import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/supported_banks.dart';

void main() {
  group('kSupportedMxBanks — single source of truth', () {
    test('lists exactly the institutions with a live backend parser', () {
      // Mirrors backend/src/services/parser/mod.rs: nu_mexico, banamex, cetes.
      expect(kSupportedMxBanks, ['Nu México', 'Banamex', 'Cetesdirecto']);
    });

    test('omits every bank that has no parser', () {
      // These appeared in the old onboarding hero but cannot be imported —
      // advertising them is the trust bug this constant prevents.
      for (final unsupported in ['Bancomer', 'Santander', 'Banorte']) {
        expect(
          kSupportedMxBanks.any((b) => b.contains(unsupported)),
          isFalse,
          reason: '$unsupported has no parser and must not be advertised',
        );
      }
    });
  });

  group('supportedMxBanksSentence — shared copy', () {
    test('renders an Oxford-style list of the supported set', () {
      // Both the onboarding hero and the import screen interpolate this
      // exact string, so asserting it here guards both call sites at once.
      expect(
        supportedMxBanksSentence(),
        'Nu México, Banamex, or Cetesdirecto',
      );
    });

    test('mentions Nu and Cetesdirecto, never the unsupported banks', () {
      final sentence = supportedMxBanksSentence();
      expect(sentence, contains('Nu'));
      expect(sentence, contains('Cetesdirecto'));
      expect(sentence, isNot(contains('Bancomer')));
      expect(sentence, isNot(contains('Santander')));
      expect(sentence, isNot(contains('Banorte')));
    });
  });
}
