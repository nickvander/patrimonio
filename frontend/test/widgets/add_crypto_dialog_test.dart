import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/widgets/add_crypto_dialog.dart';

// We construct AddCryptoDialog directly (it builds an ApiService internally,
// which is VM-safe via the conditional api_platform export) but never call
// the network. Per MEMORY we do NOT subclass ApiService. These tests only
// assert rendered copy + that the help link is tappable without throwing.
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('Bitso dialog renders Bitso-named copy + tappable help link',
      (tester) async {
    await tester.pumpWidget(_host(
      AddCryptoDialog(exchange: 'bitso', onLinked: () {}),
    ));

    expect(find.text('Link Bitso'), findsOneWidget);
    expect(find.textContaining('Bitso settings'), findsOneWidget);
    expect(find.textContaining('My Bitso'), findsOneWidget);

    final link = find.text('Where do I find my API keys? ↗');
    expect(link, findsOneWidget);
    // Tapping must not throw even with no URL handler registered in the
    // test environment — the fallback dialog path swallows the failure.
    await tester.tap(link);
    await tester.pump();
  });

  testWidgets('Coinbase dialog renders Coinbase-named copy, not Bitso',
      (tester) async {
    await tester.pumpWidget(_host(
      AddCryptoDialog(exchange: 'coinbase', onLinked: () {}),
    ));

    expect(find.text('Link Coinbase'), findsOneWidget);
    expect(find.textContaining('Coinbase settings'), findsOneWidget);
    expect(find.textContaining('My Coinbase'), findsOneWidget);
    // The old hardcoded "Bitso" copy must not leak into the Coinbase dialog.
    expect(find.textContaining('Bitso'), findsNothing);
  });
}
