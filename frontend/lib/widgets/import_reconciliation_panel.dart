import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// The import-preview "Statement check" panel: per destination account, per
/// statement file, what `POST /imports/reconcile` found.
///
/// Two properties this widget exists to hold:
///
/// 1. **`unavailable` never looks like `reconciled`.** "We couldn't check
///    this statement" gets a neutral tone and a question-mark icon — not the
///    positive tone and not the check-circle family — because a green check
///    on an unchecked statement is a lie the user acts on.
/// 2. **It is advisory.** Nothing here disables the import; the panel only
///    renders. The confirm button's enablement never reads this data (real
///    statements carry fees and adjustments the parsers miss, so a hard gate
///    would block legitimate imports).
/// 3. **A green verdict says WHICH balance it checked against.** Against the
///    bank's declared total the check is independent; against the running
///    column it only proves the rows we read are self-consistent, so it
///    cannot notice rows the reader dropped. Both are honest results, but
///    they are not the same promise — the qualifier line under the verdict
///    is what keeps "Balances to the centavo" from overclaiming.
class ImportReconciliationPanel extends StatelessWidget {
  const ImportReconciliationPanel({super.key, required this.accounts});

  /// One entry per destination account, as the backend rolled it up.
  final List<AccountReconciliation> accounts;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final showAccountHeaders = accounts.length > 1;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            // Responsiveness is driven by the panel's OWN width, not the
            // screen: it sits inside the review column, which is already
            // padded and can be narrower than the window.
            final narrow = constraints.maxWidth < 420;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.fact_check_outlined,
                      size: 18,
                      color: context.info,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l.impReconTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  l.impReconAdvisory,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: context.textSubtle,
                  ),
                ),
                for (final account in accounts) ...[
                  if (showAccountHeaders) ...[
                    const SizedBox(height: 16),
                    _AccountHeader(account: account),
                  ],
                  for (final statement in account.statements) ...[
                    const SizedBox(height: 14),
                    _StatementTile(
                      statement: statement,
                      fallbackCurrency: account.currency,
                      narrow: narrow,
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Tone + icon + label for one status. Kept in one place so the
/// `unavailable`-is-not-green rule can't drift apart across call sites.
({Color tone, IconData icon, String label}) _statusVisual(
  BuildContext context,
  AppLocalizations l,
  ReconcileStatus status,
) => switch (status) {
  ReconcileStatus.reconciled => (
    tone: context.positive,
    icon: Icons.check_circle,
    label: l.impReconReconciled,
  ),
  ReconcileStatus.reconciledAfterDuplicateSkip => (
    tone: context.positive,
    icon: Icons.check_circle_outline,
    label: l.impReconDuplicateSkip,
  ),
  ReconcileStatus.explainedByExistingTransactions => (
    tone: context.warning,
    icon: Icons.compare_arrows,
    label: l.impReconExplained,
  ),
  ReconcileStatus.unexplained => (
    tone: context.warning,
    icon: Icons.report_problem_outlined,
    label: l.impReconUnexplained,
  ),
  // Neutral, and a question mark — deliberately outside both the positive
  // tone and the check-circle icon family.
  ReconcileStatus.unavailable => (
    tone: context.textSubtle,
    icon: Icons.help_outline,
    label: l.impReconUnavailable,
  ),
};

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.account});

  final AccountReconciliation account;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final visual = _statusVisual(context, l, account.status);
    return Row(
      children: [
        Icon(visual.icon, size: 14, color: visual.tone),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            account.accountName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatementTile extends StatelessWidget {
  const _StatementTile({
    required this.statement,
    required this.fallbackCurrency,
    required this.narrow,
  });

  final StatementReconciliation statement;

  /// Used when the statement itself has no single currency (the
  /// `mixed_currency` case), so money labels still carry a symbol.
  final String fallbackCurrency;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final visual = _statusVisual(context, l, statement.status);
    final currency = statement.currency ?? fallbackCurrency;
    final subtitle = [
      if (statement.file.isNotEmpty) statement.file,
      if (statement.periodStart.isNotEmpty && statement.periodEnd.isNotEmpty)
        l.impReconPeriod(
          _shortDate(context, statement.periodStart),
          _shortDate(context, statement.periodEnd),
        ),
      l.impReconRows(statement.incomingRows),
    ].join('  ·  ');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: visual.tone.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: visual.tone.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(visual.icon, size: 18, color: visual.tone),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      visual.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: visual.tone,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: context.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _detail(context, l, currency),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              color: context.textMuted,
            ),
          ),
          ..._sourceQualifier(context, l),
          ..._balanceRows(context, l, currency),
          if (statement.candidates.isNotEmpty)
            _CandidateList(
              candidates: statement.candidates,
              currency: currency,
              narrow: narrow,
            ),
        ],
      ),
    );
  }

  /// The plain-language "what does this mean / what do I do" sentence.
  String _detail(BuildContext context, AppLocalizations l, String currency) {
    switch (statement.status) {
      case ReconcileStatus.reconciled:
        return l.impReconReconciledDetail;
      case ReconcileStatus.reconciledAfterDuplicateSkip:
        return l.impReconDuplicateSkipDetail(statement.duplicateRows);
      case ReconcileStatus.explainedByExistingTransactions:
        // The generated signature is (difference, count) — the declared
        // placeholder order in app_en.arb, which matches the template. The
        // distinct types (String, int) make a transposition a compile error.
        return l.impReconExplainedDetail(
          _money(statement.difference, currency),
          statement.candidates.length,
        );
      case ReconcileStatus.unexplained:
        return l.impReconUnexplainedDetail;
      case ReconcileStatus.unavailable:
        return switch (statement.unavailableReason) {
          ReconcileUnavailableReason.noRunningBalance =>
            l.impReconUnavailableNoBalance,
          ReconcileUnavailableReason.balanceMarkerOnly =>
            l.impReconUnavailableMarker,
          ReconcileUnavailableReason.mixedCurrency =>
            l.impReconUnavailableMixed,
          null => l.impReconUnavailableGeneric,
        };
    }
  }

  /// Which balance the check actually compared against — the qualifier that
  /// keeps a green verdict from overclaiming.
  ///
  /// Only for the states where a balance was genuinely compared:
  /// `unavailable` compared nothing, so it says nothing here (it already
  /// renders no balance rows). Deliberately quieter than both the headline
  /// and the detail sentence — this qualifies the verdict, it does not
  /// compete with it — and the running-balance wording is written to be
  /// accurate rather than alarming, because it is the normal case for most
  /// banks today.
  List<Widget> _sourceQualifier(BuildContext context, AppLocalizations l) {
    if (statement.status == ReconcileStatus.unavailable) return const [];
    final declared =
        statement.closingBalanceSource ==
        ReconcileClosingBalanceSource.declared;
    return [
      const SizedBox(height: 6),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              declared ? Icons.verified_outlined : Icons.rule,
              size: 13,
              color: context.textFaint,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              declared ? l.impReconSourceDeclared : l.impReconSourceRunning,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.3,
                color: context.textFaint,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  /// Whether the running column's own closing balance earns a row of its
  /// own: only when a DECLARED total was what we checked against and the two
  /// figures disagree. That gap is the bank's printed total contradicting
  /// where our rows end — the fingerprint of a parse that lost rows, and the
  /// one case where showing both figures tells the user something the
  /// difference row alone doesn't.
  bool get _showRunningClosing {
    if (statement.status == ReconcileStatus.unavailable) return false;
    if (statement.closingBalanceSource !=
        ReconcileClosingBalanceSource.declared) {
      return false;
    }
    final declared = statement.declaredClosingBalance;
    final running = statement.runningClosingBalance;
    if (declared == null || running == null) return false;
    // Half-a-centavo tolerance: the backend rounds to 2dp, so anything below
    // this is float noise, not a disagreement worth a row.
    return (declared - running).abs() >= 0.005;
  }

  /// Statement closing / after-import / difference, shown only when the
  /// backend actually produced them (an `unavailable` statement has none —
  /// printing a 0 there would be the very confusion this panel avoids).
  List<Widget> _balanceRows(
    BuildContext context,
    AppLocalizations l,
    String currency,
  ) {
    final rows = <({String label, String value, Color? tone})>[
      if (statement.statementClosingBalance != null)
        (
          label: l.impReconStatementClosing,
          value: _money(statement.statementClosingBalance, currency),
          tone: null,
        ),
      if (_showRunningClosing)
        (
          label: l.impReconRunningClosing,
          value: _money(statement.runningClosingBalance, currency),
          tone: null,
        ),
      if (statement.computedClosingBalance != null)
        (
          label: l.impReconAppClosing,
          value: _money(statement.computedClosingBalance, currency),
          tone: null,
        ),
      if (statement.difference != null && statement.difference != 0)
        (
          label: l.impReconDifference,
          value: _money(statement.difference, currency),
          tone: context.warning,
        ),
    ];
    if (rows.isEmpty) return const [];

    Widget cell(({String label, String value, Color? tone}) r) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.label,
          style: TextStyle(fontSize: 10.5, color: context.textFaint),
        ),
        const SizedBox(height: 2),
        Text(
          r.value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: r.tone ?? context.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    return [
      const SizedBox(height: 10),
      if (narrow)
        // Phone width: one label/value pair per line, value right-aligned,
        // so long money strings never squeeze the labels into ellipsis.
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    r.label,
                    style: TextStyle(fontSize: 11.5, color: context.textFaint),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  r.value,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: r.tone ?? context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          )
      else
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final r in rows) Expanded(child: cell(r))],
        ),
    ];
  }

  String _money(double? amount, String currency) =>
      amount == null ? '—' : formatCurrencyAmount(amount, currency);
}

/// The actionable half of an `explained_by_existing_transactions` result:
/// the exact stored rows whose amounts sum to the gap.
class _CandidateList extends StatelessWidget {
  const _CandidateList({
    required this.candidates,
    required this.currency,
    required this.narrow,
  });

  final List<ReconcileCandidate> candidates;
  final String currency;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Text(
          l.impReconCandidatesTitle,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: context.textSubtle,
          ),
        ),
        for (final candidate in candidates) ...[
          const SizedBox(height: 6),
          _CandidateRow(
            candidate: candidate,
            currency: currency,
            narrow: narrow,
          ),
        ],
      ],
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.currency,
    required this.narrow,
  });

  final ReconcileCandidate candidate;
  final String currency;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final kindLabel = switch (candidate.kind) {
      ReconcileCandidateKind.doubleEntryInPeriod =>
        l.impReconCandidateDoubleEntry,
      ReconcileCandidateKind.misdatedNearPeriod => l.impReconCandidateMisdated,
    };
    final amount = Text(
      formatCurrencyAmount(candidate.amount, currency),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: candidate.amount < 0 ? context.negative : context.positive,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          candidate.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: context.textPrimary),
        ),
        const SizedBox(height: 1),
        Text(
          '${_shortDate(context, candidate.date)}  ·  $kindLabel',
          style: TextStyle(fontSize: 10.5, color: context.textFaint),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: narrow
          // Phone width: the amount drops under the description instead of
          // fighting it for horizontal room.
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                body,
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerRight, child: amount),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: body),
                const SizedBox(width: 10),
                amount,
              ],
            ),
    );
  }
}

/// ISO `YYYY-MM-DD` → a locale-aware short date. Falls back to the raw
/// string if the backend ever sends something unparseable.
String _shortDate(BuildContext context, String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  return DateFormat.yMMMd(
    AppLocalizations.of(context).localeName,
  ).format(parsed);
}
