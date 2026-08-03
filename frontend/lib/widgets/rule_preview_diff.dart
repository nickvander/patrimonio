import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';

/// The dry-run diff for a user rule — the safety mechanism of the whole
/// rules feature, so it is rendered plainly and always, never behind a
/// collapsed disclosure (`work/RULES_ENGINE_DESIGN.md` §5.2).
///
/// Dumb/injected per house convention: it takes an already-fetched
/// [RulePreview] plus the loading/error state and renders it. The
/// debounced fetching lives in [RuleEditorSheet].
///
/// Three pieces of copy here exist because of what the backend actually
/// returns, not because of decoration:
///
/// * the **provenance note** — `category_changes` counts rows whose
///   DISPLAYED value would change, while the apply also stamps matched
///   rows that already hold the target value, so its reported numbers can
///   legitimately exceed these. Better said out loud than discovered.
/// * the **skipped-as-manual line** — rows a human edited are never
///   overwritten by a rule.
/// * the **FX-transfer warning** — recategorizing a confirmed transfer
///   leg re-enters it into cash-flow totals. The owner's decision was
///   allow + warn (DEC-028), which makes this banner the entire guard.
class RulePreviewDiff extends StatelessWidget {
  const RulePreviewDiff({
    super.key,
    required this.preview,
    this.loading = false,
    this.error,
  });

  /// The completed dry run; null until one has landed.
  final RulePreview? preview;

  /// A preview request is in flight (the previous [preview], if any, is
  /// still shown underneath a progress line — the numbers on screen must
  /// never silently belong to a different rule definition).
  final bool loading;

  /// Human-readable failure from the last preview attempt.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = preview;

    if (error != null) {
      return _frame(
        context,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 16, color: context.negative),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.rulePreviewFailed(error!),
                style: TextStyle(fontSize: 12, color: context.negative),
              ),
            ),
          ],
        ),
      );
    }

    if (p == null) {
      return _frame(
        context,
        child: Row(
          children: [
            if (loading) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                loading ? l.rulePreviewRunning : l.rulePreviewIdle,
                style: TextStyle(fontSize: 12, color: context.textSubtle),
              ),
            ),
          ],
        ),
      );
    }

    return _frame(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l.rulePreviewTitle,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w700,
                    color: context.textSubtle,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // gen-l10n takes these in metadata declaration order, which the
          // arb declares in template order → (matched, categories, names).
          Text(
            l.rulePreviewCounts(
              p.matched,
              p.categoryChanges,
              p.descriptionChanges,
            ),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
          if (p.skippedManual > 0) ...[
            const SizedBox(height: 4),
            Text(
              l.rulePreviewSkippedManual(p.skippedManual),
              style: TextStyle(fontSize: 12, color: context.textMuted),
            ),
          ],
          if (p.matched > 0) ...[
            const SizedBox(height: 6),
            Text(
              l.rulePreviewProvenanceNote,
              style: TextStyle(fontSize: 11.5, color: context.textSubtle),
            ),
          ],
          if (p.fxTransferLegs > 0) ...[
            const SizedBox(height: 10),
            _fxWarning(context, l, p.fxTransferLegs),
          ],
          if (p.matched > 0 && !p.hasVisibleChanges) ...[
            const SizedBox(height: 10),
            Text(
              l.rulePreviewNoChanges,
              style: TextStyle(fontSize: 12, color: context.textMuted),
            ),
          ],
          if (p.samples.isNotEmpty) ...[
            const SizedBox(height: 6),
            // The tile needs its OWN Material ancestor: this widget's frame
            // is a DecoratedBox with a fill, and ExpansionTile's header
            // would otherwise paint its ink on the Material *outside* it
            // (a framework assertion, not just cosmetics).
            Material(
              type: MaterialType.transparency,
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  // Expanded by default: the diff IS the safety mechanism,
                  // so the user must not have to go looking for it.
                  initiallyExpanded: true,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: Text(
                    l.rulePreviewSamples,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: context.textMuted,
                    ),
                  ),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: p.samples.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 12, color: context.hairline),
                        itemBuilder: (_, i) =>
                            _sampleRow(context, l, p.samples[i]),
                      ),
                    ),
                    if (p.samples.length < p.matched) ...[
                      const SizedBox(height: 8),
                      Text(
                        l.rulePreviewShowingFirst(p.samples.length),
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _frame(BuildContext context, {required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: context.tileSurface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.hairline),
    ),
    child: child,
  );

  Widget _fxWarning(BuildContext context, AppLocalizations l, int count) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: context.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.rulePreviewFxWarning(count),
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: context.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sampleRow(
    BuildContext context,
    AppLocalizations l,
    RulePreviewSample s,
  ) {
    final meta = <String>[
      s.date,
      if (s.accountName.isNotEmpty) s.accountName,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(meta, style: TextStyle(fontSize: 11, color: context.textSubtle)),
        const SizedBox(height: 2),
        Text(
          s.displayDescription,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: context.textPrimary,
          ),
        ),
        if (s.changesCategory) ...[
          const SizedBox(height: 4),
          _beforeAfter(
            context,
            l.ruleFieldCategory,
            s.oldCategory,
            s.newCategory!,
          ),
        ],
        if (s.changesDescription) ...[
          const SizedBox(height: 4),
          _beforeAfter(
            context,
            l.ruleFieldName,
            s.oldDescription,
            s.newDescription!,
          ),
        ],
      ],
    );
  }

  Widget _beforeAfter(
    BuildContext context,
    String field,
    String? before,
    String after,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            field,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
        ),
        Flexible(
          child: Text(
            // An em dash stands in for "nothing there today" — it needs no
            // translation and reads the same in both locales.
            before ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: context.textMuted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Icon(Icons.arrow_forward, size: 13, color: context.textFaint),
        ),
        Flexible(
          child: Text(
            after,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.positive,
            ),
          ),
        ),
      ],
    );
  }
}
