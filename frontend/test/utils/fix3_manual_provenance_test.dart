import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/transaction_display.dart';

// fix-3 regressions: manual transactions must display the user's typed
// text verbatim — the Plaid-noise normaliser (case-folding, reference-code
// stripping) applies only to synced/bank-sourced rows. Previously
// "CRITIC TEST coffee" was silently re-cased to "Critic TEST coffee".
void main() {
  group('displayLabel manual provenance (fix-3)', () {
    test('manual row keeps typed caps verbatim', () {
      final tx = <String, dynamic>{
        'source': 'manual',
        'description': 'CRITIC TEST coffee',
        'amount': -4.5,
      };
      expect(displayLabel(tx), 'CRITIC TEST coffee');
    });

    test('manual row keeps separators the user typed', () {
      final tx = <String, dynamic>{
        'source': 'manual',
        'description': 'coffee * snacks - MISC2026',
        'amount': -10.0,
      };
      // The Plaid cleaner would rewrite '*' and drop 'MISC2026' as a
      // reference code — manual text must survive untouched.
      expect(displayLabel(tx), 'coffee * snacks - MISC2026');
    });

    test('plaid row is still normalised', () {
      final tx = <String, dynamic>{
        'source': 'plaid',
        'description': 'AMAZON.COM*XJ9R7K8',
        'amount': -20.0,
      };
      expect(displayLabel(tx), 'Amazon.com');
    });

    test('absent source still cleans (bank-shaped data, unknown origin)', () {
      // No provenance claim is made in the UI for these rows, but the
      // display cleaner keeps its historical behaviour for them.
      final tx = <String, dynamic>{
        'description': 'STARBUCKS COFFEE',
        'amount': -6.0,
      };
      expect(displayLabel(tx), 'Starbucks Coffee');
    });

    test('user_description always wins verbatim regardless of source', () {
      final tx = <String, dynamic>{
        'source': 'plaid',
        'description': 'AMAZON.COM*XJ9R7K8',
        'user_description': 'GIFT for Ana',
        'amount': -20.0,
      };
      expect(displayLabel(tx), 'GIFT for Ana');
    });
  });
}
