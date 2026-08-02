import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/account_category.dart';

void main() {
  group('categorizeAccount', () {
    test('null + empty fall through to other', () {
      expect(categorizeAccount(null), AccountCategory.other);
      expect(categorizeAccount(''), AccountCategory.other);
      expect(categorizeAccount('   '), AccountCategory.other);
    });

    group('cash variants', () {
      for (final t in [
        'Checking',
        'savings',
        'Cash management',
        'CD',
        'Cash',
        // Plaid's broad TYPE (subtypes: checking/savings/CD/…) — written by
        // the bootstrap/test path and importers; must bucket as cash, not
        // fall through to Other (that leak zeroed the Cash tile and
        // produced an "Other" group for depository accounts).
        'depository',
        'Depository',
      ]) {
        test('"$t" → cash', () {
          expect(categorizeAccount(t), AccountCategory.cash);
        });
      }
    });

    group('investment variants — Plaid + manual', () {
      for (final t in [
        'IRA',
        'roth 401k',
        '403b',
        'HSA',
        'Brokerage',
        'Investment',
        'Stock Plan',
        'ESOP',
        'pension',
        'RSU',
        'Mutual Fund',
        'SEP-IRA',
        '529',
      ]) {
        test('"$t" → investment', () {
          expect(categorizeAccount(t), AccountCategory.investment);
        });
      }
    });

    group('credit + crypto', () {
      test('credit card', () {
        expect(categorizeAccount('Credit Card'), AccountCategory.credit);
        expect(categorizeAccount('credit'), AccountCategory.credit);
      });
      test('crypto', () {
        expect(categorizeAccount('crypto'), AccountCategory.crypto);
        expect(categorizeAccount('Crypto wallet'), AccountCategory.crypto);
      });
    });

    group('loans', () {
      for (final t in ['Mortgage', 'Loan', 'Student Loan', 'Auto Loan']) {
        test('"$t" → loan', () {
          expect(categorizeAccount(t), AccountCategory.loan);
        });
      }
    });

    group('real assets — manual non-financial', () {
      // The new category. Every label exposed in the add-account
      // dialog's "Real assets" section MUST map here, so a user
      // picking "Vehicle" finds their car under "Real assets" and
      // not "Other" or "Loans".
      for (final t in [
        'Real Estate',
        'real estate',
        'Vehicle',
        'vehicle',
        'Auto', // bare token, not "auto loan"
        'Car',
        'Private Equity',
        'private equity',
        'Collectibles',
        'collectible',
        'Other Asset',
        'Property',
      ]) {
        test('"$t" → realAsset', () {
          expect(categorizeAccount(t), AccountCategory.realAsset);
        });
      }

      test('does NOT collide with auto-loan', () {
        // "auto loan" must remain a liability, not a real asset.
        // The contains() ordering in account_category.dart matters:
        // loan-side checks run BEFORE real-asset checks.
        expect(categorizeAccount('Auto Loan'), AccountCategory.loan);
        expect(categorizeAccount('auto loan'), AccountCategory.loan);
      });

      test('does NOT collide with checking/savings substrings', () {
        // No real-asset keyword appears in cash labels; sanity check.
        expect(categorizeAccount('Checking Account'), AccountCategory.cash);
      });

      test('"other liability" stays in "other" (it is not realAsset)', () {
        // The dialog exposes "Other Liability" alongside "Other
        // Asset"; we deliberately don't bucket the liability variant
        // into realAsset. (It falls to AccountCategory.other today
        // since "other liability" doesn't match any keyword — the
        // dashboard's net worth aggregation handles it server-side
        // regardless.)
        expect(categorizeAccount('Other Liability'), AccountCategory.other);
      });
    });
  });
}
