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
    WidgetTester tester,
    String Function(AppLocalizations l) pick, {
    Locale locale = const Locale('en'),
  }) async {
    late String out;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            out = pick(AppLocalizations.of(context));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return out;
  }

  // Renders [pick] in en AND es and pins both outputs, so a transposition
  // that only manifests in one locale's template still fails.
  Future<void> expectBoth(
    WidgetTester tester,
    String Function(AppLocalizations l) pick, {
    required String en,
    required String es,
  }) async {
    expect(await render(tester, pick), en);
    expect(await render(tester, pick, locale: const Locale('es')), es);
  }

  testWidgets('taxHarvestFooterFlow(carryforward, gains, ordinary)', (
    tester,
  ) async {
    // template: "{gains} taxable gains remain, {ordinary} offset ..., {carryforward} carried forward"
    final s = await render(
      tester,
      (l) => l.taxHarvestFooterFlow('CF', 'GA', 'OR'),
    );
    expect(
      s,
      'GA taxable gains remain, OR offset against income, '
      'CF carried forward',
    );
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
        tester,
        (l) => l.txTransferImpliedRate('DA', 'DC', 'RT', 'SA', 'SC'),
      );
      expect(s, 'SA → DA · implied RT DC/SC');
    },
  );

  testWidgets(
    'lwNotifRepaymentOverdueDetail(amount, daysOverdue, dueDate, number)',
    (tester) async {
      // template: "Installment #{number} of {amount} was due {dueDate} ({daysOverdue}d ago)."
      final s = await render(
        tester,
        (l) => l.lwNotifRepaymentOverdueDetail('AM', 'DO', 'DD', 'NU'),
      );
      expect(s, 'Installment #NU of AM was due DD (DOd ago).');
    },
  );

  testWidgets('lwNotifStaleSyncTitle(days, name)', (tester) async {
    // template: "{name} last synced {days}d ago"
    final s = await render(
      tester,
      (l) => l.lwNotifStaleSyncTitle('DAYS', 'NM'),
    );
    expect(s, 'NM last synced DAYSd ago');
  });

  testWidgets('projTooltipYearAmount(amount, year)', (tester) async {
    // U1 template: "{year} · {amount}" — synthesized placeholders, so the
    // generated signature is alphabetical: (amount, year), amount FIRST.
    final s = await render(tester, (l) => l.projTooltipYearAmount('AMT', 'YR'));
    expect(s, 'YR · AMT');
  });

  testWidgets('projValueEntryRange(min, max)', (tester) async {
    // U2 template: "Enter an amount between {min} and {max}" — explicit arb
    // placeholders keep the declaration order (min, max), NOT alphabetical.
    final s = await render(tester, (l) => l.projValueEntryRange('MIN', 'MAX'));
    expect(s, 'Enter an amount between MIN and MAX');
  });

  testWidgets('projMxRateLine(now, retire)', (tester) async {
    // MX scenario template: "USD/MXN {now} today → ≈{retire} at retirement".
    // Alphabetical (now, retire) happens to equal the template order — this
    // pin catches any future rename that breaks that coincidence.
    final s = await render(tester, (l) => l.projMxRateLine('NOW', 'RET'));
    expect(s, 'USD/MXN NOW today → ≈RET at retirement');
  });

  // ---------------------------------------------------------------------
  // Audit round 2: every remaining metadata-less multi-placeholder key whose
  // alphabetical signature differs from its template order AND whose
  // adjacent args share a type. Each is pinned in BOTH locales with
  // distinguishable sentinels so a transposition fails either assertion.
  // ---------------------------------------------------------------------

  testWidgets('txRenamedNFailed(failed, ok)', (tester) async {
    // template: "Renamed {ok} · {failed} failed" — alphabetical puts
    // failed FIRST, the reverse of reading order.
    await expectBoth(
      tester,
      (l) => l.txRenamedNFailed('FA', 'OK'),
      en: 'Renamed OK · FA failed',
      es: 'Se renombraron OK · FA con error',
    );
  });

  testWidgets('txUpdatedNFailed(failed, ok)', (tester) async {
    // template: "Updated {ok} · {failed} failed"
    await expectBoth(
      tester,
      (l) => l.txUpdatedNFailed('FA', 'OK'),
      en: 'Updated OK · FA failed',
      es: 'Se actualizaron OK · FA con error',
    );
  });

  testWidgets('dpSplitCredit(amount, count)', (tester) async {
    // template: "{count} credit · {amount}" — alphabetical is (amount, count).
    await expectBoth(
      tester,
      (l) => l.dpSplitCredit('AM', 'CT'),
      en: 'CT credit · AM',
      es: 'CT crédito · AM',
    );
  });

  testWidgets('dpSplitLoan(amount, count)', (tester) async {
    // template: "{count} loans · {amount}"
    await expectBoth(
      tester,
      (l) => l.dpSplitLoan('AM', 'CT'),
      en: 'CT loans · AM',
      es: 'CT préstamos · AM',
    );
  });

  testWidgets('dashFxPill(base, rate, target)', (tester) async {
    // template: "{base}/{target} {rate}" — rate and target swap between
    // template and alphabetical order.
    await expectBoth(
      tester,
      (l) => l.dashFxPill('BA', 'RT', 'TG'),
      en: 'BA/TG RT',
      es: 'BA/TG RT',
    );
  });

  testWidgets('dashWebhookPartial(failed, updated)', (tester) async {
    // template: "{updated} updated, {failed} failed" — alphabetical is
    // the reverse.
    await expectBoth(
      tester,
      (l) => l.dashWebhookPartial('FA', 'UP'),
      en: 'UP updated, FA failed',
      es: 'UP actualizadas, FA con error',
    );
  });

  testWidgets('dashTransfersLinked(checked, inserted)', (tester) async {
    // template: "Linked {inserted} transfer pair(s) (checked {checked}
    // candidates)" — alphabetical is the reverse.
    await expectBoth(
      tester,
      (l) => l.dashTransfersLinked('CH', 'IN'),
      en: 'Linked IN transfer pair(s) (checked CH candidates)',
      es:
          'Se vincularon IN par(es) de transferencias '
          '(se revisaron CH candidatos)',
    );
  });

  testWidgets('pfGoalHitBy(amount, remaining, year)', (tester) async {
    // template: "Hit {amount} by {year} · {remaining}" — remaining and
    // year swap between template and alphabetical order.
    await expectBoth(
      tester,
      (l) => l.pfGoalHitBy('AM', 'RM', 'YR'),
      en: 'Hit AM by YR · RM',
      es: 'Alcanzar AM para YR · RM',
    );
  });

  testWidgets('pfGoalOnPaceFor(rate, when)', (tester) async {
    // template: "on pace for ~{when} at +{rate}/mo" — alphabetical is
    // the reverse.
    await expectBoth(
      tester,
      (l) => l.pfGoalOnPaceFor('RT', 'WH'),
      en: 'on pace for ~WH at +RT/mo',
      es: 'en camino para ~WH a +RT/mes',
    );
  });

  testWidgets('pfInstDescriptor(descriptor, inst)', (tester) async {
    // template: "{inst} · {descriptor}" — alphabetical is the reverse.
    await expectBoth(
      tester,
      (l) => l.pfInstDescriptor('DE', 'IN'),
      en: 'IN · DE',
      es: 'IN · DE',
    );
  });

  testWidgets('lwNotifRepaymentDueDetail(amount, dueDate, number)', (
    tester,
  ) async {
    // template: "Installment #{number} of {amount} due {dueDate}." —
    // number renders FIRST but sits LAST alphabetically.
    await expectBoth(
      tester,
      (l) => l.lwNotifRepaymentDueDetail('AM', 'DD', 'NU'),
      en: 'Installment #NU of AM due DD.',
      es: 'Cuota #NU de AM vence el DD.',
    );
  });

  testWidgets('lwNotifRepaymentDueTodayDetail(amount, number)', (tester) async {
    // template: "Installment #{number} of {amount} is due today."
    await expectBoth(
      tester,
      (l) => l.lwNotifRepaymentDueTodayDetail('AM', 'NU'),
      en: 'Installment #NU of AM is due today.',
      es: 'Cuota #NU de AM vence hoy.',
    );
  });

  testWidgets('lwTrendsSemanticMonth(income, month, spending)', (tester) async {
    // template: "{month}: income {income}, spending {spending}" — month
    // renders first but income leads alphabetically. Screen-reader-only,
    // which is exactly why a swap would otherwise go unnoticed.
    await expectBoth(
      tester,
      (l) => l.lwTrendsSemanticMonth('IC', 'MO', 'SP'),
      en: 'MO: income IC, spending SP',
      es: 'MO: ingresos IC, gastos SP',
    );
  });

  testWidgets('impFoundWithAutoDeselected(count, message)', (tester) async {
    // template: "{message} ({count} auto-deselected as informational)" —
    // alphabetical is the reverse.
    await expectBoth(
      tester,
      (l) => l.impFoundWithAutoDeselected('CT', 'ME'),
      en: 'ME (CT auto-deselected as informational)',
      es: 'ME (CT deseleccionados automáticamente por ser informativos)',
    );
  });

  testWidgets('cfBudgetsOverAlert(count, amount) — metadata order', (
    tester,
  ) async {
    // This key HAS a placeholders block, so the generated signature keeps
    // the DECLARATION order (int count, String amount) — not alphabetical.
    // Pinned here because both orders currently coincide only by luck of
    // the declaration; a metadata reorder would silently transpose.
    await expectBoth(
      tester,
      (l) => l.cfBudgetsOverAlert(2, 'AM'),
      en: 'Over budget in 2 — AM over total',
      es: 'Sobre presupuesto en 2 — AM de más',
    );
  });
}
