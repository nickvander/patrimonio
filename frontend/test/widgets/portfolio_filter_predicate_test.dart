import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/widgets/portfolio_card.dart';

// Dimension-scoped filter parsing (contract C3): the allocation heatmap
// emits "asset:<canonical class>" / "account_type:<raw>" /
// "institution:<raw>", and each prefix must match ONLY its own field —
// the dossier's repro was a bonds-typed *account* making a Bonds band tap
// match everything. Bare values keep the legacy any-field OR as fallback.

Map<String, dynamic> _h({
  String assetClass = '',
  String holdingType = '',
  String accountType = '',
  String institution = '',
}) =>
    {
      'symbol': 'X',
      'asset_class': assetClass,
      'holding_type': holdingType,
      'account_type': accountType,
      'institution_name': institution,
    };

void main() {
  group('holdingMatchesCategoryFilter', () {
    test('null / empty filter passes everything', () {
      expect(holdingMatchesCategoryFilter(_h(), null), isTrue);
      expect(holdingMatchesCategoryFilter(_h(), ''), isTrue);
      expect(holdingMatchesCategoryFilter(_h(), '   '), isTrue);
    });

    test('asset: matches only the canonical asset_class', () {
      final bondFund = _h(
          assetClass: 'bonds',
          holdingType: 'mutual fund',
          accountType: 'brokerage');
      final equity = _h(assetClass: 'equity', holdingType: 'etf');
      expect(holdingMatchesCategoryFilter(bondFund, 'asset:bonds'), isTrue);
      expect(holdingMatchesCategoryFilter(equity, 'asset:bonds'), isFalse);
      expect(holdingMatchesCategoryFilter(equity, 'asset:equity'), isTrue);
    });

    test('asset: ignores a bonds-typed ACCOUNT (the match-everything repro)',
        () {
      // Equity holding living inside an account whose type is "bonds":
      // must NOT pass an asset:bonds filter.
      final equityInBondsAccount = _h(
          assetClass: 'equity', holdingType: 'stock', accountType: 'bonds');
      expect(
          holdingMatchesCategoryFilter(equityInBondsAccount, 'asset:bonds'),
          isFalse);
    });

    test('account_type: matches only account_type', () {
      final inIra = _h(accountType: 'ira', institution: 'Vanguard');
      final iraNamedInstitution = _h(accountType: 'brokerage', institution: 'ira');
      expect(holdingMatchesCategoryFilter(inIra, 'account_type:ira'), isTrue);
      expect(
          holdingMatchesCategoryFilter(
              iraNamedInstitution, 'account_type:ira'),
          isFalse);
    });

    test('institution: matches only institution_name, case-insensitively', () {
      final vanguard = _h(institution: 'Vanguard', accountType: 'ira');
      expect(
          holdingMatchesCategoryFilter(vanguard, 'institution:Vanguard'),
          isTrue);
      expect(
          holdingMatchesCategoryFilter(vanguard, 'institution:vanguard'),
          isTrue);
      expect(
          holdingMatchesCategoryFilter(vanguard, 'institution:Fidelity'),
          isFalse);
      expect(holdingMatchesCategoryFilter(vanguard, 'account_type:vanguard'),
          isFalse);
    });

    test('institution values with spaces stay scoped to their dimension', () {
      final schwab = _h(institution: 'Charles Schwab');
      expect(
          holdingMatchesCategoryFilter(
              schwab, 'institution:Charles Schwab'),
          isTrue);
    });

    test('bare value falls back to legacy any-field OR', () {
      expect(
          holdingMatchesCategoryFilter(_h(holdingType: 'bonds'), 'bonds'),
          isTrue);
      expect(
          holdingMatchesCategoryFilter(_h(accountType: 'bonds'), 'bonds'),
          isTrue);
      expect(
          holdingMatchesCategoryFilter(_h(institution: 'Vanguard'), 'Vanguard'),
          isTrue);
      expect(holdingMatchesCategoryFilter(_h(holdingType: 'etf'), 'bonds'),
          isFalse);
    });

    test('unknown prefix falls back to legacy exact match on the whole value',
        () {
      // Not a known dimension — treated as a bare value, so only an exact
      // whole-string field match passes.
      expect(
          holdingMatchesCategoryFilter(
              _h(holdingType: 'bonds'), 'sector:bonds'),
          isFalse);
      expect(
          holdingMatchesCategoryFilter(
              _h(institution: 'sector:bonds'), 'sector:bonds'),
          isTrue);
    });

    test('colon after the first space is not a dimension prefix', () {
      // Legacy institution names can themselves contain a colon.
      final odd = _h(institution: 'Banco Azteca: Premium');
      expect(
          holdingMatchesCategoryFilter(odd, 'Banco Azteca: Premium'), isTrue);
    });
  });

  group('categoryFilterLabel', () {
    test('strips known prefixes and title-cases', () {
      expect(categoryFilterLabel('asset:bonds'), 'Bonds');
      expect(categoryFilterLabel('account_type:ira'), 'Ira');
      expect(categoryFilterLabel('institution:charles schwab'),
          'Charles Schwab');
    });

    test('bare and unknown-prefix values are only title-cased', () {
      expect(categoryFilterLabel('bonds'), 'Bonds');
      expect(categoryFilterLabel('sector:tech'), 'Sector:tech');
    });
  });
}
