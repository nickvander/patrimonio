import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/supported_banks.dart';

void main() {
  group('kSupportedMxBanks — single source of truth', () {
    test('lists exactly the advertised institutions with a validated parser', () {
      // Banks whose parsers were built/validated against real statements
      // (see backend/src/services/parser/mod.rs dispatch).
      expect(kSupportedMxBanks, [
        'Nu México',
        'Banamex',
        'Banorte',
        'Scotiabank',
        'Cetesdirecto',
        'HealthEquity',
        'Fidelity NetBenefits',
      ]);
    });

    test('omits banks we have no parser for', () {
      // These have no backend parser — advertising them is the trust bug this
      // constant prevents.
      for (final unsupported in ['Inbursa', 'Afirme', 'Banco Azteca']) {
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
        'Nu México, Banamex, Banorte, Scotiabank, Cetesdirecto, HealthEquity, or Fidelity NetBenefits',
      );
    });

    test('mentions supported banks, never the unsupported ones', () {
      final sentence = supportedMxBanksSentence();
      expect(sentence, contains('Nu'));
      expect(sentence, contains('Banorte'));
      expect(sentence, contains('Cetesdirecto'));
      expect(sentence, isNot(contains('Inbursa')));
      expect(sentence, isNot(contains('Afirme')));
    });
  });
}
