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

  @override
  String get txOverrideCleared => 'Se quitó el nombre personalizado';

  @override
  String get txRenamed => 'Renombrado';

  @override
  String txRenameFailed(Object error) {
    return 'No se pudo renombrar: $error';
  }

  @override
  String get txRenameFailedShort => 'No se pudo renombrar';

  @override
  String get txFlowExpense => 'Gasto';

  @override
  String get txFlowIncome => 'Ingreso';

  @override
  String get txFlowAll => 'Todos';

  @override
  String get txFlow => 'Flujo';

  @override
  String get txStatusPending => 'Pendiente';

  @override
  String get txStatusSettled => 'Liquidada';

  @override
  String get txStatusAll => 'Todas';

  @override
  String get txStatus => 'Estado';

  @override
  String get txClearAll => 'Limpiar todo';

  @override
  String get txEmptyTitle => 'Aún no hay movimientos';

  @override
  String get txEmptyBody =>
      'Vincula un banco, importa un estado de cuenta o agrega una cuenta manualmente\npara empezar a ver actividad aquí.';

  @override
  String get txAddAccount => 'Agregar una cuenta';

  @override
  String txShowingCount(Object shown, Object total) {
    return 'Mostrando $shown de $total';
  }

  @override
  String get txLoadMore => 'Cargar más';

  @override
  String get txSelectAll => 'Seleccionar todo';

  @override
  String get txDeselectAll => 'Quitar selección';

  @override
  String get txSetCategory => 'Asignar categoría';

  @override
  String get txMoveAccount => 'Cambiar de cuenta';

  @override
  String get txRename => 'Renombrar';

  @override
  String get txClear => 'Limpiar';

  @override
  String txSelectedCount(Object count) {
    return '$count seleccionadas';
  }

  @override
  String get txCategoryHint => 'p. ej. Restaurantes';

  @override
  String txRenameNTitle(Object count) {
    return 'Renombrar $count movimientos';
  }

  @override
  String get txNewDescription => 'Nueva descripción';

  @override
  String get txRenameHint => 'p. ej. Renta — marzo';

  @override
  String txDeleteNTitle(Object count) {
    return '¿Eliminar $count movimientos?';
  }

  @override
  String get txBulkDeleteBody =>
      'Se quitarán de tus listas y totales. Una sincronización futura podría volver a importar los movimientos vinculados al banco.';

  @override
  String txDeletingN(Object count) {
    return 'Eliminando $count movimientos…';
  }

  @override
  String txDeletedN(Object count) {
    return 'Se eliminaron $count movimientos';
  }

  @override
  String get txDeleteSomeFailed =>
      'No se pudieron eliminar algunos movimientos';

  @override
  String get txMoveToAccount => 'Mover a la cuenta';

  @override
  String txSplitIntoN(Object count) {
    return 'Dividido en $count partes';
  }

  @override
  String txSplitFailed(Object error) {
    return 'No se pudo dividir: $error';
  }

  @override
  String get txSplitChildrenNotFound =>
      'No se encontraron las partes de la división para editar.';

  @override
  String txSplitUpdatedN(Object count) {
    return 'División actualizada ($count partes)';
  }

  @override
  String txEditSplitFailed(Object error) {
    return 'No se pudo editar la división: $error';
  }

  @override
  String get txRenameTransaction => 'Renombrar movimiento';

  @override
  String get txRenameDisplayLabelHelp =>
      'Solo es la etiqueta visible. La descripción original del banco se conserva y sigue visible en el panel de detalle de esta fila, en \"Texto original del banco\".';

  @override
  String get txDisplayLabel => 'Etiqueta visible';

  @override
  String get txDisplayLabelHint => 'p. ej. Renta — Juan';

  @override
  String txAlsoApplyToN(Object count) {
    return 'Aplicar también a $count movimientos coincidentes';
  }

  @override
  String get txAlsoApplySubtitle =>
      'Filas que comparten esta descripción original del banco.';

  @override
  String get txClearOverride => 'Quitar nombre personalizado';

  @override
  String txRenamedN(Object count) {
    return 'Se renombraron $count movimientos';
  }

  @override
  String txRenamedNFailed(Object failed, Object ok) {
    return 'Se renombraron $ok · $failed con error';
  }

  @override
  String txUpdatingN(Object count) {
    return 'Actualizando $count movimientos…';
  }

  @override
  String txUpdatedN(Object count) {
    return 'Se actualizaron $count movimientos';
  }

  @override
  String txUpdatedNFailed(Object failed, Object ok) {
    return 'Se actualizaron $ok · $failed con error';
  }

  @override
  String get txCloseSearch => 'Cerrar búsqueda';

  @override
  String get txRecentTransactions => 'Movimientos recientes';

  @override
  String get txFilterTransactions => 'Filtrar movimientos';

  @override
  String get txExitSelectionMode => 'Salir del modo de selección';

  @override
  String get txSelectMultiple => 'Seleccionar varios';

  @override
  String get txAddTransaction => 'Agregar movimiento';

  @override
  String get txExportCsv => 'Exportar CSV';

  @override
  String get txScanTransfers =>
      'Buscar transferencias entre divisas (Wise / Remitly / etc.)';

  @override
  String get txSearchTransactions => 'Buscar movimientos';

  @override
  String get txDateToday => 'Hoy';

  @override
  String get txDateYesterday => 'Ayer';

  @override
  String get txInlineEditHint => 'Nueva etiqueta · Enter para guardar';

  @override
  String get txSplitPill => 'División';

  @override
  String get txDismiss => 'Cerrar';

  @override
  String txRenamePlusMatching(Object count) {
    return 'Renombrar (+$count coincidentes)';
  }

  @override
  String get txOutflow => 'SALIDA';

  @override
  String get txInflow => 'ENTRADA';

  @override
  String txApproxEstimated(Object amount) {
    return '≈ $amount (estimado)';
  }

  @override
  String get txRawBankText => 'Texto original del banco';

  @override
  String get txCategoryAndNotes => 'Categoría y notas';

  @override
  String get txCategory => 'Categoría';

  @override
  String txCategoryExample(Object category) {
    return 'p. ej. $category';
  }

  @override
  String get txNotes => 'Notas';

  @override
  String get txNotesHint => '¿Por qué es importante este movimiento?';

  @override
  String get txRecentAtMerchant => 'Recientes en este comercio';

  @override
  String txMerchantTotal(Object amount, Object count) {
    return 'Total: $amount en $count movimientos';
  }

  @override
  String get txMoveToDifferentAccount => 'Mover a otra cuenta';

  @override
  String txMoveFailed(Object error) {
    return 'No se pudo mover: $error';
  }

  @override
  String get txSplitThisTransaction => 'Dividir este movimiento';

  @override
  String get txEditSplit => 'Editar división';

  @override
  String get txSplitRemoved => 'División eliminada';

  @override
  String txUnsplitFailed(Object error) {
    return 'No se pudo deshacer la división: $error';
  }

  @override
  String get txUnsplitRestore => 'Deshacer división (restaurar original)';

  @override
  String get txDeleteOneTitle => '¿Eliminar movimiento?';

  @override
  String get txDeleteOneBody =>
      'Esto elimina el movimiento de forma permanente. Para volver a importarlo desde CSV/PDF tendrás que subir el archivo otra vez.';

  @override
  String txDeleteFailed(Object error) {
    return 'No se pudo eliminar: $error';
  }

  @override
  String get txLinkedTransfer => 'Transferencia entre divisas vinculada';

  @override
  String get txConfirmed => 'Confirmada';

  @override
  String txAutoConfidence(Object confidence) {
    return 'Automática · $confidence%';
  }

  @override
  String txAutoConfidenceKeyword(Object confidence, Object keyword) {
    return 'Automática · $confidence% · $keyword';
  }

  @override
  String txTransferImpliedRate(
    Object dstAmount,
    Object dstCurrency,
    Object rate,
    Object srcAmount,
    Object srcCurrency,
  ) {
    return '$srcAmount → $dstAmount · tipo implícito $rate $dstCurrency/$srcCurrency';
  }

  @override
  String get txConfirm => 'Confirmar';

  @override
  String get txUnlink => 'Desvincular';

  @override
  String get txSourcePlaid => 'Sincronizado con Plaid';

  @override
  String get txSourceCsv => 'Importado (CSV)';

  @override
  String get txSourceManual => 'Captura manual';

  @override
  String get txSourceUnknown => 'Origen desconocido';

  @override
  String get txReassignTo => 'Reasignar a…';

  @override
  String get txMove => 'Mover';

  @override
  String get txDateAllTime => 'Todo el tiempo';

  @override
  String get txDateLast7Days => 'Últimos 7 días';

  @override
  String get txDateLast30Days => 'Últimos 30 días';

  @override
  String get txDateLast90Days => 'Últimos 90 días';

  @override
  String get txDateYtd => 'En lo que va del año';

  @override
  String get txDateLastYear => 'Último año';

  @override
  String get txDateCustomRange => 'Rango personalizado';

  @override
  String get txReset => 'Restablecer';

  @override
  String get txDateRange => 'Rango de fechas';

  @override
  String get txAccounts => 'Cuentas';

  @override
  String get txCategories => 'Categorías';

  @override
  String get txSplitSameAsParentUncategorised =>
      'Igual que el original (sin categoría)';

  @override
  String txSplitSameAsParent(Object category) {
    return 'Igual que el original ($category)';
  }

  @override
  String txSplitExistingCategory(Object category) {
    return '$category  (existente)';
  }

  @override
  String get txSplitTransactionTitle => 'Dividir movimiento';

  @override
  String get txQuickSplit => 'División rápida';

  @override
  String get txSplitEven => 'Dividir en partes iguales…';

  @override
  String txSplitTotal(Object amount, Object kind) {
    return 'Total: $amount $kind';
  }

  @override
  String get txSplitExpenseTag => '(gasto)';

  @override
  String get txSplitIncomeTag => '(ingreso)';

  @override
  String get txSplitDescription => 'Descripción';

  @override
  String get txSplitAmount => 'Importe';

  @override
  String get txSplitRemoveRow => 'Quitar fila';

  @override
  String get txSplitAddRow => 'Agregar fila';

  @override
  String get txSplitMatches => 'Las partes coinciden con el total original.';

  @override
  String txSplitOffBy(Object amount) {
    return 'Difiere por $amount.';
  }

  @override
  String txSplitApproxIn(Object amount, Object currency) {
    return '≈ $amount en $currency';
  }

  @override
  String get txSplitSaveChanges => 'Guardar cambios';

  @override
  String get txSplitSave => 'Guardar división';

  @override
  String get txSplitEvenlyTitle => 'Dividir en partes iguales';

  @override
  String txSplitEvenlyBody(Object count) {
    return 'Dividir el importe original en $count partes iguales.';
  }

  @override
  String get secTitle => 'Seguridad';

  @override
  String get secPasswordSection => 'Contraseña';

  @override
  String get secChangePassword => 'Cambiar contraseña';

  @override
  String get secChangePasswordSubtitle =>
      'Cierra la sesión en todos los demás dispositivos.';

  @override
  String get secTwoFactorSection => 'Autenticación de dos factores';

  @override
  String get secTotpEnabled => 'TOTP activado';

  @override
  String get secAddAuthenticatorApp => 'Agregar una app de autenticación';

  @override
  String get secTotpEnabledSubtitle =>
      'Se te pedirá un código de 6 dígitos cada vez que inicies sesión.';

  @override
  String get secAddAuthenticatorSubtitle =>
      'Escanea un código QR con Authy / Google Authenticator / 1Password.';

  @override
  String get secRecoveryCodesSection => 'Códigos de recuperación';

  @override
  String get secNoCodesLeft => 'No quedan códigos de recuperación';

  @override
  String secFewCodesLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'n',
      one: '',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'Solo queda$_temp0 $count código$_temp1 de recuperación';
  }

  @override
  String get secLowCodesWarningBody =>
      'Si pierdes tu autenticador y te quedas sin códigos, podrías perder el acceso a tu cuenta. Genera nuevos ahora para restablecer el juego completo de 10.';

  @override
  String get secRegenerate => 'Regenerar';

  @override
  String secUnusedCodes(Object count) {
    return '$count códigos sin usar';
  }

  @override
  String get secUnusedCodesSubtitle =>
      'Genera nuevos si pierdes tus códigos guardados; todos los códigos anteriores dejarán de funcionar.';

  @override
  String get secRegenerateCodesTitle =>
      '¿Regenerar los códigos de recuperación?';

  @override
  String get secRegenerateCodesBody =>
      'Tus códigos anteriores dejarán de funcionar de inmediato. Asegúrate de guardar los nuevos antes de cerrar esta ventana.';

  @override
  String get secGenerateNew => 'Generar nuevos';

  @override
  String get secPasswordChangedSnack =>
      'Contraseña cambiada. Se cerraron las demás sesiones.';

  @override
  String get secTwoFactorEnabledSnack =>
      'Autenticación de dos factores activada.';

  @override
  String get secTwoFactorDisabledSnack =>
      'Autenticación de dos factores desactivada.';

  @override
  String get secDisableTwoFactorTitle =>
      '¿Desactivar la autenticación de dos factores?';

  @override
  String get secDisableTwoFactorBody =>
      'Ingresa tu contraseña para confirmar. Desactivar TOTP hace que tu cuenta sea menos segura.';

  @override
  String secFailedWithReason(Object reason) {
    return 'Error: $reason';
  }

  @override
  String get secSignOutSessionTitle => '¿Cerrar esta sesión?';

  @override
  String secSignOutSessionBody(Object device) {
    return 'Esto cerrará la sesión del dispositivo \"$device\" de inmediato. Tendrá que ingresar la contraseña (y el TOTP) para volver a iniciar sesión.';
  }

  @override
  String get secSignOut => 'Cerrar sesión';

  @override
  String get secSessionSignedOutSnack => 'Sesión cerrada.';

  @override
  String get secSignOutThisDeviceTitle => '¿Cerrar sesión en este dispositivo?';

  @override
  String get secSignOutThisDeviceBody =>
      'Tendrás que ingresar de nuevo tu contraseña (y el TOTP, si está activado) para volver a iniciar sesión.';

  @override
  String get secSignOutEverywhereTitle =>
      '¿Cerrar sesión en todos los demás lugares?';

  @override
  String secSignOutEverywhereBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'es',
      one: '',
    );
    return 'Esto cerrará $count sesión$_temp0 más de inmediato. Este dispositivo permanecerá con la sesión iniciada.';
  }

  @override
  String get secSignOutOthers => 'Cerrar las demás';

  @override
  String secOtherSessionsSignedOutSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se cerraron $count sesiones más.',
      one: 'Se cerró 1 sesión más.',
    );
    return '$_temp0';
  }

  @override
  String secOnOs(Object os) {
    return 'en $os';
  }

  @override
  String get secUnknownDevice => 'Dispositivo desconocido';

  @override
  String get secActiveJustNow => 'Activo hace un momento';

  @override
  String secActiveMinutesAgo(Object minutes) {
    return 'Activo hace $minutes min';
  }

  @override
  String secActiveHoursAgo(Object hours) {
    return 'Activo hace $hours h';
  }

  @override
  String secActiveDaysAgo(Object days) {
    return 'Activo hace $days d';
  }

  @override
  String secActiveOnDate(Object date) {
    return 'Activo el $date';
  }

  @override
  String get secInviteUsersSection => 'Invitar usuarios';

  @override
  String get secNewInviteLink => 'Nuevo enlace de invitación';

  @override
  String get secNoInvites => 'Sin invitaciones';

  @override
  String get secNoInvitesSubtitle =>
      'Genera un enlace de un solo uso para que otra persona cree su propia cuenta de Patrimonio.';

  @override
  String get secInviteRedeemed => 'Canjeada';

  @override
  String get secInviteExpired => 'Caducada';

  @override
  String get secInviteActive => 'Activa';

  @override
  String get secReadOnlyChip => 'Solo lectura';

  @override
  String secInviteUsedOn(Object date) {
    return 'Usada el $date';
  }

  @override
  String secInviteExpiresOn(Object date) {
    return 'Caduca el $date';
  }

  @override
  String get secRevoke => 'Revocar';

  @override
  String secManyActiveInvitesHint(Object count) {
    return 'Tienes $count invitaciones activas; considera revocar los enlaces sin usar.';
  }

  @override
  String get secReadOnlyInviteReadyTitle =>
      'Enlace de invitación de solo lectura listo';

  @override
  String get secInviteReadyTitle => 'Enlace de invitación listo';

  @override
  String get secReadOnlyInviteReadyBody =>
      'Comparte esta URL con el nuevo usuario. Podrá ver tus datos, pero no cambiar nada. Sirve para crear una sola cuenta y caduca el:';

  @override
  String get secInviteReadyBody =>
      'Comparte esta URL con el nuevo usuario. Sirve para crear una sola cuenta y caduca el:';

  @override
  String get secCopiedToClipboard => 'Copiado al portapapeles.';

  @override
  String get secCopyAgain => 'Copiar de nuevo';

  @override
  String get secDone => 'Listo';

  @override
  String get secRevokeInviteTitle => '¿Revocar la invitación?';

  @override
  String get secRevokeInviteBody =>
      'El enlace dejará de funcionar de inmediato. Puedes generar uno nuevo si cambias de opinión.';

  @override
  String secRevokeFailedWithReason(Object reason) {
    return 'Error al revocar: $reason';
  }

  @override
  String get secPasskeysSection => 'Llaves de acceso';

  @override
  String get secAdd => 'Agregar';

  @override
  String get secThisDevice => 'Este dispositivo';

  @override
  String get secThisDeviceSubtitle => 'Face ID / Touch ID / Windows Hello';

  @override
  String get secSecurityKey => 'Llave de seguridad';

  @override
  String get secSecurityKeySubtitle => 'Llave USB / NFC — YubiKey, Titan';

  @override
  String get secPasskeysUnavailable => 'Llaves de acceso no disponibles';

  @override
  String get secPasskeysUnavailableSubtitle =>
      'Este navegador no expone la API de WebAuthn. Prueba con Chrome, Safari o Edge en un sistema operativo reciente para registrar una llave de acceso.';

  @override
  String get secNoPasskeys => 'Sin llaves de acceso registradas';

  @override
  String get secNoPasskeysSubtitle =>
      'Agrega este dispositivo, tu teléfono o una llave de seguridad de hardware (YubiKey, Titan, etc.) para iniciar sesión con datos biométricos o con un toque en lugar de una contraseña.';

  @override
  String get secInsertSecurityKeyPrompt =>
      'Inserta tu llave de seguridad y tócala (elige la opción de llave USB/de seguridad si tu navegador ofrece una llave de acceso guardada)…';

  @override
  String get secConfirmBiometricPrompt =>
      'Confirma con los datos biométricos de tu dispositivo…';

  @override
  String get secPasskeyAddedSnack => 'Llave de acceso agregada.';

  @override
  String get secRemovePasskeyTitle => '¿Eliminar esta llave de acceso?';

  @override
  String secRemovePasskeyBody(Object name) {
    return 'Ya no podrás iniciar sesión con \"$name\". Esta acción no se puede deshacer.';
  }

  @override
  String get secThisDeviceFallback => 'este dispositivo';

  @override
  String get secRemove => 'Eliminar';

  @override
  String get secPasskeyRemovedSnack => 'Llave de acceso eliminada.';

  @override
  String get secActiveSessionsSection => 'Sesiones activas';

  @override
  String secSignOutNOthers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Cerrar $count más',
      one: 'Cerrar 1 más',
    );
    return '$_temp0';
  }

  @override
  String get secNoActiveSessions => 'Sin sesiones activas';

  @override
  String get secNoActiveSessionsSubtitle =>
      'Deberías ver al menos este dispositivo. Actualiza para reintentar.';

  @override
  String get secThisDeviceBadge => 'Este dispositivo';

  @override
  String get secNewSinceLastVisit => 'Nueva desde tu última visita';

  @override
  String get secSignOutSessionTooltip => 'Cerrar esta sesión';

  @override
  String get secChangePasswordTitle => 'Cambiar contraseña';

  @override
  String get secCurrentPasswordLabel => 'Contraseña actual';

  @override
  String get secNewPasswordLabel => 'Nueva contraseña (12+ caracteres)';

  @override
  String get secPasswordTooShort => 'Al menos 12 caracteres';

  @override
  String get secConfirmPasswordLabel => 'Confirmar';

  @override
  String get secPasswordsDoNotMatch => 'Las contraseñas no coinciden';

  @override
  String get secChangeButton => 'Cambiar';

  @override
  String get secEnterSixDigitCode =>
      'Ingresa el código de 6 dígitos de tu app.';

  @override
  String get secEnrollTitle => 'Configurar la autenticación de dos factores';

  @override
  String get secEnrollSteps =>
      '1. Abre tu app de autenticación (Authy, Google Authenticator, 1Password, etc.).\n2. Escanea el código QR de abajo o elige \"Ingresar una clave de configuración\" y pega el secreto.\n3. Ingresa el código de 6 dígitos que muestra tu app.';

  @override
  String get secSetupLinkSecret => 'Enlace / secreto de configuración';

  @override
  String get secHide => 'Ocultar';

  @override
  String get secShow => 'Mostrar';

  @override
  String get secCopyOtpauthUri => 'Copiar URI otpauth://';

  @override
  String get secSixDigitCodeLabel => 'Código de 6 dígitos de tu app';

  @override
  String get secEnable => 'Activar';

  @override
  String get secConfirm => 'Confirmar';

  @override
  String secPasskeyRegisteredOn(Object date) {
    return 'Registrada el $date';
  }

  @override
  String get secLastUsedJustNow => 'Usada por última vez hace un momento';

  @override
  String secLastUsedMinutesAgo(Object minutes) {
    return 'Usada por última vez hace $minutes min';
  }

  @override
  String secLastUsedHoursAgo(Object hours) {
    return 'Usada por última vez hace $hours h';
  }

  @override
  String secLastUsedDaysAgo(Object days) {
    return 'Usada por última vez hace $days d';
  }

  @override
  String secLastUsedOn(Object date) {
    return 'Usada por última vez el $date';
  }

  @override
  String get secHardwareKeyTitle => 'Llave de seguridad de hardware';

  @override
  String get secDevicePasskeyTitle => 'Llave de acceso del dispositivo';

  @override
  String get secHardwareKeyKind => 'Llave de seguridad de hardware';

  @override
  String get secPlatformPasskeyKind => 'Llave de acceso de plataforma';

  @override
  String get secRemovePasskeyTooltip => 'Eliminar llave de acceso';

  @override
  String get secInviteAccessQuestion =>
      '¿Qué nivel de acceso debe otorgar esta invitación?';

  @override
  String get secFullAccess => 'Acceso completo';

  @override
  String get secFullAccessSubtitle =>
      'Puede ver y cambiar todo: vincular cuentas, editar transacciones y ejecutar sincronizaciones.';

  @override
  String get secReadOnlyAccess => 'Solo lectura';

  @override
  String get secReadOnlyAccessSubtitle =>
      'Puede ver todo, pero no hacer cambios. Ideal para un cónyuge, asesor o contador.';

  @override
  String get secCreateLink => 'Crear enlace';

  @override
  String get secNamePasskeyTitle => 'Nombrar esta llave de acceso';

  @override
  String get secNamePasskeyBody =>
      'Etiqueta opcional para distinguir esta llave de acceso más adelante. Ejemplos: \"iPhone 15\", \"MacBook del trabajo\", \"YubiKey del llavero\".';

  @override
  String get secDeviceNameLabel => 'Nombre del dispositivo';

  @override
  String get secDeviceNameHint => 'p. ej. iPhone 15';

  @override
  String get secContinue => 'Continuar';

  @override
  String get cfMonthlyTitle => 'Flujo de efectivo de este mes';

  @override
  String get cfMonthlyExcludesTooltip =>
      'No incluye transferencias internas entre tus cuentas ni pagos de tarjeta de crédito: ese dinero se mueve dentro de tu propio balance sin cambiar tus gastos.';

  @override
  String get cfIncome => 'Ingresos';

  @override
  String get cfExpense => 'Gastos';

  @override
  String get cfMonthlyEmpty =>
      'El flujo de efectivo aparecerá aquí una vez que se sincronicen algunas semanas de movimientos.';

  @override
  String cfVsLastMonth(Object delta) {
    return '$delta vs. el mes pasado';
  }

  @override
  String get cfNotEnoughHistory => 'Aún no hay suficiente historial';

  @override
  String get cfSubscriptionsTitle => 'Cargos recurrentes';

  @override
  String cfSubscriptionsActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count activos',
      one: '1 activo',
    );
    return '$_temp0';
  }

  @override
  String cfSubscriptionsStoppedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count detenidos',
      one: '1 detenido',
    );
    return '$_temp0';
  }

  @override
  String cfPerMonthApprox(Object amount) {
    return '≈ $amount / mes';
  }

  @override
  String get cfSubscriptionsSubtitle =>
      'Cargos que se repiten cada 5 a 62 días. Toca un renglón para filtrar la lista de movimientos.';

  @override
  String get cfSubscriptionsNoneActive =>
      'No se detectaron suscripciones activas.';

  @override
  String cfSubscriptionsStoppedHeader(Object count) {
    return 'Detenidos ($count)';
  }

  @override
  String get cfSubscriptionsStoppedHint => 'Último cargo hace más de 90 días';

  @override
  String get cfCadenceWeekly => 'Semanal';

  @override
  String get cfCadenceBiweekly => 'Quincenal';

  @override
  String get cfCadenceMonthly => 'Mensual';

  @override
  String cfCadenceEveryNDays(Object days) {
    return 'Cada $days d';
  }

  @override
  String cfChargesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cargos',
      one: '1 cargo',
    );
    return '$_temp0';
  }

  @override
  String cfLastCharged(Object date) {
    return 'último $date';
  }

  @override
  String cfPerMonth(Object amount) {
    return '$amount / mes';
  }

  @override
  String cfWasPerMonth(Object amount) {
    return 'era $amount / mes';
  }

  @override
  String get cfNotASubscription =>
      'No es una suscripción: ocultar este renglón';

  @override
  String cfPlusNMore(Object count) {
    return '+$count más';
  }

  @override
  String get cfBudgetsTitle => 'Presupuestos de este mes';

  @override
  String get cfBudgetsEdit => 'Editar';

  @override
  String get cfBudgetsEmpty =>
      'Define un presupuesto mensual para cualquier categoría y dale seguimiento a tus gastos aquí.';

  @override
  String get cfBudgetsDialogTitle => 'Editar presupuestos mensuales';

  @override
  String get cfTransfersTitle => 'Transferencias entre divisas';

  @override
  String get cfTransfersSubtitle =>
      'Pares vinculados de Wise / Remitly / transferencias bancarias. La tasa implícita es el tipo de cambio efectivo que usó el servicio; spot es la tasa de mercado en la fecha de origen.';

  @override
  String cfTransfersSpot(Object rate) {
    return 'spot $rate';
  }

  @override
  String get cfTransfersConfirm => 'Confirmar';

  @override
  String get cfTransfersConfirmed => 'Confirmada';

  @override
  String get cfTransfersUnlink => 'Desvincular';

  @override
  String get cfCreditNoAccounts => 'No se encontraron cuentas de crédito.';

  @override
  String get cfCreditUtilizationHeader => 'USO DEL CRÉDITO';

  @override
  String get cfCreditAccountFallback => 'Cuenta de crédito';

  @override
  String get cfCreditShowFewer => 'Mostrar menos';

  @override
  String cfCreditShowMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Mostrar $count tarjetas más',
      one: 'Mostrar 1 tarjeta más',
    );
    return '$_temp0';
  }

  @override
  String get authCreateAccount => 'Crear cuenta';

  @override
  String get authInviteIntro =>
      'Recibiste una invitación. Elige un usuario y una contraseña para terminar de configurar tu cuenta.';

  @override
  String get authUsernameMaxLength => 'Máximo 64 caracteres';

  @override
  String get authEmailOptional => 'Correo (opcional)';

  @override
  String get authPasswordMinHelper => 'Al menos 12 caracteres';

  @override
  String get authConfirmPassword => 'Confirmar contraseña';

  @override
  String get authPasswordsDoNotMatch => 'Las contraseñas no coinciden';

  @override
  String get authResetPasswordTitle => 'Restablecer contraseña';

  @override
  String get authPasswordResetDoneTitle => 'Contraseña restablecida';

  @override
  String get authPasswordResetDoneBody =>
      'Inicia sesión con tu nueva contraseña. El código que usaste ya fue consumido.';

  @override
  String get authBackToSignIn => 'Volver a iniciar sesión';

  @override
  String get authUseRecoveryCodeTitle => 'Usar un código de recuperación';

  @override
  String get authUseRecoveryCodeBody =>
      'Ingresa uno de los códigos de recuperación que guardaste al configurar tu cuenta. Cada código es de un solo uso: una vez utilizado, no se puede volver a usar.';

  @override
  String get authRecoveryCodeLabel =>
      'Código de recuperación (ej. XK4T-9PMQ-7HZL)';

  @override
  String get authRecoveryCodeHint =>
      'Los guiones y las mayúsculas son opcionales';

  @override
  String get authRecoveryCodeInvalid =>
      'Los códigos tienen 12 letras o dígitos (los guiones son opcionales)';

  @override
  String get authNewPasswordLabel => 'Nueva contraseña (12+ caracteres)';

  @override
  String get authConfirmNewPassword => 'Confirmar nueva contraseña';

  @override
  String get authWelcomeTitle => 'Te damos la bienvenida a Patrimonio';

  @override
  String get authBootstrapSubtitle =>
      'Crea la cuenta del titular. Esta configuración se hace una sola vez.';

  @override
  String get authPasswordWithMin => 'Contraseña (12+ caracteres)';

  @override
  String get authTotpEnterCode => 'Ingresa el código de 6 dígitos de tu app.';

  @override
  String get authTotpTitle => 'Se requiere doble factor';

  @override
  String get authTotpSubtitle =>
      'Abre tu app de autenticación e ingresa el código de 6 dígitos para Patrimonio.';

  @override
  String get authTotpVerify => 'Verificar';

  @override
  String get impTitle => 'Importar estado de cuenta';

  @override
  String get impUploadHeading => 'Subir estado de cuenta';

  @override
  String impUploadSubtitle(Object banks) {
    return 'Sube estados de cuenta en CSV o PDF de $banks. Detectaremos el formato automáticamente.';
  }

  @override
  String get impWaitForUpload =>
      'Espera a que termine la importación actual antes de agregar más archivos.';

  @override
  String get impAddedFileFromDrop => 'Se agregó 1 archivo';

  @override
  String impAddedFilesFromDrop(Object count) {
    return 'Se agregaron $count archivos';
  }

  @override
  String impUploadTooLarge(Object count, Object totalMb) {
    return 'Estos $count archivos suman $totalMb MB, más del límite de 100 MB. Quita algunos archivos e impórtalos en lotes separados.';
  }

  @override
  String get impLargeUploadTitle => 'Carga grande';

  @override
  String impLargeUploadBody(Object totalMb) {
    return 'Este lote pesa $totalMb MB, cerca del límite de 100 MB. Las cargas grandes pueden ser lentas y rechazarse. ¿Importar de todos modos?';
  }

  @override
  String get impImportAnyway => 'Importar de todos modos';

  @override
  String impFoundTransactions(Object count) {
    return 'Se encontraron $count movimientos.';
  }

  @override
  String impFoundWithAutoDeselected(Object count, Object message) {
    return '$message ($count deseleccionados automáticamente por ser informativos)';
  }

  @override
  String impUploadFailed(Object error) {
    return 'Error al subir: $error';
  }

  @override
  String get impSelectAccountFirst =>
      'Primero selecciona una cuenta de destino.';

  @override
  String get impNoTransactionsSelected =>
      'No seleccionaste ningún movimiento. Marca al menos uno.';

  @override
  String get impImportSuccessful => 'Importación exitosa';

  @override
  String impConfirmationFailed(Object error) {
    return 'Error al confirmar: $error';
  }

  @override
  String get impReadingFiles => 'Leyendo archivos…';

  @override
  String get impReadingOneFile => 'Leyendo 1 archivo…';

  @override
  String impReadingNFiles(Object count) {
    return 'Leyendo $count archivos…';
  }

  @override
  String get impReadingHint =>
      'Cargando el contenido de los archivos en el navegador antes de enviarlos. Este paso es local: aún no se sube nada.';

  @override
  String get impProcessingOneFile => 'Procesando 1 archivo…';

  @override
  String impProcessingProgress(Object done, Object total) {
    return 'Procesando $done de $total archivos…';
  }

  @override
  String impProcessingNFiles(Object count) {
    return 'Procesando $count archivos…';
  }

  @override
  String impLastFile(Object file) {
    return 'Último: $file';
  }

  @override
  String impLastFileSkipped(Object file) {
    return 'Último: $file (omitido)';
  }

  @override
  String get impLargeBatchHint =>
      'Los lotes grandes pueden tardar de 30 a 120 segundos: cada PDF se procesa por separado en el servidor.';

  @override
  String get impDropToImport => 'Suelta para importar';

  @override
  String get impDropHint =>
      'Arrastra archivos CSV o PDF a cualquier parte de esta página, o selecciónalos manualmente abajo.';

  @override
  String get impNoFilesSelected => 'No hay archivos seleccionados';

  @override
  String get impOneFileSelected => '1 archivo seleccionado';

  @override
  String impNFilesSelected(Object count) {
    return '$count archivos seleccionados';
  }

  @override
  String get impRemoveFile => 'Quitar';

  @override
  String get impSelectFiles => 'Seleccionar archivos';

  @override
  String get impAddMoreFiles => 'Agregar más archivos';

  @override
  String get impAssignToAccount => 'Asignar a una cuenta';

  @override
  String impPreviewSelected(Object selected, Object total) {
    return 'Vista previa ($selected/$total seleccionados)';
  }

  @override
  String get impSelectAll => 'Seleccionar todo';

  @override
  String get impDeselectAll => 'Deseleccionar todo';

  @override
  String get impAutoDeselectedTooltip =>
      'Deseleccionado automáticamente: registro informativo';

  @override
  String get impImportOneTransaction => 'Importar 1 movimiento';

  @override
  String impImportNTransactions(Object count) {
    return 'Importar $count movimientos';
  }

  @override
  String get impPdfPassword => 'Contraseña del PDF (ej. RFC)';

  @override
  String get impProcessStatement => 'Procesar estado de cuenta';

  @override
  String get dashConnectViaOauth => 'Conectar con OAuth';

  @override
  String get dashConnectWithApiKey => 'Conectar con una llave API';

  @override
  String dashPaletteJumpTo(Object name) {
    return 'Ir a $name';
  }

  @override
  String get dashPaletteSection => 'Sección';

  @override
  String get dashPaletteSectionLending => 'Sección · dinero que prestaste';

  @override
  String dashPaletteAccount(Object institution) {
    return 'Cuenta · $institution';
  }

  @override
  String get dashPaletteHolding => 'Posición';

  @override
  String dashPaletteTransaction(Object account, Object date) {
    return 'Transacción · $account · $date';
  }

  @override
  String get dashHiddenFromSubscriptions => 'Ocultas de suscripciones';

  @override
  String get dashHiddenFromSubscriptionsHint =>
      'Marcaste estas como \"no es una suscripción\". Muestra una fila para que el detector la vuelva a considerar.';

  @override
  String get dashUnhide => 'Mostrar';

  @override
  String dashSubscriptionRestored(Object merchant) {
    return '\"$merchant\" volvió al detector de suscripciones';
  }

  @override
  String dashUnhideFailed(Object error) {
    return 'No se pudo mostrar: $error';
  }

  @override
  String get dashModuleLendingTitle => 'Préstamos personales';

  @override
  String get dashModuleLendingSubtitle =>
      'Lleva el control del dinero que prestas a tus amigos: marca las transacciones bancarias que financian y pagan cada préstamo. Agrega una sección de Préstamos.';

  @override
  String get dashRemindBeforeRepayment =>
      'Recordarme antes de que venza un pago';

  @override
  String get dashFewerDays => 'Menos días';

  @override
  String get dashMoreDays => 'Más días';

  @override
  String dashDaysShort(Object count) {
    return '$count d';
  }

  @override
  String get dashReminderSaveFailed => 'No se pudo guardar el recordatorio';

  @override
  String get dashSettingSaveFailed => 'No se pudo guardar ese ajuste';

  @override
  String get dashEnvSandbox => 'Sandbox';

  @override
  String get dashEnvDev => 'Dev';

  @override
  String dashEnvTooltip(Object env) {
    return 'Plaid está en modo $env. Las cuentas vinculadas no accederán a datos bancarios reales.';
  }

  @override
  String get dashFxLoading => 'Cargando el tipo de cambio…';

  @override
  String get dashFxLive => 'Tipo de cambio USD/MXN en vivo';

  @override
  String dashFxStaleAt(Object timestamp) {
    return 'Tipo de cambio desactualizado — $timestamp';
  }

  @override
  String dashFxUpdatedAt(Object timestamp) {
    return 'Actualizado $timestamp';
  }

  @override
  String get dashLinkUsBank => 'Vincular un banco de EE. UU.';

  @override
  String get dashLinkUsBankSubtitle =>
      'Conéctalo de forma segura con Plaid: los saldos y las transacciones se sincronizan automáticamente.';

  @override
  String get dashLinkUsBankDisabledHint =>
      'Aún no se configuran las credenciales de Plaid: por ahora usa CSV o manual.';

  @override
  String get dashImportMxCsvPdf => 'Importar CSV o PDF de México';

  @override
  String dashImportMxCsvPdfSubtitle(Object banks) {
    return 'Sube un estado de cuenta de $banks.';
  }

  @override
  String get dashAddManualAccount => 'Agregar una cuenta manual';

  @override
  String get dashAddManualAccountSubtitle =>
      'Registra un saldo en efectivo, una cuenta de inversión o cualquier otra cosa a mano.';

  @override
  String get dashTrackMoneyLent => 'Lleva el control del dinero que prestaste';

  @override
  String get dashTrackMoneyLentSubtitle =>
      '¿Prestas a amigos o familiares? Registra préstamos, concilia los pagos y lleva el control de los intereses.';

  @override
  String get dashConnectCryptoExchangeTile => 'Conectar un exchange de cripto';

  @override
  String get dashConnectCryptoExchangeTileSubtitle =>
      'Vincula Coinbase o Bitso para ver tus criptos junto con tus cuentas.';

  @override
  String get dashOnboardingWelcome => 'Te damos la bienvenida a Patrimonio';

  @override
  String get dashOnboardingSubtitle =>
      'Conecta tu primera cuenta para ver tu patrimonio neto, tus transacciones y tus proyecciones en un solo lugar.';

  @override
  String get dashOnboardingAlreadyLinked =>
      '¿Ya tienes cuentas vinculadas en otro lado? Aparecerán aquí en cuanto se complete la primera sincronización.';

  @override
  String get dashAccountLinkedSuccess => '¡Cuenta vinculada con éxito!';

  @override
  String get dashAccountLinkFailed =>
      'No se pudo vincular la cuenta. Inténtalo de nuevo.';

  @override
  String dashReconnectFailed(Object error) {
    return 'No se pudo reconectar: $error';
  }

  @override
  String dashWebhookPushed(Object count) {
    return 'URL de webhook enviada a $count institución(es)';
  }

  @override
  String dashWebhookPartial(Object failed, Object updated) {
    return '$updated actualizadas, $failed con error';
  }

  @override
  String get dashUnknown => 'Desconocida';

  @override
  String dashPushFailed(Object error) {
    return 'No se pudo enviar: $error';
  }

  @override
  String dashErrorLoading(Object error) {
    return 'Error al cargar el panel: $error';
  }

  @override
  String get dashRetry => 'Reintentar';

  @override
  String dashUpdateFailed(Object error) {
    return 'No se pudo actualizar: $error';
  }

  @override
  String get dashAccountDeleted => 'Cuenta eliminada';

  @override
  String dashDeleteFailed(Object error) {
    return 'No se pudo eliminar: $error';
  }

  @override
  String get dashNicknameCleared => 'Apodo borrado';

  @override
  String dashRenamedTo(Object nickname) {
    return 'Renombrada a \"$nickname\"';
  }

  @override
  String dashRenameFailed(Object error) {
    return 'No se pudo renombrar: $error';
  }

  @override
  String get dashRevalued => 'Revaluada';

  @override
  String get dashRevaluedNoteSaved => 'Revaluada · nota guardada';

  @override
  String dashRevalueFailed(Object error) {
    return 'No se pudo revaluar: $error';
  }

  @override
  String get dashNetWorthHistory => 'Historial de patrimonio neto';

  @override
  String get dashSyncingAll => 'Sincronizando todas las instituciones…';

  @override
  String get dashSyncComplete => 'Sincronización completa';

  @override
  String dashSyncFailed(Object error) {
    return 'Falló la sincronización: $error';
  }

  @override
  String get dashLaunchSetup => 'Configuración de lanzamiento';

  @override
  String get dashLaunchSetupReady =>
      'La vinculación con Plaid puede comenzar. Los servicios opcionales aún pueden mejorar la calidad de los datos.';

  @override
  String get dashLaunchSetupBlocked =>
      'Completa la configuración requerida antes de que usuarios reales puedan vincular cuentas con Plaid.';

  @override
  String dashPushToInstitutions(Object count) {
    return 'Enviar a $count institución(es)';
  }

  @override
  String dashRecommendedBeforeProduction(Object labels) {
    return 'Recomendado antes de producción: $labels.';
  }

  @override
  String dashConfirmFailed(Object error) {
    return 'No se pudo confirmar: $error';
  }

  @override
  String dashUnlinkFailed(Object error) {
    return 'No se pudo desvincular: $error';
  }

  @override
  String get dashScanningTransfers => 'Buscando transferencias entre monedas…';

  @override
  String dashTransfersLinked(Object checked, Object inserted) {
    return 'Se vincularon $inserted par(es) de transferencias (se revisaron $checked candidatos)';
  }

  @override
  String get dashNoNewTransfers => 'No se encontraron transferencias nuevas';

  @override
  String dashDetectionFailed(Object error) {
    return 'Falló la detección: $error';
  }

  @override
  String dashUpdateTransactionFailed(Object error) {
    return 'No se pudo actualizar la transacción: $error';
  }

  @override
  String get dashTransactionDeleted => 'Transacción eliminada';

  @override
  String get dashLinkConfirmed => 'Vínculo confirmado';

  @override
  String get dashPairUnlinked => 'Par desvinculado';

  @override
  String dashMerchantHidden(Object merchant) {
    return '\"$merchant\" oculto de las suscripciones';
  }

  @override
  String dashFailedGeneric(Object error) {
    return 'Error: $error';
  }

  @override
  String get dashDataSources => 'Fuentes de datos y sincronización';

  @override
  String dashRetryFailed(Object error) {
    return 'Falló el reintento: $error';
  }

  @override
  String get dashDeleteInstitutionTitle => 'Eliminar institución';

  @override
  String get dashDeleteInstitutionBody =>
      '¿Estás seguro? Esto eliminará TODAS las cuentas y el historial de esta institución.';

  @override
  String get dashDeleteEverything => 'Eliminar todo';

  @override
  String get dashFxRateRefreshed => 'Tipo de cambio actualizado';

  @override
  String dashRefreshFailed(Object error) {
    return 'No se pudo actualizar: $error';
  }

  @override
  String get dashConnectStandardAccounts => 'Conectar cuentas estándar';

  @override
  String get dashSyncAllAccounts => 'Sincronizar todas las cuentas';

  @override
  String get dashLinkPlaidUsBanks => 'Vincular Plaid (bancos de EE. UU.)';

  @override
  String get dashImportMxShort => 'Importar México (CSV/PDF)';

  @override
  String get dashAddManualAccountShort => 'Agregar cuenta manual';

  @override
  String get dashConnectCryptoExchanges => 'Conectar exchanges de cripto';

  @override
  String get dashLinkCoinbase => 'Vincular Coinbase';

  @override
  String get dashConnectBitso => 'Conectar Bitso';

  @override
  String get dashHiddenItems => 'Elementos ocultos';

  @override
  String get dashSecurity => 'Seguridad';

  @override
  String get dashSignOut => 'Cerrar sesión';

  @override
  String get dashThemeSystem => 'Tema del sistema';

  @override
  String get dashThemeLight => 'Tema claro';

  @override
  String get dashThemeDark => 'Tema oscuro';

  @override
  String get dashThemeSystemDefault => 'Predeterminado del sistema';

  @override
  String get dashThemeLightShort => 'Claro';

  @override
  String get dashThemeDarkShort => 'Oscuro';

  @override
  String dashThemeTooltip(Object label) {
    return '$label · toca para alternar, mantén presionado para elegir';
  }
}
