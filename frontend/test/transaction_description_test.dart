import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/transaction_description.dart';

void main() {
  group('cleanTransactionDescription', () {
    test('returns empty string for null or whitespace', () {
      expect(cleanTransactionDescription(null), '');
      expect(cleanTransactionDescription('   '), '');
    });

    test('title-cases ALL-CAPS merchants', () {
      expect(
        cleanTransactionDescription('MCDONALDS RESTAURANT'),
        'Mcdonalds Restaurant',
      );
    });

    test('preserves short ALL-CAPS acronyms', () {
      expect(
        cleanTransactionDescription('ACH DEBIT VERIZON WIRELESS'),
        'ACH Debit Verizon Wireless',
      );
      expect(
        cleanTransactionDescription('PIN PURCHASE STARBUCKS'),
        'PIN Purchase Starbucks',
      );
    });

    test('normalises Plaid `*` separator', () {
      expect(
        cleanTransactionDescription('PAYPAL *NETFLIX'),
        'Paypal Netflix',
      );
    });

    test('drops alphanumeric reference codes', () {
      // XJ9R7K8 is a 7-char ALL-CAPS code with digits → drop.
      final out = cleanTransactionDescription('AMAZON XJ9R7K8 PURCHASE');
      expect(out, 'Amazon Purchase');
    });

    test('keeps mixed-case brand names intact', () {
      // "Amzn.com/billWA" is informational and we should not pretend to know
      // better than the bank — just leave it.
      final raw = 'Amazon.com*Amzn.com/billWA';
      final out = cleanTransactionDescription(raw);
      expect(out.contains('Amazon.com'), isTrue);
      expect(out.contains('Amzn.com/billWA'), isTrue);
    });

    test('collapses multiple internal spaces', () {
      expect(
        cleanTransactionDescription('STARBUCKS   STORE'),
        'Starbucks Store',
      );
    });

    test('title-cases dotted abbreviations correctly', () {
      // AMZN.COM should become Amzn.com, not "Amzn.Com".
      expect(
        cleanTransactionDescription('AMZN.COM ORDER'),
        'Amzn.com Order',
      );
    });

    test('leaves already-readable strings alone', () {
      expect(
        cleanTransactionDescription('Spotify Premium'),
        'Spotify Premium',
      );
    });

    test('falls back to normalised input when every token is dropped', () {
      // Pathological: all tokens look like reference codes. We still return
      // something rather than an empty string.
      final out = cleanTransactionDescription('AB12CD EF34GH IJ56KL');
      expect(out.isNotEmpty, isTrue);
    });
  });
}
