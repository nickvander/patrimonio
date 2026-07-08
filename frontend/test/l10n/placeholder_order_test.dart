import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// Contract guard for the gen-l10n placeholder-transposition trap
// (skills/flutter-frontend/SKILL.md §2). gen-l10n derives each localized
// method's POSITIONAL parameters by ALPHABETIZING the placeholder names,
// independent of the order they appear in the template. Call sites therefore
// must pass args in alphabetical-name order, and an audit found 15 sites that
// didn't (silently swapping money/dates because they're all Object).
//
// These assertions call each fixed method with distinguishable per-parameter
// sentinels and pin the rendered position of each. If a future SDK bump changes
// the alphabetization, or someone edits a template and regenerates, the
// param→slot mapping shifts and these fail loudly — surfacing what would
// otherwise be an invisible transposition.
void main() {
  Future<String> render(
      WidgetTester tester, String Function(AppLocalizations l) pick) async {
    late String out;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        out = pick(AppLocalizations.of(context));
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    return out;
  }

  testWidgets('taxHarvestFooterFlow(carryforward, gains, ordinary)',
      (tester) async {
    // template: "{gains} taxable gains remain, {ordinary} offset ..., {carryforward} carried forward"
    final s = await render(
        tester, (l) => l.taxHarvestFooterFlow('CF', 'GA', 'OR'));
    expect(
        s,
        'GA taxable gains remain, OR offset against income, '
        'CF carried forward');
  });

  testWidgets('lwSinceLargestMove(account, amount)', (tester) async {
    // template: "{amount} on {account}"
    final s = await render(tester, (l) => l.lwSinceLargestMove('ACC', 'AMT'));
    expect(s, 'AMT on ACC');
  });

  testWidgets(
      'txTransferImpliedRate(dstAmount, dstCurrency, rate, srcAmount, srcCurrency)',
      (tester) async {
    // template: "{srcAmount} → {dstAmount} · implied {rate} {dstCurrency}/{srcCurrency}"
    final s = await render(
        tester, (l) => l.txTransferImpliedRate('DA', 'DC', 'RT', 'SA', 'SC'));
    expect(s, 'SA → DA · implied RT DC/SC');
  });

  testWidgets(
      'lwNotifRepaymentOverdueDetail(amount, daysOverdue, dueDate, number)',
      (tester) async {
    // template: "Installment #{number} of {amount} was due {dueDate} ({daysOverdue}d ago)."
    final s = await render(tester,
        (l) => l.lwNotifRepaymentOverdueDetail('AM', 'DO', 'DD', 'NU'));
    expect(s, 'Installment #NU of AM was due DD (DOd ago).');
  });

  testWidgets('lwNotifStaleSyncTitle(days, name)', (tester) async {
    // template: "{name} last synced {days}d ago"
    final s = await render(tester, (l) => l.lwNotifStaleSyncTitle('DAYS', 'NM'));
    expect(s, 'NM last synced DAYSd ago');
  });
}
