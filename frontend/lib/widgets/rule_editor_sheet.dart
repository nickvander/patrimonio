import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/buttons.dart';
import '../theme/menus.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';
import 'rule_preview_diff.dart';

/// An account the sheet can offer in the "only this account" picker.
/// The label is resolved by the caller — the sheet never looks accounts up.
class RuleScopeAccount {
  const RuleScopeAccount(this.id, this.label);
  final String id;
  final String label;
}

/// Create/edit a categorization-or-rename rule, with the dry-run diff
/// wired underneath (`work/RULES_ENGINE_DESIGN.md` §5.2).
///
/// The safety contract this widget implements:
///
/// * a debounced `POST /rules/preview` runs as the user edits, and the
///   [RulePreviewDiff] below shows exactly what a retroactive apply would
///   do — including the rows it would refuse to touch;
/// * **both** primary actions stay disabled until a preview has landed,
///   so "Save & apply" can never fire against numbers nobody saw;
/// * "Save rule" is forward-only — it changes zero existing rows;
/// * "Save & apply to N past transactions" goes through a confirm dialog
///   that restates N, then saves and applies with the preview's
///   single-use token. A rule edited after the preview is a server-side
///   409, not a silent re-computation.
class RuleEditorSheet extends StatefulWidget {
  const RuleEditorSheet({
    super.key,
    required this.api,
    required this.initial,
    this.ruleId,
    this.accountOption,
    this.currencyOption,
    this.accounts = const <RuleScopeAccount>[],
    this.currencies = const <String>[],
    this.categorySuggestions = const <String>[],
    this.previewDebounce = const Duration(milliseconds: 450),
  });

  final ApiService api;

  /// Prefilled definition — from the "Save as rule…" ladder on a
  /// transaction, or from an existing rule in edit mode.
  final RuleDraft initial;

  /// Non-null = edit mode (PATCH instead of POST).
  final String? ruleId;

  /// One account worth offering even when [accounts] doesn't list it — the
  /// row's own account on the "Save as rule…" path. Folded into the picker's
  /// options, deduped by id.
  final RuleScopeAccount? accountOption;

  /// Same, for the currency picker.
  final String? currencyOption;

  /// Every account the scope picker can offer, in display order. The sheet
  /// never fetches: the caller hands it whatever list it already has (the
  /// rules screen reads the cached dashboard overview).
  final List<RuleScopeAccount> accounts;

  /// Currency codes the scope picker can offer.
  final List<String> currencies;

  /// The shared prettified category list — same source the bulk-
  /// categorize / split / detail-panel editors feed from, so a rule can't
  /// introduce a second taxonomy.
  final List<String> categorySuggestions;

  /// How long to wait after the last keystroke before previewing. A test
  /// seam as much as a UX knob (tests pass [Duration.zero]).
  final Duration previewDebounce;

  @override
  State<RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<RuleEditorSheet> {
  late final TextEditingController _valueCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _minCtrl;
  late final TextEditingController _maxCtrl;
  late final FocusNode _categoryFocus;

  late String _matchType;
  String? _direction;

  /// Scope selections — null means "any", i.e. the unscoped default every
  /// existing rule keeps.
  String? _accountId;
  String? _currency;

  /// Picker options, resolved once: what the caller offers, plus whatever
  /// the rule is ALREADY scoped to. A rule pinned to an account the
  /// overview no longer returns must still render (and be able to keep)
  /// its own scope rather than silently reading as "Any account".
  late final List<RuleScopeAccount> _accountChoices = _buildAccountChoices();
  late final List<String> _currencyChoices = _buildCurrencyChoices();

  RulePreview? _preview;
  bool _previewing = false;
  String? _previewError;
  bool _saving = false;

  Timer? _debounce;

  /// Monotonic request id: a slower earlier preview must never overwrite a
  /// newer one's numbers (that would show a diff for a rule the user has
  /// already moved past — and it is the numbers the apply is confirmed
  /// against).
  int _previewSeq = 0;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _matchType = kRuleMatchTypes.contains(d.matchType)
        ? d.matchType
        : 'contains';
    _direction = d.direction;
    _accountId = _accountChoices.any((a) => a.id == d.accountId)
        ? d.accountId
        : null;
    _currency = _currencyChoices.contains(d.currency?.trim())
        ? d.currency?.trim()
        : null;
    _valueCtrl = TextEditingController(text: d.matchValue);
    _categoryCtrl = TextEditingController(text: d.setCategory ?? '');
    _nameCtrl = TextEditingController(text: d.setDescription ?? '');
    _minCtrl = TextEditingController(text: _numText(d.amountMin));
    _maxCtrl = TextEditingController(text: _numText(d.amountMax));
    _categoryFocus = FocusNode();
    for (final c in [
      _valueCtrl,
      _categoryCtrl,
      _nameCtrl,
      _minCtrl,
      _maxCtrl,
    ]) {
      c.addListener(_schedulePreview);
    }
    // A prefilled draft (save-as-rule, or edit) is already previewable —
    // fire immediately so the diff is on screen when the sheet settles.
    // Fields are mutated directly here: initState runs before the first
    // build, so there is nothing to notify yet.
    if (_draft.isValid) {
      _lastSignature = _draftSignature;
      _previewing = true;
      _previewSeq++;
      final seq = _previewSeq;
      _debounce = Timer(Duration.zero, () => unawaited(_runPreview(seq)));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _valueCtrl.dispose();
    _categoryCtrl.dispose();
    _nameCtrl.dispose();
    _minCtrl.dispose();
    _maxCtrl.dispose();
    _categoryFocus.dispose();
    super.dispose();
  }

  /// [RuleEditorSheet.accounts] + [RuleEditorSheet.accountOption] + the
  /// initial draft's account, deduped by id, first occurrence wins.
  List<RuleScopeAccount> _buildAccountChoices() {
    final seen = <String>{};
    final out = <RuleScopeAccount>[];
    void add(RuleScopeAccount a) {
      if (a.id.isEmpty || !seen.add(a.id)) return;
      out.add(a);
    }

    for (final a in widget.accounts) {
      add(a);
    }
    final option = widget.accountOption;
    if (option != null) add(option);
    final initialId = widget.initial.accountId;
    if (initialId != null &&
        initialId.isNotEmpty &&
        !seen.contains(initialId)) {
      // No label to be had — the id is at least honest about the scope
      // being there, which reading "Any account" would not be.
      add(RuleScopeAccount(initialId, initialId));
    }
    return out;
  }

  /// Same union for currencies, sorted so the order doesn't wobble with
  /// whatever order the caller's accounts came back in. Codes are compared
  /// verbatim (never upper-cased): the value goes back on the wire.
  List<String> _buildCurrencyChoices() {
    final out = <String>{};
    for (final c in [
      ...widget.currencies,
      ?widget.currencyOption,
      ?widget.initial.currency,
    ]) {
      final s = c.trim();
      if (s.isNotEmpty) out.add(s);
    }
    return out.toList()..sort();
  }

  static String _numText(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }

  /// Parse an amount bound. Not money *formatting* (which always goes
  /// through utils/currency.dart) — this is reading a plain bound the user
  /// typed, so an es-MX comma decimal is normalized before parsing.
  static double? _parseBound(String raw) {
    final s = raw.trim().replaceAll(',', '.');
    if (s.isEmpty) return null;
    final v = double.tryParse(s);
    if (v == null || v < 0) return null;
    return v;
  }

  RuleDraft get _draft => RuleDraft(
    matchType: _matchType,
    matchValue: _valueCtrl.text,
    accountId: _accountId,
    currency: _currency,
    direction: _direction,
    amountMin: _parseBound(_minCtrl.text),
    amountMax: _parseBound(_maxCtrl.text),
    setCategory: _categoryCtrl.text,
    setDescription: _nameCtrl.text,
  );

  /// Everything the preview depends on, flattened. Controllers notify on
  /// cursor moves too; comparing signatures keeps those from re-firing a
  /// request for a definition that hasn't actually changed.
  String get _draftSignature {
    final d = _draft;
    return [
      d.matchType,
      d.matchValue.trim(),
      d.accountId,
      d.currency,
      d.direction,
      d.amountMin,
      d.amountMax,
      d.setCategory?.trim(),
      d.setDescription?.trim(),
    ].join('|');
  }

  String? _lastSignature;

  /// Any edit invalidates the diff on screen AND the token behind it — a
  /// stale token would apply the previous definition's id set.
  void _schedulePreview() {
    final signature = _draftSignature;
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    _debounce?.cancel();
    _previewSeq++;
    if (!_draft.isValid) {
      setState(() {
        _preview = null;
        _previewing = false;
        _previewError = null;
      });
      return;
    }
    setState(() {
      _preview = null;
      _previewing = true;
      _previewError = null;
    });
    final seq = _previewSeq;
    _debounce = Timer(
      widget.previewDebounce,
      () => unawaited(_runPreview(seq)),
    );
  }

  Future<void> _runPreview(int seq) async {
    try {
      final result = await widget.api.previewRule(_draft);
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _preview = result;
        _previewing = false;
      });
    } catch (e) {
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _preview = null;
        _previewing = false;
        _previewError = _clean(e);
      });
    }
  }

  static String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  /// Create or update the rule, returning its id. Neither path touches a
  /// single existing transaction.
  Future<String> _persist() async {
    final id = widget.ruleId;
    if (id != null) {
      final updated = await widget.api.updateRule(id, _draft);
      return updated.id;
    }
    final created = await widget.api.createRule(_draft);
    return created.id;
  }

  Future<void> _saveOnly() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await _persist();
      if (!mounted) return;
      navigator.pop(true);
      messenger.showSnackBar(SnackBar(content: Text(l.ruleSaved)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l.ruleSaveFailed(_clean(e)))),
      );
    }
  }

  Future<void> _saveAndApply() async {
    final l = AppLocalizations.of(context);
    final preview = _preview;
    if (preview == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.ruleApplyConfirmTitle),
        content: Text(
          // gen-l10n takes these in metadata declaration order, which the
          // arb declares in template order → (matched, categories, names).
          l.ruleApplyConfirmBody(
            preview.matched,
            preview.categoryChanges,
            preview.descriptionChanges,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.actionApply),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final id = await _persist();
      final result = await widget.api.applyRule(id, preview.previewToken);
      if (!mounted) return;
      navigator.pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            // The apply's counts are reported verbatim, and a non-zero
            // `skipped` is always named — those rows were edited by hand
            // between preview and apply and were deliberately left alone.
            [
              l.ruleAppliedCounts(
                result.updatedCategory,
                result.updatedDescription,
              ),
              if (result.skipped > 0) l.ruleAppliedSkipped(result.skipped),
            ].join(' '),
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l.ruleApplyFailed(_clean(e)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final draft = _draft;
    // Both actions are gated on a LANDED preview — never on a pending or
    // failed one. This is the feature's safety interlock, not a nicety.
    final ready = _preview != null && !_previewing && !_saving;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.92,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final stacked = width < kActionButtonStackBelow;
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: width < 720 ? 16 : 24,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.ruleId == null
                                ? l.ruleNewTitle
                                : l.ruleEditTitle,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: l.actionClose,
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.of(context).pop(),
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                      ],
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _sectionLabel(context, l.ruleMatchTypeLabel),
                            const SizedBox(height: 8),
                            ConnectedSegments<String>(
                              selected: _matchType,
                              onSelected: (v) {
                                if (v == _matchType) return;
                                setState(() => _matchType = v);
                                _schedulePreview();
                              },
                              segments: [
                                ConnectedSegment(
                                  value: 'contains',
                                  label: l.ruleMatchTypeContains,
                                ),
                                ConnectedSegment(
                                  value: 'starts_with',
                                  label: l.ruleMatchTypeStartsWith,
                                ),
                                ConnectedSegment(
                                  value: 'exact',
                                  label: l.ruleMatchTypeExact,
                                ),
                                ConnectedSegment(
                                  value: 'merchant_key',
                                  label: l.ruleMatchTypeMerchantKey,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _valueCtrl,
                              decoration: InputDecoration(
                                labelText: l.ruleMatchValueLabel,
                                hintText: l.ruleMatchValueHint,
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            if (_matchType == 'merchant_key' &&
                                (_preview?.derivedMerchantKey ?? '')
                                    .isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                l.ruleDerivedKey(_preview!.derivedMerchantKey),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: context.textSubtle,
                                ),
                              ),
                            ],
                            const SizedBox(height: 18),
                            _sectionLabel(context, l.ruleActionsLabel),
                            const SizedBox(height: 8),
                            _CategoryField(
                              controller: _categoryCtrl,
                              focusNode: _categoryFocus,
                              suggestions: widget.categorySuggestions,
                              label: l.ruleSetCategoryLabel,
                              hint: l.ruleSetCategoryHint,
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _nameCtrl,
                              decoration: InputDecoration(
                                labelText: l.ruleSetDescriptionLabel,
                                hintText: l.ruleSetDescriptionHint,
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            if (draft.matchValue.trim().isNotEmpty &&
                                !draft.isValid) ...[
                              const SizedBox(height: 8),
                              Text(
                                l.ruleNeedsAction,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.negative,
                                ),
                              ),
                            ],
                            const SizedBox(height: 18),
                            _sectionLabel(context, l.ruleScopeLabel),
                            const SizedBox(height: 8),
                            ..._scopePickers(context, l, stacked: stacked),
                            ConnectedSegments<String?>(
                              selected: _direction,
                              onSelected: (v) {
                                if (v == _direction) return;
                                setState(() => _direction = v);
                                _schedulePreview();
                              },
                              segments: [
                                ConnectedSegment(
                                  value: null,
                                  label: l.ruleDirectionAny,
                                ),
                                ConnectedSegment(
                                  value: 'inflow',
                                  label: l.ruleDirectionInflow,
                                ),
                                ConnectedSegment(
                                  value: 'outflow',
                                  label: l.ruleDirectionOutflow,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _minCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: InputDecoration(
                                      labelText: l.ruleAmountMinLabel,
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _maxCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: InputDecoration(
                                      labelText: l.ruleAmountMaxLabel,
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (draft.amountMin != null ||
                                draft.amountMax != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                l.ruleAmountRangeHint,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: context.textSubtle,
                                ),
                              ),
                            ],
                            const SizedBox(height: 18),
                            RulePreviewDiff(
                              preview: _preview,
                              loading: _previewing,
                              error: _previewError,
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                    _actions(
                      context,
                      l,
                      ready: ready,
                      stacked: stacked,
                      width: width,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The account / currency scope pickers, plus the trailing gap. Empty
  /// when the caller offered no options at all (nothing to pick from beats
  /// a dropdown whose only entry is "Any account").
  ///
  /// Both default to "Any …", so a rule the user never scopes keeps the
  /// unscoped behaviour it has always had. Changing either goes through
  /// [_schedulePreview] exactly like a matcher edit — which drops the
  /// preview on screen AND the apply token behind it, so an apply can
  /// never fire against the counts of a differently-scoped rule.
  List<Widget> _scopePickers(
    BuildContext context,
    AppLocalizations l, {
    required bool stacked,
  }) {
    final account = _accountChoices.isEmpty
        ? null
        : _scopeDropdown<String>(
            context,
            label: l.ruleScopeAccountField,
            anyLabel: l.ruleScopeAnyAccount,
            value: _accountId,
            options: [for (final a in _accountChoices) (a.id, a.label)],
            onChanged: (v) {
              if (v == _accountId) return;
              setState(() => _accountId = v);
              _schedulePreview();
            },
          );
    final currency = _currencyChoices.isEmpty
        ? null
        : _scopeDropdown<String>(
            context,
            label: l.ruleScopeCurrencyField,
            anyLabel: l.ruleScopeAnyCurrency,
            value: _currency,
            options: [for (final c in _currencyChoices) (c, c)],
            onChanged: (v) {
              if (v == _currency) return;
              setState(() => _currency = v);
              _schedulePreview();
            },
          );
    if (account == null && currency == null) return const [];

    final Widget row;
    if (account == null || currency == null) {
      row = account ?? currency!;
    } else if (stacked) {
      row = Column(children: [account, const SizedBox(height: 10), currency]);
    } else {
      row = Row(
        children: [
          Expanded(flex: 3, child: account),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: currency),
        ],
      );
    }
    return [
      row,
      // The schema holds ONE account_id, so a rule cannot span two
      // accounts. Said out loud the moment a scope is picked, because the
      // failure mode is silent: payments made from a second account simply
      // stop matching. The preview's match count below is the hard number.
      if (_accountId != null) ...[
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 14, color: context.warning),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.ruleScopeOneAccountOnly,
                style: TextStyle(fontSize: 11.5, color: context.warning),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 10),
    ];
  }

  /// One "Any …"-defaulted scope dropdown. House dropdown chrome comes
  /// from `theme/menus.dart` (the legacy dropdown route has no theme hook).
  Widget _scopeDropdown<T extends Object>(
    BuildContext context, {
    required String label,
    required String anyLabel,
    required T? value,
    required List<(T, String)> options,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T?>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: houseDropdownColor(context),
      borderRadius: kMenuRadius,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        DropdownMenuItem<T?>(value: null, child: Text(anyLabel)),
        for (final (v, text) in options)
          DropdownMenuItem<T?>(
            value: v,
            child: Text(text, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _actions(
    BuildContext context,
    AppLocalizations l, {
    required bool ready,
    required bool stacked,
    required double width,
  }) {
    final preview = _preview;
    // Enablement still keys off MATCHED: applying a rule to rows that already
    // show the target value is a real operation (it stamps them rule-managed,
    // which is why the apply's counts can exceed the preview's). Only the
    // LABEL changed — it now leads with what will visibly change, because
    // "apply to 37 past transactions" oversold the blast radius when 37 was
    // merely the match count.
    final matched = preview?.matched ?? 0;
    final categoryChanges = preview?.categoryChanges ?? 0;
    final nameChanges = preview?.descriptionChanges ?? 0;
    // No union of the two is available (a row can be in both sets), and the
    // preview reports no such count — so a two-action rule names both counts
    // rather than inventing a combined one. With a single action the count IS
    // the number of transactions that visibly change. Neither number is
    // rounded, padded, or hidden; the confirm dialog still carries the full
    // matched-vs-changed explanation, and the snackbar still reports what the
    // apply actually did.
    final String applyLabel;
    if (categoryChanges > 0 && nameChanges > 0) {
      // gen-l10n takes these in metadata declaration order, which the arb
      // declares in template order → (categories, names).
      applyLabel = l.ruleSaveAndApplyBoth(categoryChanges, nameChanges);
    } else if (categoryChanges > 0 || nameChanges > 0) {
      applyLabel = l.ruleSaveAndApplyChanges(
        categoryChanges > 0 ? categoryChanges : nameChanges,
      );
    } else {
      applyLabel = l.ruleSaveAndApplyPlain;
    }
    final saveButton = OutlinedButton(
      onPressed: ready ? _saveOnly : null,
      child: Text(l.ruleSaveForward),
    );
    final applyButton = FilledButton(
      onPressed: ready && matched > 0 ? _saveAndApply : null,
      child: Text(applyLabel, maxLines: 2, textAlign: TextAlign.center),
    );
    if (stacked) {
      // Touch-width: full-bleed and stacked, primary action last (nearest
      // the thumb) — theme/buttons.dart.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: double.infinity, child: saveButton),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: applyButton),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        ConstrainedBox(
          constraints: actionButtonConstraints(width),
          child: saveButton,
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: kActionButtonMinWidth,
            maxWidth: kActionButtonMaxWidth,
          ),
          child: applyButton,
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      letterSpacing: 1.0,
      fontWeight: FontWeight.w700,
      color: context.textSubtle,
    ),
  );
}

/// Category input with type-ahead over the shared prettified category
/// list — the same RawAutocomplete recipe the transaction detail panel
/// uses, so a rule's category can't drift into a second taxonomy.
class _CategoryField extends StatelessWidget {
  const _CategoryField({
    required this.controller,
    required this.focusNode,
    required this.suggestions,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> suggestions;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focusNode,
      optionsBuilder: (TextEditingValue value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return suggestions;
        return suggestions.where((c) => c.toLowerCase().contains(q));
      },
      fieldViewBuilder: (ctx, textController, node, onFieldSubmitted) {
        return TextField(
          controller: textController,
          focusNode: node,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (ctx, onSelected, options) {
        final opts = options.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 420),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: opts.length,
                itemBuilder: (ctx, index) {
                  final option = opts[index];
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(option),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Open [RuleEditorSheet] as a modal bottom sheet. Resolves to `true` when
/// a rule was saved (with or without a retroactive apply), so the caller
/// can refresh.
Future<bool?> showRuleEditorSheet(
  BuildContext context, {
  required ApiService api,
  required RuleDraft initial,
  String? ruleId,
  RuleScopeAccount? accountOption,
  String? currencyOption,
  List<RuleScopeAccount> accounts = const <RuleScopeAccount>[],
  List<String> currencies = const <String>[],
  List<String> categorySuggestions = const <String>[],
  Duration previewDebounce = const Duration(milliseconds: 450),
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => RuleEditorSheet(
      api: api,
      initial: initial,
      ruleId: ruleId,
      accountOption: accountOption,
      currencyOption: currencyOption,
      accounts: accounts,
      currencies: currencies,
      categorySuggestions: categorySuggestions,
      previewDebounce: previewDebounce,
    ),
  );
}

/// Seed a rule from a transaction row — design §5.1's prefill ladder.
///
/// * matcher: `contains` over `counterparty_name ?? merchant_name ??
///   description` (trimmed) — the same fallback the transactions list uses
///   to LABEL the row, so the rule matches what the user is looking at;
/// * actions: the row's current effective category (user override first,
///   then the auto category) and its current display override, if any.
///   A rule with no action yet is fine — the editor blocks saving until
///   one is set.
RuleDraft ruleDraftFromTransaction(Map<String, dynamic> tx) {
  String? pick(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  final value =
      pick(tx['counterparty_name']) ??
      pick(tx['merchant_name']) ??
      pick(tx['description']) ??
      '';
  return RuleDraft(
    matchType: 'contains',
    matchValue: value,
    setCategory: pick(tx['user_category']) ?? pick(tx['category']),
    setDescription: pick(tx['user_description']),
  );
}
