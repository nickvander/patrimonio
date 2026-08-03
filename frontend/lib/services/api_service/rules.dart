part of '../api_service.dart';

/// User categorization/rename rules: CRUD, reorder, and the
/// dry-run/apply safety contract (`work/RULES_ENGINE_DESIGN.md` §4).
///
/// The sixth domain mixin of the ApiService split. Two contract facts
/// worth knowing before reading the DTOs:
///
/// * **Creating, editing, enabling, disabling or deleting a rule mutates
///   ZERO transactions.** Only [applyRule] rewrites history, and only
///   with a single-use token minted by [previewRule].
/// * **The preview's change counts and the apply's updated counts measure
///   different things** — see [RulePreview.categoryChanges]. The UI must
///   not imply they have to agree.
mixin _RulesApi on _ApiServiceBase {
  /// Every rule, in evaluation order (priority ASC), including inactive
  /// ones. Deliberately NOT `_cachedGet`: the rules screen is a small,
  /// rarely-open management surface where a stale list after a drag or a
  /// toggle would be worse than one extra round-trip.
  Future<List<UserRule>> getRules() async {
    final response = await _get(Uri.parse('$_baseUrl/rules'));
    if (response.statusCode == 200) {
      return (json.decode(response.body) as List<dynamic>)
          .map((e) => UserRule.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw _errorFromBody(
      response,
      fallback: _t('Failed to load rules', 'No se pudieron cargar las reglas'),
    );
  }

  /// Create a rule. It appends at the end of the evaluation order and
  /// changes no existing transaction — retroactive application is a
  /// separate, previewed [applyRule] call.
  Future<UserRule> createRule(RuleDraft draft, {bool active = true}) async {
    final response = await _post(
      Uri.parse('$_baseUrl/rules'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode({...draft.toCreateJson(), 'active': active}),
    );
    if (response.statusCode == 201) {
      return UserRule.fromJson(json.decode(response.body));
    }
    throw _errorFromBody(
      response,
      fallback: _t('Failed to create rule', 'No se pudo crear la regla'),
    );
  }

  /// Full edit of a rule's definition. Every field is sent, with explicit
  /// `null`s for cleared scopes/actions — the server distinguishes "key
  /// absent" (leave alone) from "key present and null" (clear), so a
  /// partial body would silently keep a scope the user just removed.
  Future<UserRule> updateRule(String id, RuleDraft draft) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/rules/$id'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode(draft.toPatchJson()),
    );
    if (response.statusCode == 200) {
      return UserRule.fromJson(json.decode(response.body));
    }
    throw _errorFromBody(
      response,
      fallback: _t('Failed to update rule', 'No se pudo actualizar la regla'),
    );
  }

  /// Pause/resume a rule. Paused rules stop matching new transactions and
  /// never touch anything they already applied.
  Future<UserRule> setRuleActive(String id, bool active) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/rules/$id'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode({'active': active}),
    );
    if (response.statusCode == 200) {
      return UserRule.fromJson(json.decode(response.body));
    }
    throw _errorFromBody(
      response,
      fallback: _t('Failed to update rule', 'No se pudo actualizar la regla'),
    );
  }

  /// Delete a rule. Values it already applied are KEPT (DEC-028) — the
  /// delete confirm copy must say so.
  Future<void> deleteRule(String id) async {
    final response = await _delete(Uri.parse('$_baseUrl/rules/$id'));
    if (response.statusCode != 204) {
      throw _errorFromBody(
        response,
        fallback: _t('Failed to delete rule', 'No se pudo eliminar la regla'),
      );
    }
  }

  /// Rewrite the evaluation order from a full, ordered id list (the
  /// management screen's drag handle). Returns the re-ordered list.
  Future<List<UserRule>> reorderRules(List<String> orderedIds) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/rules/reorder'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode({'ordered_ids': orderedIds}),
    );
    if (response.statusCode == 200) {
      return (json.decode(response.body) as List<dynamic>)
          .map((e) => UserRule.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw _errorFromBody(
      response,
      fallback: _t(
        'Failed to reorder rules',
        'No se pudo reordenar las reglas',
      ),
    );
  }

  /// Dry run: what would this rule definition change across ALL history?
  /// Reads only — it writes nothing but a short-lived Redis token whose
  /// id set the matching [applyRule] is confined to.
  ///
  /// Note on the cache: this is a POST, so the shared verb wrapper clears
  /// the dashboard cache even though a preview mutates no data. That's the
  /// blunt-but-provably-safe house invalidation; the cost is a few extra
  /// dashboard refetches while the user types a rule, which beats
  /// special-casing the wrapper.
  Future<RulePreview> previewRule(RuleDraft draft) async {
    final response = await _post(
      Uri.parse('$_baseUrl/rules/preview'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode(draft.toCreateJson()),
    );
    if (response.statusCode == 200) {
      return RulePreview.fromJson(json.decode(response.body));
    }
    throw _errorFromBody(
      response,
      fallback: _t('Preview failed', 'La vista previa falló'),
    );
  }

  /// THE only call that rewrites history, and only for the exact rows the
  /// matching [previewRule] listed. [previewToken] is single-use: a
  /// double-tap can't double-fire, and a rule edited after the preview
  /// gets a 409 ("re-run the preview") rather than applying values the
  /// user never saw.
  Future<RuleApplyResult> applyRule(String id, String previewToken) async {
    final response = await _post(
      Uri.parse('$_baseUrl/rules/$id/apply'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode({'preview_token': previewToken}),
    );
    if (response.statusCode == 200) {
      return RuleApplyResult.fromJson(json.decode(response.body));
    }
    throw _errorFromBody(
      response,
      fallback: _t('Failed to apply rule', 'No se pudo aplicar la regla'),
    );
  }
}

/// The four matcher kinds the backend accepts (`user_rules.match_type`
/// CHECK constraint). Regex is deliberately out of v1 — a catastrophic
/// backtracking pattern would wedge the Plaid sync path, where rules run
/// per row (design §1).
const List<String> kRuleMatchTypes = <String>[
  'merchant_key',
  'contains',
  'starts_with',
  'exact',
];

/// Trim a JSON value to a non-empty string, or null. Rule scopes and
/// actions treat "cleared in the UI" and "never set" as the same state,
/// exactly as the server's `blank_to_none` does.
String? _ruleText(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// A rule definition as the client states it — the body shape shared by
/// create, edit and preview. Deliberately separate from [UserRule]: the
/// preview endpoint takes a definition INLINE (not an id) so the diff
/// works before the rule exists as well as for edits.
class RuleDraft {
  const RuleDraft({
    this.matchType = 'contains',
    this.matchValue = '',
    this.accountId,
    this.currency,
    this.direction,
    this.amountMin,
    this.amountMax,
    this.setCategory,
    this.setDescription,
  });

  /// One of [kRuleMatchTypes].
  final String matchType;
  final String matchValue;

  // Scope — null everywhere means unrestricted.
  final String? accountId;
  final String? currency;

  /// `'inflow'` or `'outflow'`; null = both.
  final String? direction;

  /// Bounds compare ABS(amount) in the row's NATIVE currency.
  final double? amountMin;
  final double? amountMax;

  // Actions — at least one must be set.
  final String? setCategory;
  final String? setDescription;

  /// Client-side mirror of the server's validation, so the editor can
  /// keep the preview from firing on a body the server would 400.
  bool get isValid =>
      matchValue.trim().isNotEmpty &&
      kRuleMatchTypes.contains(matchType) &&
      (_ruleText(setCategory) != null || _ruleText(setDescription) != null) &&
      (amountMin == null || amountMax == null || amountMax! >= amountMin!);

  /// Body for `POST /rules` and `POST /rules/preview`: unset scopes and
  /// actions are omitted (the server's `#[serde(default)]` reads absent
  /// as "none").
  Map<String, dynamic> toCreateJson() => <String, dynamic>{
    'match_type': matchType,
    'match_value': matchValue.trim(),
    'account_id': ?accountId,
    'currency': ?currency,
    'direction': ?direction,
    'amount_min': ?amountMin,
    'amount_max': ?amountMax,
    'set_category': ?_ruleText(setCategory),
    'set_description': ?_ruleText(setDescription),
  };

  /// Body for `PATCH /rules/{id}`: every key present, `null` where the
  /// user cleared it (see [_RulesApi.updateRule]).
  Map<String, dynamic> toPatchJson() => <String, dynamic>{
    'match_type': matchType,
    'match_value': matchValue.trim(),
    'account_id': accountId,
    'currency': currency,
    'direction': direction,
    'amount_min': amountMin,
    'amount_max': amountMax,
    'set_category': _ruleText(setCategory),
    'set_description': _ruleText(setDescription),
  };
}

/// A stored rule, as `GET /rules` returns it.
class UserRule {
  const UserRule({
    required this.id,
    required this.matchType,
    required this.matchValue,
    required this.priority,
    required this.active,
    this.accountId,
    this.currency,
    this.direction,
    this.amountMin,
    this.amountMax,
    this.setCategory,
    this.setDescription,
  });

  factory UserRule.fromJson(Map<String, dynamic> j) => UserRule(
    id: (j['id'] ?? '').toString(),
    matchType: _ruleText(j['match_type']) ?? 'contains',
    matchValue: (j['match_value'] ?? '').toString(),
    accountId: _ruleText(j['account_id']),
    currency: _ruleText(j['currency']),
    direction: _ruleText(j['direction']),
    amountMin: (j['amount_min'] as num?)?.toDouble(),
    amountMax: (j['amount_max'] as num?)?.toDouble(),
    setCategory: _ruleText(j['set_category']),
    setDescription: _ruleText(j['set_description']),
    priority: (j['priority'] as num?)?.toInt() ?? 0,
    active: j['active'] == true,
  );

  final String id;
  final String matchType;
  final String matchValue;
  final String? accountId;
  final String? currency;
  final String? direction;
  final double? amountMin;
  final double? amountMax;
  final String? setCategory;
  final String? setDescription;
  final int priority;
  final bool active;

  /// The editable definition behind this rule (drops id/priority/active,
  /// none of which participate in matching or in the preview fingerprint).
  RuleDraft toDraft() => RuleDraft(
    matchType: matchType,
    matchValue: matchValue,
    accountId: accountId,
    currency: currency,
    direction: direction,
    amountMin: amountMin,
    amountMax: amountMax,
    setCategory: setCategory,
    setDescription: setDescription,
  );
}

/// One row of the dry-run diff. `oldDescription` is what the list shows
/// today; a null `newCategory`/`newDescription` means that field wouldn't
/// visibly change on this row.
class RulePreviewSample {
  const RulePreviewSample({
    required this.id,
    required this.date,
    required this.accountName,
    required this.displayDescription,
    this.oldCategory,
    this.newCategory,
    this.oldDescription,
    this.newDescription,
  });

  factory RulePreviewSample.fromJson(Map<String, dynamic> j) =>
      RulePreviewSample(
        id: (j['id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        accountName: (j['account_name'] ?? '').toString(),
        displayDescription: (j['display_description'] ?? '').toString(),
        oldCategory: _ruleText(j['old_category']),
        newCategory: _ruleText(j['new_category']),
        oldDescription: _ruleText(j['old_description']),
        newDescription: _ruleText(j['new_description']),
      );

  final String id;
  final String date;
  final String accountName;
  final String displayDescription;
  final String? oldCategory;
  final String? newCategory;
  final String? oldDescription;
  final String? newDescription;

  bool get changesCategory => newCategory != null;
  bool get changesDescription => newDescription != null;
}

/// The dry-run result. The token inside is what makes an apply legal.
class RulePreview {
  const RulePreview({
    required this.matched,
    required this.categoryChanges,
    required this.descriptionChanges,
    required this.skippedManual,
    required this.fxTransferLegs,
    required this.derivedMerchantKey,
    required this.samples,
    required this.previewToken,
    required this.expiresInSeconds,
  });

  factory RulePreview.fromJson(Map<String, dynamic> j) => RulePreview(
    matched: (j['matched'] as num?)?.toInt() ?? 0,
    categoryChanges: (j['category_changes'] as num?)?.toInt() ?? 0,
    descriptionChanges: (j['description_changes'] as num?)?.toInt() ?? 0,
    skippedManual: (j['skipped_manual'] as num?)?.toInt() ?? 0,
    fxTransferLegs: (j['fx_transfer_legs'] as num?)?.toInt() ?? 0,
    derivedMerchantKey: (j['derived_merchant_key'] ?? '').toString(),
    samples: ((j['samples'] as List<dynamic>?) ?? const [])
        .map((e) => RulePreviewSample.fromJson(e as Map<String, dynamic>))
        .toList(),
    previewToken: (j['preview_token'] ?? '').toString(),
    expiresInSeconds: (j['expires_in_seconds'] as num?)?.toInt() ?? 0,
  );

  /// Rows the rule matches at all.
  final int matched;

  /// Matched rows whose DISPLAYED category would change.
  ///
  /// **Not the number the apply will report.** The apply also stamps
  /// provenance on matched rows that already hold the target value
  /// (making them rule-managed rather than machine-guessed), so
  /// [RuleApplyResult.updatedCategory] can legitimately exceed this. The
  /// UI says so out loud instead of implying the two must agree.
  final int categoryChanges;

  /// Same contract as [categoryChanges], for the rename action.
  final int descriptionChanges;

  /// Matched rows left alone because a human set that field. Rules never
  /// overwrite a manual edit.
  final int skippedManual;

  /// Matched rows that are legs of a confirmed cross-currency transfer.
  /// Recategorizing one re-enters it into cash-flow totals, so the diff
  /// warns loudly (DEC-028: allow + warn).
  final int fxTransferLegs;

  /// `categorize::merchant_key` of the entered match value — what the
  /// merchant_key matcher will actually compare against.
  final String derivedMerchantKey;

  /// Capped server-side at 50 rows; only rows with a visible change.
  final List<RulePreviewSample> samples;

  final String previewToken;
  final int expiresInSeconds;

  /// True when the rule matches rows but none of them would look
  /// different afterwards (usually a rule that's already applied, or one
  /// shadowed by a higher-priority rule).
  bool get hasVisibleChanges => categoryChanges > 0 || descriptionChanges > 0;
}

/// What the apply actually did. [skipped] > 0 means rows were manually
/// edited between the preview and the apply and were therefore left
/// alone — always surfaced, never swallowed.
class RuleApplyResult {
  const RuleApplyResult({
    required this.updatedCategory,
    required this.updatedDescription,
    required this.skipped,
  });

  factory RuleApplyResult.fromJson(Map<String, dynamic> j) => RuleApplyResult(
    updatedCategory: (j['updated_category'] as num?)?.toInt() ?? 0,
    updatedDescription: (j['updated_description'] as num?)?.toInt() ?? 0,
    skipped: (j['skipped'] as num?)?.toInt() ?? 0,
  );

  final int updatedCategory;
  final int updatedDescription;
  final int skipped;
}
