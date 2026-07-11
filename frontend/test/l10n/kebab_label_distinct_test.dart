import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// F16: the dashboard header kebab and the bottom-nav "More" tab used to
// share the same accessible name ("More"), so screen-reader users couldn't
// tell them apart. The kebab now carries its own distinct label.

void main() {
  test('en: kebab label is "Options" and distinct from the nav tab', () async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(l.dashOptionsTooltip, 'Options');
    expect(l.dashOptionsTooltip, isNot(l.navMore));
  });

  test('es: kebab label is "Opciones" and distinct from the nav tab',
      () async {
    final l = await AppLocalizations.delegate.load(const Locale('es'));
    expect(l.dashOptionsTooltip, 'Opciones');
    expect(l.dashOptionsTooltip, isNot(l.navMore));
  });
}
