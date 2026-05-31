// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Patrimonio';

  @override
  String get navOverview => 'Resumen';

  @override
  String get navPortfolio => 'Portafolio';

  @override
  String get navTransactions => 'Transacciones';

  @override
  String get navCashFlow => 'Flujo de efectivo';

  @override
  String get navProjections => 'Proyecciones';

  @override
  String get navTaxPlanning => 'Planeación fiscal';

  @override
  String get navLending => 'Préstamos';

  @override
  String get navSettings => 'Configuración';

  @override
  String get navShortOverview => 'Inicio';

  @override
  String get navShortPortfolio => 'Cartera';

  @override
  String get navShortTransactions => 'Actividad';

  @override
  String get navShortCashFlow => 'Efectivo';

  @override
  String get navShortProjections => 'Proy.';

  @override
  String get navShortTaxPlanning => 'Fiscal';

  @override
  String get navShortLending => 'Préstamos';

  @override
  String get navShortSettings => 'Ajustes';

  @override
  String get navMore => 'Más';

  @override
  String get navMoreGroup => 'MÁS';

  @override
  String get actionAdd => 'Agregar';

  @override
  String get actionCancel => 'Cancelar';

  @override
  String get actionSave => 'Guardar';

  @override
  String get actionApply => 'Aplicar';

  @override
  String get actionDelete => 'Eliminar';

  @override
  String get actionClose => 'Cerrar';

  @override
  String get searchTransactionsHint => 'Buscar transacciones…';

  @override
  String get languageLabel => 'Idioma';

  @override
  String get languageEnglish => 'Inglés';

  @override
  String get languageSpanish => 'Español';

  @override
  String currencyToggleTooltip(String code) {
    return 'Mostrando en $code · toca para cambiar';
  }
}
