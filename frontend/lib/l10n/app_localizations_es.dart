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
  String get commonRequired => 'Obligatorio';

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

  @override
  String get authSignInToContinue => 'Inicia sesión para continuar';

  @override
  String get authUsername => 'Usuario';

  @override
  String get authPassword => 'Contraseña';

  @override
  String get authSignIn => 'Iniciar sesión';

  @override
  String get authSignInWithPasskey => 'Iniciar sesión con passkey';

  @override
  String get authForgotPassword => '¿Olvidaste tu contraseña?';

  @override
  String get authEnterUsernameFirst => 'Primero ingresa tu usuario.';

  @override
  String get statNetWorth => 'Patrimonio neto';

  @override
  String get statAssets => 'Activos';

  @override
  String get statLiabilities => 'Pasivos';

  @override
  String get statCash => 'Efectivo';

  @override
  String get statInvestments => 'Inversiones';

  @override
  String get lendingTitle => 'Dinero que presté';

  @override
  String get lendingAddLoan => 'Agregar préstamo';

  @override
  String get lendingOutstanding => 'Pendiente';

  @override
  String get lendingTotalLent => 'Total prestado';

  @override
  String get lendingActive => 'Activos';

  @override
  String get lendingInterestEarned => 'Intereses ganados';

  @override
  String get lendingRepaid => 'Reembolsado';

  @override
  String get lendingNoLoans => 'Aún no hay préstamos';

  @override
  String get lendingEmptySubtitle =>
      '¿Le prestaste a un amigo? Agrégalo aquí y luego selecciona las transacciones bancarias que lo fondearon y lo pagaron.';
}
