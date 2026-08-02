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
  String get navTaxPlanning => 'Impuestos';

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
  String lendingOutstandingInclInterest(String amount) {
    return 'incluye $amount de intereses';
  }

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
  String lendViewInstallments(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'Ver $count cuota$_temp0';
  }

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
  String get txAmount => 'Monto';

  @override
  String get txAmountMin => 'Mín.';

  @override
  String get txAmountMax => 'Máx.';

  @override
  String get txAmountFilterHelp =>
      'Coincide con el monto sin importar el signo o la divisa.';

  @override
  String get txClearAll => 'Limpiar todo';

  @override
  String txSpikeBanner(
    String average,
    String category,
    String monthLabel,
    int months,
    String percent,
    String recent,
  ) {
    return '$category en $monthLabel: $recent gastados, $percent por encima de tu promedio de $months meses de $average';
  }

  @override
  String get txEmptyTitle => 'Aún no hay movimientos';

  @override
  String get txEmptyBody =>
      'Vincula un banco, importa un estado de cuenta o agrega una cuenta manualmente\npara empezar a ver actividad aquí.';

  @override
  String get txAddAccount => 'Agregar una cuenta';

  @override
  String get txNoMatchesTitle => 'Ningún movimiento coincide';

  @override
  String get txNoMatchesBody => 'Prueba ajustar tu búsqueda o los filtros.';

  @override
  String get txClearFiltersSearch => 'Limpiar filtros y búsqueda';

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
  String get txDeletedOne => 'Movimiento eliminado';

  @override
  String get txDeleteOneFailed => 'No se pudo eliminar el movimiento';

  @override
  String get txDeleteSomeFailed =>
      'No se pudieron eliminar algunos movimientos';

  @override
  String get txUndo => 'Deshacer';

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
  String get txFilterSort => 'Filtrar y ordenar';

  @override
  String get txFilterLoadingHistory =>
      'Cargando todo tu historial para que todas las opciones estén disponibles…';

  @override
  String get txLoadingFullHistory => 'Cargando el historial completo…';

  @override
  String get txExitSelectionMode => 'Salir del modo de selección';

  @override
  String get txSelectMultiple => 'Seleccionar varios';

  @override
  String get txAddTransaction => 'Agregar movimiento';

  @override
  String get txExportCsv => 'Exportar CSV';

  @override
  String get txExportCsvAllNote =>
      'Exportar CSV: exporta todos los movimientos (los filtros y la búsqueda no se aplican)';

  @override
  String get txExportCsvFiltered =>
      'Exportar CSV: exporta los movimientos que coinciden con tu filtro actual';

  @override
  String get txExportNoRows =>
      'Nada para exportar: ningún movimiento coincide con el filtro actual.';

  @override
  String get txExportAllTitle => '¿Exportar todos los movimientos?';

  @override
  String get txExportAllBody =>
      'Los filtros y la búsqueda no se aplican a la exportación CSV: incluirá todo tu historial de movimientos.';

  @override
  String get txExportAllConfirm => 'Exportar todo';

  @override
  String get txSortBy => 'Ordenar por';

  @override
  String get txSortDateNewest => 'Fecha (más reciente primero)';

  @override
  String get txSortDateOldest => 'Fecha (más antigua primero)';

  @override
  String get txSortAmountHigh => 'Monto (mayor primero)';

  @override
  String get txSortAmountLow => 'Monto (menor primero)';

  @override
  String get txSortMerchant => 'Comercio (A–Z)';

  @override
  String get txScanTransfers =>
      'Buscar transferencias entre divisas (Wise / Remitly / etc.)';

  @override
  String get txMoreActions => 'Más acciones';

  @override
  String get txDetails => 'Detalles';

  @override
  String get txMoreDetails => 'Más detalles';

  @override
  String get txDate => 'Fecha';

  @override
  String get txAccount => 'Cuenta';

  @override
  String get txAutoCategory => 'Categoría automática';

  @override
  String get txSearchTransactions => 'Buscar movimientos';

  @override
  String get txDateToday => 'Hoy';

  @override
  String get txDateYesterday => 'Ayer';

  @override
  String txMonthNet(Object amount) {
    return '$amount neto';
  }

  @override
  String txMonthNetPartial(Object amount) {
    return '$amount neto (parcial)';
  }

  @override
  String txBalanceAfter(Object amount) {
    return 'Saldo $amount';
  }

  @override
  String get txBalanceAfterTooltip => 'Saldo después de este movimiento';

  @override
  String get txBalanceAfterEstimatedTooltip =>
      'Estimado a partir del saldo actual';

  @override
  String get txInlineEditHint => 'Nueva etiqueta · Enter para guardar';

  @override
  String get txSplitPill => 'División';

  @override
  String get txTransferPill => 'Transferencia';

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
  String get txOriginalText => 'Texto original';

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
  String get txEditTransaction => 'Editar movimiento';

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
  String txNewSince(Object date) {
    return 'Nuevas desde $date';
  }

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
  String get secAccountSection => 'Cuenta';

  @override
  String get secAccountNoEmail => 'Sin correo registrado';

  @override
  String get secPasswordSection => 'Contraseña';

  @override
  String get secChangePassword => 'Cambiar contraseña';

  @override
  String get secChangePasswordSubtitle =>
      'Cierra la sesión en todos los demás dispositivos.';

  @override
  String get secSetPasswordWithPasskey =>
      'Crear una nueva contraseña (con clave de acceso)';

  @override
  String get secSetPasswordWithPasskeySubtitle =>
      'Usa tu clave de acceso en lugar de tu contraseña actual.';

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
  String get secSetPasswordWithPasskeyTitle => 'Crear una nueva contraseña';

  @override
  String get secSetPasswordWithPasskeyBody =>
      'Tu clave de acceso te verificó. Elige una nueva contraseña; no necesitarás la anterior.';

  @override
  String get secSetPasswordButton => 'Guardar contraseña';

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
  String get cfCashFlowShort => 'Flujo de efectivo';

  @override
  String cfNetEquivalence(Object amount) {
    return 'Neto del periodo ≈ $amount';
  }

  @override
  String get cfMonthlyExcludesTooltip =>
      'No incluye operaciones de inversión ni transferencias internas entre tus cuentas, ni pagos de tarjeta de crédito: ese dinero se mueve dentro de tu balance sin cambiar tus ingresos ni gastos. Los montos se muestran abajo.';

  @override
  String get cfAlsoThisPeriod => 'También este periodo —';

  @override
  String cfInvestedContext(Object amount) {
    return 'Invertido $amount';
  }

  @override
  String cfWithdrawnContext(Object amount) {
    return 'Retirado $amount';
  }

  @override
  String cfTransferredInContext(Object amount) {
    return 'Transferencia recibida $amount';
  }

  @override
  String cfTransferredOutContext(Object amount) {
    return 'Transferencia enviada $amount';
  }

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
  String get cfPeriodLabel => 'Periodo';

  @override
  String get cfPeriodThisMonth => 'Este mes';

  @override
  String get cfPeriodLastMonth => 'Mes pasado';

  @override
  String get cfPeriod3Months => 'Últimos 3 meses';

  @override
  String get cfPeriodYtd => 'En lo que va del año';

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
  String get bmTitle => 'Inversiones vs S&P 500';

  @override
  String get bmSubtitle =>
      'Ponderado por dinero, todo el periodo — si tus aportaciones hubieran comprado el índice en cada fecha de compra';

  @override
  String get bmContribCaveat =>
      'Cubre solo compras con lotes registrados — las compras recientes pesan más, por lo que puede quedar muy por debajo del rendimiento del portafolio de arriba.';

  @override
  String bmAheadPts(Object pts) {
    return 'Vas por encima del índice por $pts pts';
  }

  @override
  String bmBehindPts(Object pts) {
    return 'El índice va por encima por $pts pts';
  }

  @override
  String get bmYou => 'Tú';

  @override
  String get bmSp500 => 'S&P 500';

  @override
  String bmAhead(Object pct) {
    return 'Vas por encima del mercado por $pct';
  }

  @override
  String bmBehind(Object pct) {
    return 'El mercado va por encima por $pct';
  }

  @override
  String get bmContribTitle => 'Por fecha de aportación';

  @override
  String get bmContribYou => 'Tus lotes registrados';

  @override
  String get bmContribIndex => 'Lo mismo en el S&P 500';

  @override
  String bmContribNote(Object count, Object invested) {
    return '$count compras · $invested invertido';
  }

  @override
  String get bmSeeTracked => 'Ver qué está registrado';

  @override
  String get bmSheetTapHint =>
      'Muestra qué símbolos tienen lotes registrados y cuáles quedan fuera';

  @override
  String get bmSheetTitle => 'Qué está registrado';

  @override
  String get bmSheetCaption =>
      'Compras con lotes registrados, comparadas con comprar el índice en las mismas fechas';

  @override
  String bmLots(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lotes',
      one: '1 lote',
    );
    return '$_temp0';
  }

  @override
  String bmFirstBuy(Object monthYear) {
    return 'primera compra $monthYear';
  }

  @override
  String bmInvestedToValue(Object invested, Object value) {
    return '$invested → $value';
  }

  @override
  String bmPtsVsIndex(Object pts) {
    return '$pts pts vs índice';
  }

  @override
  String get bmUntrackedHeader =>
      'No incluido — sin datos de compras registradas';

  @override
  String bmUntrackedTotal(Object amount) {
    return '$amount de posiciones excluidas';
  }

  @override
  String get bmUntrackedHint =>
      'Agrega lotes de compra para incluir estas posiciones en la comparación.';

  @override
  String get dpTitle => 'Pago de deudas';

  @override
  String get dpMonthlyPayment => 'Pago mensual';

  @override
  String get dpAvalanche => 'Avalancha';

  @override
  String get dpSnowball => 'Bola de nieve';

  @override
  String get dpAvalancheSub => 'Mayor tasa primero';

  @override
  String get dpSnowballSub => 'Menor saldo primero';

  @override
  String dpDebtFree(Object months) {
    return '$months meses para liquidar';
  }

  @override
  String dpInterest(Object amount) {
    return '$amount de interés';
  }

  @override
  String get dpRecommended => 'Recomendado';

  @override
  String dpSaves(Object amount) {
    return 'Ahorra $amount vs bola de nieve';
  }

  @override
  String get dpSimulator => 'Simulador de pago';

  @override
  String get dpInfeasible => 'Aumenta el pago mensual para cubrir los mínimos.';

  @override
  String get dpSetApr => 'Definir TAE';

  @override
  String get dpAprDialogTitle => 'Tasa de interés (TAE)';

  @override
  String get dpAprLabel => 'Tasa anual';

  @override
  String dpEditApr(Object name) {
    return 'Tasa de $name';
  }

  @override
  String get dpTotalOwed => 'Total adeudado';

  @override
  String get dpWeightedApr => 'TAE prom.';

  @override
  String get dpMonthlyInterest => 'Interés / mes';

  @override
  String dpSplitCredit(Object amount, Object count) {
    return '$count crédito · $amount';
  }

  @override
  String dpSplitLoan(Object amount, Object count) {
    return '$count préstamos · $amount';
  }

  @override
  String get dpCardTermsTitle => 'Términos de tarjeta';

  @override
  String dpEditCardTerms(Object name) {
    return 'Términos de $name';
  }

  @override
  String get dpStatementBalance => 'Saldo del estado';

  @override
  String get dpMinPayment => 'Pago mínimo';

  @override
  String get dpDueDate => 'Fecha de vencimiento';

  @override
  String get dpDueDateNone => 'Sin fecha';

  @override
  String get dpAddTerms => 'Términos';

  @override
  String get dpDueSoonTitle => 'Próximos vencimientos';

  @override
  String dpDueInDays(int n) {
    return 'Vence en $n d';
  }

  @override
  String get dpDueToday => 'Vence hoy';

  @override
  String get dpOverdue => 'Vencido';

  @override
  String dpDueOn(Object date) {
    return 'Vence $date';
  }

  @override
  String dpInDays(int n) {
    return 'en $n d';
  }

  @override
  String dpMinAmount(Object amount) {
    return 'mín $amount';
  }

  @override
  String get efTitle => 'Fondo de emergencia';

  @override
  String get efMonthsUnit => 'meses de gastos';

  @override
  String get efStatusHealthy => 'Totalmente fondeado';

  @override
  String get efStatusOnTrack => 'En camino';

  @override
  String get efStatusBuilding => 'Sigue ahorrando';

  @override
  String efCashLabel(Object amount) {
    return '$amount en efectivo líquido';
  }

  @override
  String efSpendLabel(Object amount) {
    return '$amount / mes promedio';
  }

  @override
  String get efScale0 => '0';

  @override
  String get efScale3 => '3 m';

  @override
  String get efScale6 => '6 m+';

  @override
  String get efNoSpendTitle => 'Aún no hay estimación';

  @override
  String get efNoSpendBody =>
      'Cuando tengas alrededor de un mes de transacciones, estimaremos cuánto duraría tu efectivo.';

  @override
  String get efNoCashHint =>
      'No se detectó efectivo líquido — vincula una cuenta de cheques o ahorros para ver tu cobertura.';

  @override
  String get billsTitle => 'Próximos pagos recurrentes';

  @override
  String get billsNext12 => 'Proyectado · próximos 12 meses';

  @override
  String get rgTitle => 'Ganancias realizadas';

  @override
  String get rgThisYear => 'Este año';

  @override
  String get rgAllTime => 'Histórico';

  @override
  String get rgProceeds => 'Ingresos';

  @override
  String get rgCost => 'Costo';

  @override
  String get rgLongTerm => 'LP';

  @override
  String get rgShortTerm => 'CP';

  @override
  String rgMoreCount(Object count) {
    return '+$count ventas más';
  }

  @override
  String get spendByCatTitle => 'Gasto por categoría';

  @override
  String get spendByCatEmpty =>
      'Aún no hay gastos registrados en este periodo.';

  @override
  String get spendByCatAvgPerMonth => 'Promedio por mes';

  @override
  String get spendByCatTotal => 'Total';

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
  String cfBudgetsOverAlert(int count, String amount) {
    return 'Sobre presupuesto en $count — $amount de más';
  }

  @override
  String cfBudgetsNearAlert(Object count) {
    return 'Cerca del presupuesto en $count';
  }

  @override
  String cfBudgetsOverBy(Object amount) {
    return '$amount de más';
  }

  @override
  String cfBudgetsLeft(Object amount) {
    return '$amount disponible';
  }

  @override
  String get cfBudgetsSuggest => 'Sugerir';

  @override
  String get cfBudgetsSuggestTooltip =>
      'Llena los presupuestos con tu gasto promedio reciente';

  @override
  String cfBudgetsSuggestedSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se agregaron presupuestos para $count categorías',
      one: 'Se agregó un presupuesto para $count categoría',
    );
    return '$_temp0';
  }

  @override
  String get cfBudgetsSuggestNone =>
      'No hay nuevas sugerencias: ya tienen presupuesto o no hay suficiente gasto reciente para sugerir.';

  @override
  String get cfBudgetsSuggestDialogTitle => 'Presupuestos sugeridos';

  @override
  String cfBudgetsSuggestDialogSubtitle(int months) {
    return 'Según tu gasto de los últimos $months meses. Elige cuáles agregar.';
  }

  @override
  String cfBudgetsSuggestAvg(String amount) {
    return 'Promedia $amount/mes';
  }

  @override
  String get cfBudgetsSuggestSelectAll => 'Seleccionar todo';

  @override
  String get cfBudgetsSuggestClear => 'Limpiar';

  @override
  String cfBudgetsSuggestApply(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Agregar $count',
      zero: 'Agregar',
    );
    return '$_temp0';
  }

  @override
  String cfBudgetsShowAll(int count) {
    return 'Ver $count más';
  }

  @override
  String get cfBudgetsShowFewer => 'Ver menos';

  @override
  String cfInsightRecentLabel(String monthLabel) {
    return 'Gastado en $monthLabel';
  }

  @override
  String cfInsightAvgLabel(int months) {
    return 'Promedio de $months meses';
  }

  @override
  String cfInsightDelta(String amount, String percent) {
    return '$amount sobre el promedio ($percent)';
  }

  @override
  String cfInsightTrendTitle(int months) {
    return 'Últimos $months meses';
  }

  @override
  String cfInsightTrendSemantics(String category, int months) {
    return 'Gasto mensual en $category en los últimos $months meses';
  }

  @override
  String cfInsightTopMerchantsTitle(String monthLabel) {
    return 'Principales comercios en $monthLabel';
  }

  @override
  String cfInsightMerchantTxCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transacciones',
      one: '1 transacción',
    );
    return '$_temp0';
  }

  @override
  String get cfInsightNoMerchantData =>
      'Aún no hay transacciones cargadas para este mes';

  @override
  String get cfInsightSeeTransactions => 'Ver todas las transacciones';

  @override
  String get cfInsightSetBudget => 'Establecer presupuesto';

  @override
  String get cfInsightUpdateBudget => 'Actualizar presupuesto';

  @override
  String cfInsightBudgetDialogTitle(String category) {
    return 'Presupuesto mensual para $category';
  }

  @override
  String cfInsightBudgetDialogHint(int months) {
    return 'Sugerido según tu promedio de $months meses';
  }

  @override
  String cfInsightBudgetSaved(String amount, String category) {
    return 'Presupuesto guardado: $amount para $category';
  }

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
  String impHoldingsNotAttached(Object error) {
    return 'Movimientos importados, pero no se adjuntaron las posiciones del estado de cuenta: $error';
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
  String get impAlreadyImported => 'Ya importado';

  @override
  String get impCreateAccountForImport => 'Nueva cuenta (p. ej. Banamex)';

  @override
  String get impOcrHint =>
      'Los estados de cuenta escaneados o fotografiados se leen con reconocimiento de texto (OCR), lo que puede tardar hasta un minuto por archivo: es normal, no está atorado.';

  @override
  String get impCleanupTitle => 'Gestionar importaciones';

  @override
  String get impRecentImports => 'Importaciones recientes';

  @override
  String get impNoRecentImports =>
      'Aún no hay importaciones registradas. Las que hagas de ahora en adelante aparecerán aquí y podrás deshacerlas.';

  @override
  String get impUndo => 'Deshacer';

  @override
  String get impUndoImport => 'Deshacer importación';

  @override
  String impUndoImportConfirm(Object count) {
    return '¿Eliminar las $count transacciones de esta importación?';
  }

  @override
  String get impDelete => 'Eliminar';

  @override
  String impDeletedN(Object count) {
    return 'Se eliminaron $count transacciones';
  }

  @override
  String get impBulkDelete => 'Limpiar por cuenta y fecha';

  @override
  String get impBulkDeleteHint =>
      'Para importaciones hechas antes de esta actualización (sin lote). Elimina las transacciones en la cuenta y el rango de fechas elegidos.';

  @override
  String get impOnlyImported => 'Solo transacciones importadas';

  @override
  String get impPreview => 'Vista previa';

  @override
  String impWillDelete(Object count) {
    return 'Se eliminarán $count transacciones';
  }

  @override
  String get impFrom => 'Desde';

  @override
  String get impTo => 'Hasta';

  @override
  String get impTransactionsLabel => 'transacciones';

  @override
  String get impCleanupFillAll => 'Elige una cuenta y ambas fechas';

  @override
  String get impFileWaiting => 'en espera…';

  @override
  String get impFileParsing => 'procesando…';

  @override
  String get impFileSkipped => 'omitido';

  @override
  String impFileTransactions(Object count) {
    return '$count transacciones';
  }

  @override
  String impFileTooLarge(Object file, Object totalMb) {
    return '«$file» pesa $totalMb MB, supera el límite de 100 MB para un solo archivo y no se puede dividir. Intenta exportar un periodo más corto del estado de cuenta.';
  }

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
  String dashFxPill(Object base, Object rate, Object target) {
    return '$base/$target $rate';
  }

  @override
  String dashFxRateEquation(Object base, Object rate) {
    return '1 $base = $rate';
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
  String get dashImportMxCsvPdf => 'Importar un estado de cuenta (CSV o PDF)';

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
  String get ovDetailsTitle => 'Detalles';

  @override
  String get ovDetailsSubtitle => 'Estadísticas, meta y fondo de emergencia';

  @override
  String get mgmtConnectionsTitle => 'Conexiones y sincronización';

  @override
  String get mgmtConnectionsSubtitle =>
      'Bancos, estado de sincronización y tipo de cambio';

  @override
  String get dashSyncingAll => 'Sincronizando todas las instituciones…';

  @override
  String dashSyncingProgress(int done, int total) {
    return 'Actualizando… ($done de $total)';
  }

  @override
  String get dashSyncComplete => 'Sincronización completa';

  @override
  String get dashSyncStillRunning =>
      'La sincronización está tardando más de lo normal; sigue ejecutándose en segundo plano';

  @override
  String dashSyncFailed(Object error) {
    return 'Falló la sincronización: $error';
  }

  @override
  String dashSyncedAt(Object when) {
    return 'Sincronizado $when';
  }

  @override
  String get dashSyncNow => 'Sincronizar';

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
  String get dashImportMxShort => 'Importar estado de cuenta';

  @override
  String get dashAddManualAccountShort => 'Agregar cuenta manual';

  @override
  String get dashConnectCryptoExchanges => 'Conectar exchanges de cripto';

  @override
  String get dashLinkCoinbase => 'Vincular Coinbase';

  @override
  String get dashConnectBitso => 'Conectar Bitso';

  @override
  String get dashAddAccountsTitle => 'Agregar cuentas';

  @override
  String get dashSetupReadyPill => 'Listo';

  @override
  String get dashSetupShowDetails => 'Mostrar detalles';

  @override
  String get dashSetupHideDetails => 'Ocultar detalles';

  @override
  String get dashSetupCheckPlaid => 'Vinculación de cuentas con Plaid';

  @override
  String get dashSetupCheckEncryption => 'Cifrado de credenciales';

  @override
  String get dashSetupCheckFx => 'Tipos de cambio';

  @override
  String get dashSetupCheckCoinbase => 'OAuth de Coinbase';

  @override
  String get dashSetupCheckPlaidWebhook => 'URL del webhook de Plaid';

  @override
  String get dashSetupCheckCors => 'Lista de orígenes permitidos (CORS)';

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
  String get dashThemeSystemShort => 'Sistema';

  @override
  String get dashThemeLightShort => 'Claro';

  @override
  String get dashThemeDarkShort => 'Oscuro';

  @override
  String get dashThemeMenu => 'Tema';

  @override
  String get dashPreferencesTitle => 'Preferencias';

  @override
  String get dashLanguageLabel => 'Idioma';

  @override
  String get dashAccountSecurityTitle => 'Cuenta y seguridad';

  @override
  String get dashServerLabel => 'Servidor';

  @override
  String get dashServerChangeTitle => '¿Cambiar de servidor?';

  @override
  String get dashServerChangeBody => 'Cambiar de servidor cerrará tu sesión.';

  @override
  String dashThemeTooltip(Object label) {
    return '$label · toca para alternar, mantén presionado para elegir';
  }

  @override
  String get dashSearchCommandsTooltip => 'Buscar y comandos (⌘K)';

  @override
  String get projTitle => 'Proyección de patrimonio';

  @override
  String get projSubtitle =>
      'Proyecta tu futuro financiero con base en tus activos actuales y tu estrategia de ahorro.';

  @override
  String get projMonthlySavings => 'Ahorro mensual';

  @override
  String get projAnnualExpenses => 'Gastos anuales';

  @override
  String get projSafeWithdrawalRate => 'Tasa de retiro segura';

  @override
  String get projProjectionYears => 'Años de proyección';

  @override
  String get projGoal => 'Meta';

  @override
  String get projClear => 'Borrar';

  @override
  String projGoalHitBy(Object amount, Object year) {
    return 'Alcanzar $amount para $year';
  }

  @override
  String get projGoalSetTarget => 'Define una meta, p. ej. \$1M para 2030';

  @override
  String get projSetTargetTitle => 'Definir una meta';

  @override
  String get projTargetNetWorth => 'Patrimonio objetivo';

  @override
  String get projTargetYear => 'Año objetivo';

  @override
  String get projNetWorthProjection => 'Proyección de patrimonio neto';

  @override
  String projTooltipYearAmount(Object amount, Object year) {
    return '$year · $amount';
  }

  @override
  String get projFiNumber => 'Número FI';

  @override
  String get projYearsToFi => 'Años para FI';

  @override
  String get projEstimate => 'Estimación';

  @override
  String get projIncomeAtProjectedBalance => 'Ingreso al saldo proyectado';

  @override
  String get projIncomeAtProjectedBalanceSub =>
      'Mensual · saldo proyectado × tasa de retiro';

  @override
  String get projInflation => 'Inflación';

  @override
  String get projYearsToRetirement => 'Años para el retiro';

  @override
  String get projVolatility => 'Volatilidad del rendimiento';

  @override
  String get projExpectedReturnNominal => 'Rendimiento esperado (nominal)';

  @override
  String get projRange => 'Rango';

  @override
  String get projRealNote => 'Cifras en dólares de hoy';

  @override
  String get projSuccessRate => 'Tasa de éxito';

  @override
  String get projSuccessRateSub =>
      'Probabilidad de que el plan dure el horizonte';

  @override
  String get projSuccessRateNa => 'n/d — sin fase de retiro en esta proyección';

  @override
  String get projCoastReachedSub =>
      'Solo el crecimiento alcanza tu meta — puedes dejar de aportar.';

  @override
  String get projBaristaFiSub =>
      'Capital necesario cuando un ingreso de medio tiempo ayuda a cubrir gastos';

  @override
  String get projBaristaIncome => 'Ingreso Barista / pensión';

  @override
  String get projFromYourData => 'De tus gastos registrados';

  @override
  String get projBandLegend => 'Rango percentil 10–90';

  @override
  String get projHelpExpectedReturn =>
      'Rendimiento anual bruto antes de inflación. ~7% ≈ el promedio histórico de la bolsa.';

  @override
  String get projHelpInflation =>
      'Reduce el dinero futuro a su valor de hoy. ~3% es el promedio de largo plazo.';

  @override
  String get projHelpVolatility =>
      'Qué tan variables son los rendimientos — amplía el rango sombreado de resultados. ~13% ≈ una cartera con mucha renta variable.';

  @override
  String get projHelpAnnualExpenses =>
      'Tu gasto anual objetivo en el retiro, en dólares de hoy.';

  @override
  String get projHelpSwr =>
      'Cuánto retiras de la cartera cada año en el retiro. La clásica \'regla del 4%\' implica un capital de 25×.';

  @override
  String get projHelpBaristaIncome =>
      'Trabajo de medio tiempo, una pensión o seguro social en el retiro. Reduce el capital que necesitas — esto define el número FI Barista.';

  @override
  String get projHelpTaxDrag =>
      'Lo que los impuestos y comisiones de fondos restan a tu rendimiento cada año. ~0.5–1% es lo típico.';

  @override
  String get projLegendProjected => 'Proyectado (trayectoria promedio)';

  @override
  String projLegendTarget(Object flavor) {
    return 'Objetivo $flavor';
  }

  @override
  String get projLegendGoal => 'Tu meta';

  @override
  String get projHelpYearsToRetirement =>
      'Cuándo dejas de aportar y empiezas a retirar — también define el objetivo de Coast FIRE.';

  @override
  String get projAdvancedAssumptions => 'Supuestos avanzados';

  @override
  String get projGlossaryTitle => '¿Qué significan estos términos?';

  @override
  String get projTermCoast => 'Coast FIRE';

  @override
  String get projTermBarista => 'Barista FI';

  @override
  String get projTermRange => 'El rango sombreado';

  @override
  String get projTermRealDollars => 'Dólares de hoy';

  @override
  String get projGlossaryFiNumberDef =>
      'El capital que te permite vivir de los retiros indefinidamente — aproximadamente tu gasto anual × 25 con una tasa de retiro del 4%.';

  @override
  String get projGlossaryCoastDef =>
      'La cantidad que, invertida hoy, crecería hasta tu número FI al llegar al retiro sin ahorrar más — alcánzala y puedes dejar de aportar.';

  @override
  String get projGlossaryBaristaDef =>
      'Un objetivo menor: el trabajo de medio tiempo o una pensión cubre parte del gasto, así que tu cartera solo financia el resto.';

  @override
  String get projGlossarySwrDef =>
      'La parte de tu cartera que retiras cada año en el retiro. La conocida \'regla del 4%\' es el valor por defecto aquí.';

  @override
  String get projGlossaryRangeDef =>
      'La banda es una simulación de mercado de 1,000 corridas — el rango de buena y mala suerte. La \'tasa de éxito\' es con qué frecuencia el dinero dura todo el horizonte.';

  @override
  String get projGlossaryRealDef =>
      'Cada cifra está en dólares de hoy, así que un monto futuro ya considera la inflación.';

  @override
  String get projTermAveragePath => 'La línea gruesa proyectada';

  @override
  String get projGlossaryAveragePathDef =>
      'La línea gruesa compone tu rendimiento esperado exactamente — la trayectoria promedio. El resultado típico (mediano) de la simulación suele ser menor, así que léela como una ilustración, no un pronóstico.';

  @override
  String get projFirePlanTitle => 'Tu plan FIRE';

  @override
  String get projGoalLabel => 'Meta';

  @override
  String get projTermLifestyle => 'Austero / Estándar / Holgado';

  @override
  String get projGlossaryLifestyleDef =>
      'Niveles de estilo de vida — Austero es frugal, Holgado es generoso, Estándar ≈ tu gasto registrado. Definen tus gastos anuales, que a su vez definen cada objetivo.';

  @override
  String get projFocusFull => 'FIRE completo';

  @override
  String get projFullReached =>
      'Alcanzaste tu número FI — el FIRE completo está cubierto.';

  @override
  String projFullYearsAway(Object years) {
    return 'A unos $years años a tu ritmo actual.';
  }

  @override
  String get projFullUnreachable =>
      'No alcanzable a tu ritmo actual — sube el ahorro o el rendimiento.';

  @override
  String projCoastTake(Object amount) {
    return 'Vas en $amount hoy — cierra la brecha y el crecimiento hace el resto.';
  }

  @override
  String get projBaristaPrompt =>
      'Ajusta \'Ingreso Barista / pensión\' arriba para ver este objetivo menor.';

  @override
  String get projSpendingLevel => 'Estilo de vida';

  @override
  String get projPresetLean => 'Austero';

  @override
  String get projPresetStandard => 'Estándar';

  @override
  String get projPresetFat => 'Holgado';

  @override
  String get projTaxDrag => 'Carga fiscal';

  @override
  String get projGuardrails => 'Barandillas de gasto';

  @override
  String get projGuardrailsOn =>
      'Barandillas activas — el gasto se ajusta al mercado';

  @override
  String get projGuardrailsOff => 'Gasto fijo — sin ajuste en caídas';

  @override
  String get projLoadFailed => 'No se pudo cargar tu proyección.';

  @override
  String get projRetry => 'Reintentar';

  @override
  String projBasedOnMonths(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: 'Basado en $months meses de tus datos',
      one: 'Basado en 1 mes de tus datos',
    );
    return '$_temp0';
  }

  @override
  String get projExpensesEstimateHint => 'Estimación — ajústala a tu gasto';

  @override
  String get projGoalAmountInvalid =>
      'Ingresa un monto mayor que cero (hasta mil millones)';

  @override
  String projGoalYearRange(int min, int max) {
    return 'Ingresa un año entre $min y $max';
  }

  @override
  String get projGoalSaveFailed => 'No se pudo guardar tu meta';

  @override
  String get projRetirementMarker => 'Retiro';

  @override
  String projGoalOffChart(String amount) {
    return 'Tu meta: $amount';
  }

  @override
  String projValueEntryRange(String min, String max) {
    return 'Ingresa un monto entre $min y $max';
  }

  @override
  String projValueEntryRangePercent(String min, String max) {
    return 'Ingresa una tasa entre $min y $max';
  }

  @override
  String projValueEntryWholeYears(int min, int max) {
    return 'Ingresa un número entero de años entre $min y $max';
  }

  @override
  String projSavingsRateCaption(String pct) {
    return 'Estás ahorrando alrededor del $pct de tus ingresos';
  }

  @override
  String get taxTitle => 'Planeación fiscal';

  @override
  String get taxFilingSingle => 'Soltero';

  @override
  String get taxFilingMarried => 'Casado';

  @override
  String get taxFilingHeadOfHousehold => 'Jefe de familia';

  @override
  String get taxCsvLaunchFailed => 'No se pudo abrir la exportación CSV.';

  @override
  String get taxPdfLaunchFailed => 'No se pudo abrir la exportación PDF.';

  @override
  String taxLoadError(Object error) {
    return 'Error al cargar los datos fiscales: $error';
  }

  @override
  String get taxRetry => 'Reintentar';

  @override
  String get taxSectionLoadFailed =>
      'No se pudo cargar esta sección — las cifras de abajo no son un resultado.';

  @override
  String get taxExportCsv => 'Exportar CSV';

  @override
  String get taxExportPdf => 'PDF';

  @override
  String get taxExportsTitle => 'Paquete de exportación fiscal';

  @override
  String get taxExportsSubtitle =>
      'Documentos con formato de declaración generados a partir de las cifras de esta pantalla — elige un año fiscal y descarga cada uno.';

  @override
  String get taxExportsFbar => 'Hoja de trabajo FBAR (FinCEN 114)';

  @override
  String get taxExportsFbarDesc =>
      'Saldo máximo anual por cuenta extranjera, en USD. Imprimible.';

  @override
  String get taxExports8949 => 'CSV Formulario 8949';

  @override
  String get taxExports8949Desc =>
      'Ganancias realizadas divididas en corto/largo plazo con ingresos, costo base y ganancia.';

  @override
  String get taxExportsScheduleB => 'CSV de intereses (Anexo B)';

  @override
  String get taxExportsScheduleBDesc =>
      'Intereses por pagador — préstamos personales más intereses bancarios y de CETES/bonos.';

  @override
  String get taxExportsMx => 'CSV resumen anual MX';

  @override
  String get taxExportsMxDesc =>
      'Ingresos, dividendos, intereses y ganancias realizadas con la estimación simplificada del SAT.';

  @override
  String get taxTotalTaxableIncome => 'Ingreso gravable total';

  @override
  String taxOrdinaryIncome(Object amount) {
    return 'Ingreso ordinario: $amount';
  }

  @override
  String taxCapitalGains(Object amount) {
    return 'Ganancias de capital: $amount';
  }

  @override
  String taxStLtBreakdown(String st, String lt) {
    return 'Corto plazo $st · Largo plazo $lt';
  }

  @override
  String taxIncomeDecomposition(
    String wages,
    String dividends,
    String interest,
  ) {
    return 'Salario $wages · Dividendos $dividends · Intereses $interest';
  }

  @override
  String taxMxWithheld(String withheld, String net) {
    return 'ISR ya retenido $withheld · est. restante $net';
  }

  @override
  String get taxUsEstimatedLiability => 'Impuesto estimado EE. UU. (IRS)';

  @override
  String get taxMxEstimatedLiability => 'Impuesto estimado MX (SAT)';

  @override
  String taxEffectiveRate(Object rate) {
    return 'Tasa efectiva: $rate%';
  }

  @override
  String get taxTaxableEvents => 'Eventos gravables';

  @override
  String get taxNoEventsTitle =>
      'No se encontraron eventos gravables para este año.';

  @override
  String get taxNoEventsBody =>
      'Aquí aparecerán las transacciones de ingresos, salario, intereses y venta de inversiones.';

  @override
  String taxDisclaimer(String bracketYear) {
    return 'Aviso: las estimaciones fiscales son aproximaciones basadas en los tramos del IRS/SAT $bracketYear. Consulta a un profesional fiscal calificado para tu declaración.';
  }

  @override
  String get taxConstantsUnverified =>
      'Estimaciones — constantes fiscales pendientes de verificación';

  @override
  String get taxFilingStatusLabel => 'Estado civil fiscal';

  @override
  String get taxYearLabel => 'Año fiscal';

  @override
  String get taxRealizedGainsTitle => 'Ganancias realizadas';

  @override
  String get taxIncomeSectionTitle => 'Ingresos';

  @override
  String get taxTermShort => 'Corto';

  @override
  String get taxTermLong => 'Largo';

  @override
  String get taxTermUnknown => 'Desconocido';

  @override
  String get taxColProceeds => 'Ingresos';

  @override
  String get taxColCost => 'Costo';

  @override
  String get taxAcquiredUnknown => 'Adquirido —';

  @override
  String taxAcquiredToSold(String acquired, String sold) {
    return '$acquired → $sold';
  }

  @override
  String get taxTaxAdvantagedBadge => 'Con beneficio fiscal';

  @override
  String get taxTaxAdvantagedSection =>
      'Cuentas con beneficio fiscal (excluidas de los totales gravables)';

  @override
  String get taxTaxAdvantagedNote =>
      'Disposiciones dentro de cuentas tipo 401(k)/IRA/HSA. No forman parte del total gravable de arriba.';

  @override
  String taxGainsSubtotal(String amount) {
    return 'Ganancia realizada neta: $amount';
  }

  @override
  String taxIncomeSubtotal(String amount) {
    return 'Ingreso total: $amount';
  }

  @override
  String taxSubtotalReconcileNote(String kpi) {
    return 'Coincide con la tarjeta $kpi de arriba.';
  }

  @override
  String get taxNoDisposals => 'No hay disposiciones realizadas para este año.';

  @override
  String get taxScenarioUsSubtitle =>
      'Si todo el ingreso se gravara en EE. UU.';

  @override
  String get taxScenarioMxSubtitle => 'Si todo el ingreso se gravara en México';

  @override
  String get taxScenarioUsCaveat =>
      'Solo federal — sin NIIT ni impuesto estatal, sin crédito por impuestos extranjeros.';

  @override
  String get taxScenarioMxCaveat =>
      'Todo pasado por la tarifa de ISR de salarios (una simplificación).';

  @override
  String get taxScenariosNote =>
      'Son dos escenarios alternativos sobre el mismo ingreso, no cantidades que se sumen entre sí.';

  @override
  String get taxRoughEstimateBadge => 'Estimación aproximada';

  @override
  String get taxRoughEstimateTooltip =>
      'Sin lotes de compra registrados — las ganancias usan un costo base estimado.';

  @override
  String get taxAssumptionsTitle => 'Supuestos';

  @override
  String taxAssumptionBracketYear(String year) {
    return 'Año de tramos: $year';
  }

  @override
  String get taxAssumptionFx =>
      'Tipo de cambio: cada fila convertida al tipo USD/MXN guardado de su propia fecha.';

  @override
  String taxAssumptionFilingStatus(String status) {
    return 'Estado civil fiscal: $status';
  }

  @override
  String get taxAssumptionExclusions =>
      'Excluye cuentas con beneficio fiscal (401(k)/IRA/HSA).';

  @override
  String taxAssumptionHoldingsNoBasis(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count posiciones sin costo base registrado',
      one: '1 posición sin costo base registrado',
    );
    return '$_temp0';
  }

  @override
  String get taxAssumptionProReview =>
      'La redacción y las constantes están pendientes de revisión por un profesional fiscal — tómalo como orientación, no como asesoría.';

  @override
  String get taxUnrealizedTitle =>
      'Posiciones no realizadas — qué pasa si vendo';

  @override
  String get taxUnrealizedShortTerm => 'Lotes a corto plazo';

  @override
  String get taxUnrealizedLongTerm => 'Lotes a largo plazo';

  @override
  String get taxNoUnrealizedLots => 'No hay lotes gravables para evaluar.';

  @override
  String taxUnrealizedSubtotal(String amount) {
    return 'No realizada: $amount';
  }

  @override
  String taxFlipsToLongIn(String days, String date) {
    return 'Largo plazo en $days d — $date';
  }

  @override
  String get taxColBasis => 'Costo base';

  @override
  String get taxColValue => 'Valor';

  @override
  String get taxHarvestTitle => 'Candidatos para cosechar pérdidas';

  @override
  String taxHarvestEstimate(String amount) {
    return 'Ahorro fiscal est. $amount';
  }

  @override
  String get taxHarvestEstimateBadge => 'Estimado';

  @override
  String get taxHarvestEstimateTooltip =>
      'Pérdida × tu tasa marginal — un estimado con constantes sin verificar, no un ahorro garantizado.';

  @override
  String get taxHarvestNote =>
      'Vender estas posiciones en pérdida podría compensar ganancias. Ahorro estimado = pérdida × tu tasa marginal.';

  @override
  String get taxNoHarvestCandidates =>
      'No hay lotes en pérdida para cosechar por ahora.';

  @override
  String get taxHarvestLossesNoSavings =>
      'Hay lotes en pérdida arriba, pero con esta estimación simplificada (pérdida × tasa marginal) venderlos no reduciría tu impuesto estimado por ahora.';

  @override
  String get taxWashSaleMarker => 'Venta ficticia';

  @override
  String taxWashSaleSafeAfter(String date) {
    return 'Se puede recomprar después del $date';
  }

  @override
  String get taxWashSaleTooltip =>
      'Una recompra del mismo valor cerca de esta fecha puede anular la pérdida. Recomprar después de la fecha segura evita la regla de venta ficticia (wash sale).';

  @override
  String get taxFbarTitle => 'Cuentas en el extranjero — monitor FBAR';

  @override
  String get taxFbarPeakAggregate =>
      'Saldo extranjero agregado máximo (este año)';

  @override
  String taxFbarThreshold(String amount) {
    return 'Umbral de reporte FBAR: $amount';
  }

  @override
  String get taxFbarExceeded => 'El agregado superó el umbral este año';

  @override
  String get taxFbarUnder => 'El agregado se mantuvo bajo el umbral este año';

  @override
  String taxFbarPeakDate(String date) {
    return 'Máximo el $date';
  }

  @override
  String get taxFbarInformational =>
      'Solo informativo — esto no determina una obligación de presentar el FBAR. Consulta a un profesional fiscal.';

  @override
  String get taxFbarFatcaNote =>
      'Los umbrales del Formulario 8938 (FATCA) son distintos y más altos, y no se calculan aquí.';

  @override
  String get taxFbarNoForeignAccounts =>
      'No se detectaron cuentas en el extranjero para este año.';

  @override
  String get taxFbarConfirmLocation => 'Confirma la ubicación';

  @override
  String get taxFbarConfirmLocationTooltip =>
      'Esta institución no tiene país configurado, así que la cuenta se contó como extranjera solo por estar en MXN. Configura el país de la institución para confirmarlo o corregirlo.';

  @override
  String taxFbarAccountPeak(String amount) {
    return 'En la fecha máxima: $amount';
  }

  @override
  String taxFbarAccountYtdMax(String amount) {
    return 'Máximo propio del año: $amount';
  }

  @override
  String get taxRetirementTitle => 'Aportaciones para el retiro';

  @override
  String get taxRetirementGroup401k => '401(k) / 403(b) / 457(b)';

  @override
  String get taxRetirementGroupIra => 'IRA (Tradicional + Roth)';

  @override
  String get taxRetirementGroupHsa => 'HSA';

  @override
  String taxContributedOfLimit(String ytd, String limit) {
    return '$ytd de $limit';
  }

  @override
  String get taxBackdoorRothBadge => 'Roth puerta trasera';

  @override
  String taxMegaBackdoorNote(String elective, String room) {
    return 'Total §415(c) (electivo + empleador + después de impuestos); límite electivo $elective. Queda $room de espacio mega-backdoor Roth.';
  }

  @override
  String get taxHsaFamilyCoverage => 'Cobertura familiar';

  @override
  String taxHsaEmployerNote(String amount) {
    return 'incluye $amount del empleador';
  }

  @override
  String get tax401kElectiveSet =>
      '+ Indica tu aportación electiva para desglosarlo';

  @override
  String tax401kElectiveSplit(String elective, String limit, String rest) {
    return 'Electiva $elective de $limit · empleador + después de impuestos $rest';
  }

  @override
  String get tax401kElectiveDialogTitle => 'Aportación electiva anual al 401k';

  @override
  String tax401kElectiveDialogHint(String limit) {
    return 'Tu aportación como empleado (pre-impuestos + Roth); límite $limit';
  }

  @override
  String taxRemainingRoom(String amount) {
    return 'Espacio restante: $amount';
  }

  @override
  String taxContributionDeadline(String date) {
    return 'Fecha límite: $date';
  }

  @override
  String get taxPriorYearWindowNote =>
      'Se permiten aportaciones del año anterior hasta esta fecha límite.';

  @override
  String get taxMatchRolloverCaveat =>
      'Puede incluir aportación del empleador o traspasos — las aportaciones personales podrían sobrecontarse.';

  @override
  String get taxContributionOverLimit => 'Por encima del límite base';

  @override
  String taxCatchUpNote(String amount) {
    return '+$amount de recuperación si cumples la edad';
  }

  @override
  String get taxNoRetirementAccounts =>
      'No hay cuentas de retiro con aportaciones este año.';

  @override
  String get acctxRenameAccount => 'Renombrar cuenta';

  @override
  String get acctxNickname => 'Apodo';

  @override
  String get acctxAccountFallback => 'Cuenta';

  @override
  String acctxUpdateBalanceTitle(Object account) {
    return 'Actualizar saldo de $account';
  }

  @override
  String get acctxCurrentBalance => 'Saldo actual';

  @override
  String get acctxAccountActions => 'Acciones de la cuenta';

  @override
  String get acctxUpdateBalance => 'Actualizar saldo';

  @override
  String acctxLoadError(Object error) {
    return 'Error al cargar las transacciones: $error';
  }

  @override
  String get acctxRetry => 'Reintentar';

  @override
  String get acctxBalanceOverTime => 'Saldo a lo largo del tiempo';

  @override
  String get acctxSetLowBalanceAlert => 'Crear alerta de saldo bajo';

  @override
  String get acctxEditLowBalanceAlert => 'Editar alerta de saldo bajo';

  @override
  String get acctxLowBalanceAlertTitle => 'Alerta de saldo bajo';

  @override
  String get acctxLowBalanceAlertBody =>
      'Marcaremos esta cuenta y agregaremos una notificación cuando su saldo baje a este monto o menos.';

  @override
  String get acctxThresholdLabel => 'Avísame por debajo de';

  @override
  String get acctxRemoveAlert => 'Quitar alerta';

  @override
  String get acctxAlertSaved => 'Alerta de saldo bajo guardada';

  @override
  String get acctxAlertRemoved => 'Alerta de saldo bajo eliminada';

  @override
  String acctxLowBalanceBanner(Object amount) {
    return 'El saldo está en o por debajo de tu alerta de $amount';
  }

  @override
  String get acctxNoTransactionsTitle => 'Aún no hay transacciones';

  @override
  String get acctxNoTransactionsBody =>
      'Es posible que los registros apenas comiencen, o que las cuentas sin conexión no tengan historial.';

  @override
  String acctxUpdateFailed(Object error) {
    return 'No se pudo actualizar la transacción: $error';
  }

  @override
  String get acctxDismissBarrier => 'Cerrar';

  @override
  String get hiddenTitle => 'Elementos ocultos';

  @override
  String hiddenRestoredMerchant(Object merchant) {
    return 'Se restauró \"$merchant\"';
  }

  @override
  String hiddenRestoreFailed(Object error) {
    return 'No se pudo restaurar: $error';
  }

  @override
  String get hiddenBannerWillReappear =>
      'El aviso de \"desde el último inicio de sesión\" volverá a aparecer.';

  @override
  String hiddenFxPairRestored(Object summary) {
    return 'Restaurado: el detector podría volver a proponer $summary en la próxima sincronización.';
  }

  @override
  String get hiddenIntro =>
      'Cosas que le pediste a Patrimonio que dejara de mostrar. Al restaurar una fila, vuelve a donde normalmente aparece.';

  @override
  String get hiddenRecurringCharges => 'Cargos recurrentes';

  @override
  String get hiddenNoSubscriptions =>
      'No hay suscripciones ocultas por ahora. Cuando descartas una fila con la × en la tarjeta de Cargos recurrentes, aparece aquí.';

  @override
  String get hiddenBanners => 'Avisos';

  @override
  String get hiddenNoBanners => 'No hay avisos descartados por ahora.';

  @override
  String get hiddenSinceLastLogin => 'Desde tu última visita';

  @override
  String hiddenHiddenForVisit(Object date) {
    return 'Oculto para la visita que inició el $date';
  }

  @override
  String get hiddenShowAgain => 'Mostrar de nuevo';

  @override
  String get hiddenFxTransferPairs => 'Pares de transferencias en divisas';

  @override
  String get hiddenNoFxPairs =>
      'No hay pares de divisas descartados por ahora. Cuando desvinculas una transferencia detectada de Wise / Remitly / Xoom en la pestaña de Transacciones, llega aquí para que el detector no la vuelva a proponer.';

  @override
  String hiddenDismissedAt(Object date) {
    return 'Descartado el $date';
  }

  @override
  String get hiddenRestore => 'Restaurar';

  @override
  String get hiddenClosedAccounts => 'Cuentas cerradas';

  @override
  String get hiddenClosedAccountsIntro =>
      'Cuentas que Patrimonio archivó porque se cerraron o se eliminaron en el banco. Ya no cuentan para tu patrimonio neto. Restaura una para recuperarla o elimínala de forma permanente.';

  @override
  String get hiddenNoClosedAccounts =>
      'No hay cuentas cerradas. Cuando un banco reporta una cuenta como cerrada, aparece aquí en lugar de desaparecer.';

  @override
  String get accountRestore => 'Restaurar';

  @override
  String accountRestored(String name) {
    return 'Se restauró \"$name\"';
  }

  @override
  String get accountDeletePermanently => 'Eliminar permanentemente';

  @override
  String get accountDeleteConfirmTitle =>
      '¿Eliminar la cuenta permanentemente?';

  @override
  String accountDeleteConfirmBody(String name) {
    return 'Esto elimina permanentemente \"$name\" y todas sus transacciones. No se puede deshacer.';
  }

  @override
  String accountDeleted(String name) {
    return 'Se eliminó \"$name\"';
  }

  @override
  String accountClosedOn(Object date) {
    return 'Cerrada el $date';
  }

  @override
  String get cbTitle => 'Conectar banco';

  @override
  String get cbSetupIncompleteTitle =>
      'La configuración de Plaid está incompleta.';

  @override
  String get cbSetupIncompleteBody =>
      'Configura las credenciales de Plaid y ENCRYPTION_KEY antes de vincular cuentas bancarias reales.';

  @override
  String get cbConnectWithPlaid => 'Conectar con Plaid';

  @override
  String get cbEnvSandbox => 'Modo Sandbox de Plaid — Solo datos de prueba';

  @override
  String get cbEnvDevelopment =>
      'Modo Development de Plaid — Datos reales de cuenta (elementos de prueba)';

  @override
  String get cbEnvProduction =>
      'Modo Production de Plaid — Datos reales de cuenta';

  @override
  String cbEnvUnknown(Object env) {
    return 'Entorno de Plaid: $env';
  }

  @override
  String get cbConnected =>
      'Banco conectado. La sincronización inicial ya comenzó.';

  @override
  String get cbExchangeTokenFailed => 'No se pudo intercambiar el token';

  @override
  String cbBackendCommError(Object error) {
    return 'Error al comunicarse con el servidor: $error';
  }

  @override
  String get cbLinkTokenFailed => 'No se pudo obtener el token de vinculación';

  @override
  String cbBackendConnectError(Object error) {
    return 'Error al conectarse con el servidor: $error';
  }

  @override
  String cbHttpError(Object fallback, Object status) {
    return '$fallback: HTTP $status';
  }

  @override
  String cbPlaidError(Object message) {
    return 'Error de Plaid: $message';
  }

  @override
  String get pfAssetBreakdown => 'Desglose de activos';

  @override
  String get pfByType => 'Por tipo';

  @override
  String get pfByInstitution => 'Por institución';

  @override
  String get pfOther => 'Otros';

  @override
  String get pfBank => 'Banco';

  @override
  String get pfNetWorthGoal => 'Meta de patrimonio';

  @override
  String get pfGoalDueNow => 'vencida';

  @override
  String pfGoalYearsLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'quedan $count años',
      one: 'queda 1 año',
    );
    return '$_temp0';
  }

  @override
  String pfGoalHitBy(Object amount, Object remaining, Object year) {
    return 'Alcanzar $amount para $year · $remaining';
  }

  @override
  String pfGoalCurrent(Object amount) {
    return 'Actual: $amount';
  }

  @override
  String get pfShowingBands => 'Mostrando bandas por institución';

  @override
  String get pfShowingLine => 'Mostrando solo la línea de patrimonio';

  @override
  String get pfSimple => 'Simple';

  @override
  String get pfDetailed => 'Detallado';

  @override
  String pfTotalNetWorthCurrency(Object currency) {
    return 'Patrimonio total ($currency)';
  }

  @override
  String get pfTotalNetWorth => 'Patrimonio total';

  @override
  String pfTooltipNetWorth(Object value) {
    return 'Patrimonio: $value';
  }

  @override
  String pfTooltipAssets(Object value) {
    return 'Activos: $value';
  }

  @override
  String pfTooltipLiabilities(Object value) {
    return 'Pasivos: $value';
  }

  @override
  String pfDeltaVsAgo(Object window) {
    return 'vs. hace $window';
  }

  @override
  String get pfNoAccountsYet => 'Aún no hay cuentas';

  @override
  String get pfNoAccountsBody =>
      'Vincula un banco, importa un CSV o agrega una cuenta manual\npara comenzar.';

  @override
  String get pfAddAnAccount => 'Agregar una cuenta';

  @override
  String get pfAccountsHeader => 'CUENTAS';

  @override
  String get pfSearchAccounts => 'Buscar cuentas';

  @override
  String get pfHideZero => 'Ocultar \$0';

  @override
  String get pfNoAccountMatches => 'Ninguna cuenta coincide';

  @override
  String get pfClearFilters => 'Limpiar filtros';

  @override
  String get pfGroupCash => 'Efectivo';

  @override
  String get pfGroupInvestments => 'Inversiones';

  @override
  String get pfGroupCrypto => 'Cripto';

  @override
  String get pfGroupCreditCards => 'Tarjetas de crédito';

  @override
  String get pfGroupLoans => 'Préstamos e hipotecas';

  @override
  String get pfGroupRealAssets => 'Activos reales';

  @override
  String get pfGroupOther => 'Otros';

  @override
  String pfUnknownSubtypes(int count, Object list) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Subtipos desconocidos: $list',
      one: 'Subtipo desconocido: $list',
    );
    return '$_temp0';
  }

  @override
  String get pfVaults => 'Apartados';

  @override
  String get pfCards => 'Tarjetas';

  @override
  String get pfBase => 'base';

  @override
  String pfInstDescriptor(Object descriptor, Object inst) {
    return '$inst · $descriptor';
  }

  @override
  String get pfVault => 'Apartado';

  @override
  String get pfUnknownAccount => 'Cuenta desconocida';

  @override
  String get pfAccountActions => 'Acciones de la cuenta';

  @override
  String get pfRename => 'Renombrar';

  @override
  String get pfRevalue => 'Revaluar';

  @override
  String get pfDelete => 'Eliminar';

  @override
  String get pfDeleteAccountTitle => 'Eliminar cuenta';

  @override
  String pfDeleteAccountConfirm(Object name) {
    return '¿Seguro que quieres eliminar \"$name\"? Se borrará todo su historial.';
  }

  @override
  String pfRevalueTitle(Object name) {
    return 'Revaluar $name';
  }

  @override
  String pfRevalueCurrent(Object amount, Object currency) {
    return 'Actual: $amount $currency';
  }

  @override
  String get pfNewBalance => 'Nuevo saldo';

  @override
  String get pfNotesOptional => 'Notas (opcional)';

  @override
  String get pfNotesHint =>
      'ej. estimación de Zillow, avalúo 2026, última ronda';

  @override
  String get pfHistoryPointNote =>
      'Se registra un nuevo punto de historial con la fecha de hoy.';

  @override
  String get pfEnterNumericBalance => 'Ingresa un saldo numérico';

  @override
  String get pfAssetFallback => 'activo';

  @override
  String get pfRenameAccountTitle => 'Renombrar cuenta';

  @override
  String pfRenameOriginal(Object name) {
    return 'Original: $name';
  }

  @override
  String get pfNickname => 'Apodo';

  @override
  String get pfNicknameHint => 'ej. Cuenta conjunta';

  @override
  String get pfRenameBlankHint =>
      'Déjalo en blanco para usar el nombre del banco.';

  @override
  String get pfInvestmentPortfolio => 'Portafolio de inversión';

  @override
  String get pfTotalValue => 'Valor total';

  @override
  String get pfProfitLoss => 'Ganancia / Pérdida';

  @override
  String get pfUsDollar => 'Dólar estadounidense';

  @override
  String get pfMexicanPeso => 'Peso mexicano';

  @override
  String get pfTotalInMxn => 'Valor total en pesos';

  @override
  String get pfTotalInUsd => 'Valor total en dólares';

  @override
  String get pfHoldings => 'Posiciones';

  @override
  String pfAccountsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cuentas',
      one: '1 cuenta',
    );
    return '$_temp0';
  }

  @override
  String get pfTopPosition => 'Posición principal';

  @override
  String get pfBiggestGainer => 'Mayor ganadora';

  @override
  String get pfBiggestLoser => 'Mayor perdedora';

  @override
  String get pfSignalsTitle => 'Señales';

  @override
  String get pfConcentrated => 'Concentrado';

  @override
  String get pfViewLots => 'Ver lotes';

  @override
  String get pfUnknown => 'Desconocida';

  @override
  String pfInstPositions(Object inst, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count posiciones',
      one: '1 posición',
    );
    return '$inst · $_temp0';
  }

  @override
  String pfSharesSuffix(Object qty) {
    return '$qty acc.';
  }

  @override
  String pfCategoryFilter(Object category) {
    return 'Categoría: $category';
  }

  @override
  String get pfSearchHint => 'Buscar símbolo, nombre, cuenta o institución…';

  @override
  String pfHoldingsAccountsCount(int holdings, int accounts) {
    String _temp0 = intl.Intl.pluralLogic(
      holdings,
      locale: localeName,
      other: '$holdings posiciones',
      one: '1 posición',
    );
    String _temp1 = intl.Intl.pluralLogic(
      accounts,
      locale: localeName,
      other: '$accounts cuentas',
      one: '1 cuenta',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String fix3HoldingsAccountsCompact(int holdings, int accounts) {
    String _temp0 = intl.Intl.pluralLogic(
      accounts,
      locale: localeName,
      other: '$accounts ctas.',
      one: '1 cta.',
    );
    return '$holdings · $_temp0';
  }

  @override
  String pfShownOfTotal(Object shown, Object total) {
    return '$shown de $total';
  }

  @override
  String get pfFlat => 'Lista';

  @override
  String get pfByAccount => 'Por cuenta';

  @override
  String get pfNoHoldingsYet => 'Aún no hay posiciones';

  @override
  String get pfNoHoldingsBody =>
      'Cuando vincules una casa de bolsa con Plaid (o importes un CSV)\ntus posiciones aparecerán aquí.';

  @override
  String pfHoldingsShowAll(int count) {
    return 'Ver las $count posiciones';
  }

  @override
  String get pfHoldingsShowFewer => 'Ver menos';

  @override
  String get pfColAsset => 'Activo';

  @override
  String get pfColShares => 'Acciones';

  @override
  String get pfColPrice => 'Precio';

  @override
  String get pfColValue => 'Valor';

  @override
  String get pfColCostBasis => 'Costo base';

  @override
  String get pfCostBasisUnavailable =>
      'Costo base no disponible de esta institución';

  @override
  String get pfColGain => 'Ganancia';

  @override
  String get pfColReturn => 'Rendimiento';

  @override
  String get pfShares => 'acc.';

  @override
  String get pfHolding => 'Posición';

  @override
  String pfLotBreakdownTitle(Object title) {
    return 'Desglose por lote · $title';
  }

  @override
  String get pfLotBreakdownSubtitle =>
      'Orden FIFO. El costo base suma cada lote a su tipo de cambio USD/moneda nativa histórico, no al de hoy.';

  @override
  String get pfLotAcquired => 'Adquirido';

  @override
  String get pfLotQty => 'Cant.';

  @override
  String get pfLotCostPerUnit => 'Costo / unidad';

  @override
  String get pfLotFxAtLot => 'TC del lote';

  @override
  String get pfLotUsdCost => 'Costo USD';

  @override
  String get dlgAccountTitle => 'Agregar cuenta manual';

  @override
  String get dlgAccountName => 'Nombre de la cuenta';

  @override
  String get dlgAccountNameHint => 'p. ej. Mis ahorros, Propiedad en renta';

  @override
  String get dlgAccountType => 'Tipo de cuenta';

  @override
  String get dlgAccountClabe => 'CLABE';

  @override
  String get dlgAccountHolder => 'Titular de la cuenta';

  @override
  String get dlgAccountClabeInvalid => 'La CLABE debe tener 18 dígitos';

  @override
  String get acctDetailsToggle => 'Detalles de la cuenta';

  @override
  String get acctTypeChecking => 'Cheques';

  @override
  String get acctTypeSavings => 'Ahorros';

  @override
  String get acctTypeCD => 'Depósito a plazo';

  @override
  String get acctTypeBrokerage => 'Casa de bolsa';

  @override
  String get acctTypeInvestment => 'Inversión';

  @override
  String get acctTypeBonds => 'Bonos';

  @override
  String get acctTypeStockPlan => 'Plan de acciones';

  @override
  String get acctTypeIRA => 'IRA';

  @override
  String get acctType401k => '401(k)';

  @override
  String get acctTypeCrypto => 'Cripto';

  @override
  String get acctTypeRealEstate => 'Bienes raíces';

  @override
  String get acctTypeVehicle => 'Vehículo';

  @override
  String get acctTypePrivateEquity => 'Capital privado';

  @override
  String get acctTypeCollectibles => 'Coleccionables';

  @override
  String get acctTypeOtherAsset => 'Otro activo';

  @override
  String get acctTypeCreditCard => 'Tarjeta de crédito';

  @override
  String get acctTypeLoan => 'Préstamo';

  @override
  String get acctTypeMortgage => 'Hipoteca';

  @override
  String get acctTypeOtherLiability => 'Otro pasivo';

  @override
  String impAccountMatched(Object account) {
    return 'Coincide con $account del estado de cuenta';
  }

  @override
  String get impNoAccountMatch =>
      'Ninguna cuenta existente coincide con este estado de cuenta — crea una abajo.';

  @override
  String impAccountCreatedCue(Object account) {
    return 'Cuenta $account creada — se importará aquí';
  }

  @override
  String get impSummaryFound => 'Encontradas';

  @override
  String get impSummaryInflow => 'Ingresos';

  @override
  String get impSummaryOutflow => 'Egresos';

  @override
  String impSummaryFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count archivos',
      one: '1 archivo',
    );
    return '$_temp0';
  }

  @override
  String get impCoverageTitle => 'Cobertura de estados de cuenta';

  @override
  String impCoverageThrough(String month) {
    return 'hasta $month';
  }

  @override
  String impCoverageLastFile(String file) {
    return '$file';
  }

  @override
  String impCoverageImports(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count importaciones',
      one: '1 importación',
    );
    return '$_temp0';
  }

  @override
  String get impCoverageMaybeDue =>
      'Puede haber un estado de cuenta más reciente';

  @override
  String get impCoverageEmpty => 'Aún no se han importado estados de cuenta';

  @override
  String impAsOfDate(Object date) {
    return 'al $date';
  }

  @override
  String impStaleBannerSummary(int days, Object name) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days días',
      one: '1 día',
    );
    return 'Los datos de $name tienen $_temp0 — importa un estado de cuenta';
  }

  @override
  String impStaleBannerMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count instituciones más también necesitan',
      one: '1 institución más también necesita',
    );
    return '$_temp0 una importación reciente';
  }

  @override
  String get impStaleBannerImport => 'Importar estado de cuenta';

  @override
  String get impStaleBannerDismiss => 'Posponer 7 días';

  @override
  String get impStaleSnoozedSnack =>
      'Recordatorios de importación pospuestos 7 días';

  @override
  String get impStaleThresholdTitle => 'Recordatorio de datos importados';

  @override
  String get impStaleThresholdSubtitle =>
      'Recuérdame cuando los datos importados sean más antiguos que esto';

  @override
  String get impStaleRemindHeader => 'Recuérdame por institución';

  @override
  String get impStaleRemindSubtitle =>
      'Apagado silencia el aviso y la campana para esa institución — sus fechas “al día” siguen visibles';

  @override
  String impContinuityGap(
    Object fromFile,
    Object fromBalance,
    Object fromDate,
    Object toFile,
    Object toBalance,
    Object toDate,
    Object diff,
  ) {
    return 'Posible estado de cuenta faltante: ‘$fromFile’ cierra en $fromBalance ($fromDate), pero ‘$toFile’ abre en $toBalance ($toDate) — una diferencia sin explicar de $diff. Puede faltar un estado de cuenta que cubra el periodo entre ellos.';
  }

  @override
  String get dlgAccountCurrency => 'Moneda';

  @override
  String get dlgAccountInitialBalance => 'Saldo inicial';

  @override
  String get dlgAccountBalanceHelper =>
      'Para tarjetas de crédito o préstamos, ingresa el monto adeudado como número positivo.';

  @override
  String get dlgAccountBalanceInvalid => 'Ingresa un monto numérico';

  @override
  String get dlgAccountCreate => 'Crear cuenta';

  @override
  String get dlgAccountGroupCashBanking => 'Efectivo y banca';

  @override
  String get dlgAccountGroupInvestments => 'Inversiones';

  @override
  String get dlgAccountGroupCrypto => 'Cripto';

  @override
  String get dlgAccountGroupRealAssets => 'Activos reales';

  @override
  String get dlgAccountGroupLiabilities => 'Pasivos';

  @override
  String dlgAccountCreated(Object name) {
    return '¡Cuenta \"$name\" creada!';
  }

  @override
  String dlgAccountCreateError(Object error) {
    return 'No se pudo agregar la cuenta: $error';
  }

  @override
  String dlgCryptoLinkTitle(Object exchange) {
    return 'Vincular $exchange';
  }

  @override
  String dlgCryptoIntro(Object exchange) {
    return 'Genera una clave de API \"de solo lectura\" en los ajustes de $exchange. Solo la usamos para consultar saldos y estimar su valor.';
  }

  @override
  String get dlgCryptoWhereApiKeys => '¿Dónde encuentro mis claves de API? ↗';

  @override
  String dlgCryptoDisplayName(Object example) {
    return 'Nombre visible (p. ej. $example)';
  }

  @override
  String get dlgCryptoApiKey => 'Clave de API';

  @override
  String get dlgCryptoApiSecret => 'Secreto de API';

  @override
  String get dlgCryptoLinkAccount => 'Vincular cuenta';

  @override
  String dlgCryptoApiKeysTitle(Object exchange) {
    return 'Claves de API de $exchange';
  }

  @override
  String dlgCryptoApiKeysFallbackBody(Object exchange) {
    return 'Genera una clave de API de solo lectura en los ajustes de $exchange y pégala aquí. Abrir:';
  }

  @override
  String dlgCryptoLinkSuccess(Object exchange) {
    return '¡$exchange vinculado correctamente!';
  }

  @override
  String dlgCryptoLinkError(Object error) {
    return 'Error al vincular: $error';
  }

  @override
  String get dlgTxTitle => 'Agregar transacción';

  @override
  String get dlgTxEditTitle => 'Editar transacción';

  @override
  String get dlgTxAdded => 'Transacción agregada';

  @override
  String get dlgTxUpdated => 'Transacción actualizada';

  @override
  String get dlgTxNoAccounts =>
      'Necesitas al menos una cuenta antes de poder agregar una transacción.';

  @override
  String get dlgTxAccount => 'Cuenta';

  @override
  String get dlgTxExpense => 'Gasto';

  @override
  String get dlgTxIncome => 'Ingreso';

  @override
  String get dlgTxAmount => 'Monto';

  @override
  String get dlgTxAmountRequired => 'Ingresa un monto';

  @override
  String get dlgTxAmountPositive => 'Ingresa un monto positivo';

  @override
  String get dlgTxDate => 'Fecha';

  @override
  String get dlgTxDescription => 'Descripción';

  @override
  String get dlgTxDescriptionHint => 'p. ej. Café con Sam';

  @override
  String get dlgTxDescriptionRequired => 'La descripción es obligatoria';

  @override
  String get dlgTxCategory => 'Categoría (opcional)';

  @override
  String get dlgTxCategoryHint => 'p. ej. Restaurantes';

  @override
  String get dlgTxNotes => 'Notas (opcional)';

  @override
  String get dlgRecoveryTitle => 'Guarda tus códigos de recuperación';

  @override
  String get dlgRecoveryWarning =>
      'Estos códigos NO se mostrarán de nuevo. Cada uno es de un solo uso; usa uno si pierdes tu contraseña.';

  @override
  String get dlgRecoveryCopied => 'Copiado';

  @override
  String get dlgClabeCopied => 'CLABE copiada al portapapeles';

  @override
  String get dlgCopyClabe => 'Copiar CLABE';

  @override
  String get dlgRecoveryCopyAll => 'Copiar todo';

  @override
  String get dlgRecoverySavedConfirm =>
      'Guardé estos códigos en un lugar seguro';

  @override
  String get dlgRecoveryContinue => 'Continuar';

  @override
  String get lwFxExchangeRate => 'Tipo de cambio';

  @override
  String get lwFxRefreshNow => 'Actualizar tipo de cambio ahora';

  @override
  String lwFxSource(Object source) {
    return 'Fuente: $source';
  }

  @override
  String get lwFxUpdatedUnknown => 'Actualizado: desconocido';

  @override
  String lwFxStalePrefix(Object age) {
    return 'Desactualizado · $age';
  }

  @override
  String get lwFxUpdatedJustNow => 'Actualizado hace un momento';

  @override
  String lwFxUpdatedMinutesAgo(Object minutes) {
    return 'Actualizado hace $minutes min';
  }

  @override
  String lwFxUpdatedHoursAgo(Object hours) {
    return 'Actualizado hace $hours h';
  }

  @override
  String lwFxUpdatedDaysAgo(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Actualizado hace $days días',
      one: 'Actualizado hace $days día',
    );
    return '$_temp0';
  }

  @override
  String get lwSyncInstitutionsHeader => 'INSTITUCIONES';

  @override
  String lwSyncRetryFailed(Object count) {
    return 'Reintentar $count con error';
  }

  @override
  String get lwSyncNoInstitutions => 'Aún no hay instituciones vinculadas';

  @override
  String get lwSyncNoInstitutionsHint =>
      'Usa los botones de abajo para conectar un banco, importar un\nestado de cuenta o agregar una cuenta manual.';

  @override
  String get lwSyncNever => 'Nunca';

  @override
  String get lwSyncUnknownInstitution => 'Desconocida';

  @override
  String get lwSyncFailedUnknownReason =>
      'Falló la sincronización. Motivo desconocido: intenta Reintentar o Reconectar.';

  @override
  String get lwSyncReconnect => 'Reconectar';

  @override
  String get lwSyncRetrySync => 'Reintentar sincronización';

  @override
  String get lwSyncDeleteInstitution => 'Eliminar institución';

  @override
  String lwSyncVia(Object source) {
    return 'Vía $source';
  }

  @override
  String get lwSyncDetailSyncingNow => 'Sincronizando ahora';

  @override
  String get lwSyncDetailSetupRequired =>
      'Requiere configuración antes de sincronizar';

  @override
  String get lwSyncDetailReconnectRequired => 'Requiere reconexión';

  @override
  String get lwSyncDetailWaitingFirstSync =>
      'Esperando la primera sincronización';

  @override
  String get lwSyncDetailManualSource => 'Fuente manual/sin conexión';

  @override
  String get lwSyncStaleSuffix => '(Desactualizado)';

  @override
  String lwSyncBannerOneNeedsAttention(Object name) {
    return '$name requiere atención';
  }

  @override
  String lwSyncBannerManyNeedAttention(Object count) {
    return '$count instituciones requieren atención';
  }

  @override
  String get lwSyncBannerReconnect => 'Reconectar';

  @override
  String lwSyncBannerReconnectName(Object name) {
    return 'Reconectar $name';
  }

  @override
  String lwSyncBannerReconnectCount(Object count) {
    return 'Reconectar $count…';
  }

  @override
  String get lwSyncBannerOpenSettings => 'Abrir configuración';

  @override
  String get lwSyncBannerDismiss => 'Descartar por una semana';

  @override
  String lwSinceNewTransactions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transacciones nuevas',
      one: '$count transacción nueva',
    );
    return '$_temp0';
  }

  @override
  String lwSinceLargestMove(Object account, Object amount) {
    return '$amount en $account';
  }

  @override
  String lwSinceSyncErrors(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count errores de sincronización',
      one: '$count error de sincronización',
    );
    return '$_temp0';
  }

  @override
  String get lwSinceLastVisit => 'Desde tu última visita';

  @override
  String lwSinceDate(Object date) {
    return 'Desde $date';
  }

  @override
  String get lwSinceViewAction => 'Ver';

  @override
  String get lwSinceFixAction => 'Corregir';

  @override
  String get lwSinceDismiss => 'Descartar';

  @override
  String get lwNotifBorrowerFallback => 'Deudor';

  @override
  String get lwNotifInstitutionFallback => 'Institución';

  @override
  String get lwNotifAccountFallback => 'Cuenta';

  @override
  String lwNotifLowBalanceTitle(Object account) {
    return '$account está por agotarse';
  }

  @override
  String lwNotifLowBalanceDetail(Object balance, Object threshold) {
    return 'El saldo $balance está en o por debajo de tu alerta de $threshold.';
  }

  @override
  String lwNotifRepaymentOverdueTitle(Object borrower) {
    return 'Pago de $borrower vencido';
  }

  @override
  String lwNotifRepaymentOverdueDetail(
    Object amount,
    Object daysOverdue,
    Object dueDate,
    Object number,
  ) {
    return 'La cuota #$number de $amount venció el $dueDate (hace $daysOverdue d).';
  }

  @override
  String lwNotifRepaymentDueTitle(Object borrower, Object days) {
    return 'Pago de $borrower vence en $days d';
  }

  @override
  String lwNotifRepaymentDueDetail(
    Object amount,
    Object dueDate,
    Object number,
  ) {
    return 'Cuota #$number de $amount vence el $dueDate.';
  }

  @override
  String lwNotifRepaymentDueTodayTitle(Object borrower) {
    return 'Pago de $borrower vence hoy';
  }

  @override
  String lwNotifRepaymentDueTodayDetail(Object amount, Object number) {
    return 'Cuota #$number de $amount vence hoy.';
  }

  @override
  String lwNotifNeedsReconnectTitle(Object name) {
    return '$name requiere reconexión';
  }

  @override
  String get lwNotifNeedsReconnectDetail =>
      'El token de Plaid expiró: reconecta para reanudar la sincronización.';

  @override
  String lwNotifSyncFailedTitle(Object name) {
    return 'Falló la sincronización de $name';
  }

  @override
  String get lwNotifUnknownSyncError => 'Error de sincronización desconocido';

  @override
  String lwNotifStaleSyncTitle(Object days, Object name) {
    return '$name se sincronizó por última vez hace $days d';
  }

  @override
  String get lwNotifStaleSyncDetail =>
      'Inicia una sincronización para traer transacciones y actualizaciones de saldo.';

  @override
  String lwNotifNetWorthUpTitle(String amount, String pct) {
    return 'El patrimonio subió $amount ($pct)';
  }

  @override
  String lwNotifNetWorthDownTitle(String amount, String pct) {
    return 'El patrimonio bajó $amount ($pct)';
  }

  @override
  String lwNotifNetWorthSinceSyncDetail(String date) {
    return 'Desde tu última sincronización · $date';
  }

  @override
  String lwNotifSinceVisitDetail(String date) {
    return 'Desde tu última visita · $date. Toca para revisar.';
  }

  @override
  String lwNotifSpendingUpTitle(String category, String pct) {
    return '$category subió $pct';
  }

  @override
  String lwNotifSpendingUpDetail(int months, String avg) {
    return 'vs tu promedio de $months meses de $avg';
  }

  @override
  String lwNotifSubPriceUpTitle(String merchant) {
    return 'Subió el precio de $merchant';
  }

  @override
  String lwNotifSubPriceUpDetail(String newAmount, String oldAmount) {
    return 'Ahora $newAmount, antes $oldAmount';
  }

  @override
  String lwNotifAccountArchivedTitle(String institution) {
    return 'Cuenta cerrada: $institution';
  }

  @override
  String lwNotifAccountArchivedDetail(String account, String institution) {
    return '$account ya no está en $institution — se archivó. Toca para restaurar o eliminar.';
  }

  @override
  String get lwNotifTooltipNone => 'Notificaciones';

  @override
  String lwNotifTooltipCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alertas',
      one: '$count alerta',
    );
    return '$_temp0';
  }

  @override
  String get lwNotifAllClear => 'Todo en orden';

  @override
  String get lwNotifNoAlerts => 'No hay alertas por ahora.';

  @override
  String get lwNotifHeader => 'Notificaciones';

  @override
  String get lwNotifMarkAllRead => 'Marcar todo como leído';

  @override
  String get lwPaletteSearchHint =>
      'Busca cuentas, posiciones, transacciones o salta a una pestaña…';

  @override
  String get lwPaletteNoMatches => 'Sin coincidencias.';

  @override
  String get lwPaletteHintNavigate => 'navegar';

  @override
  String get lwPaletteHintSelect => 'seleccionar';

  @override
  String get lwPaletteHintClose => 'cerrar';

  @override
  String get lwTrendsTitle => 'Tendencias de flujo de efectivo';

  @override
  String get lwTrendsIncome => 'Ingresos';

  @override
  String get lwTrendsSpending => 'Gastos';

  @override
  String get lwTrendsTapToView => 'Toca para ver las transacciones';

  @override
  String get lwTrendsInfoTooltip =>
      'Se excluyen las transferencias internas (entre tus cuentas) y los pagos de tarjetas de crédito para que las barras reflejen ingresos y gastos externos reales.';

  @override
  String get lwTrendsSemanticNoData =>
      'Gráfica de tendencias de flujo de efectivo, sin datos';

  @override
  String lwTrendsSemanticSummary(
    int count,
    Object income,
    Object month,
    Object spending,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Tendencias de flujo de efectivo, $count meses. Más reciente $month: ingresos $income, gastos $spending.',
      one:
          'Tendencias de flujo de efectivo, $count mes. Más reciente $month: ingresos $income, gastos $spending.',
    );
    return '$_temp0';
  }

  @override
  String lwTrendsSemanticMonth(Object income, Object month, Object spending) {
    return '$month: ingresos $income, gastos $spending';
  }

  @override
  String get lwAllocTitle => 'Distribución de activos';

  @override
  String lwAllocTotal(Object amount) {
    return 'Total: $amount';
  }

  @override
  String get lwAllocOtherCategory => 'Otros';

  @override
  String lwAllocHoldingsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count posiciones',
      one: '$count posición',
    );
    return '$_temp0';
  }

  @override
  String lwAllocSharesSuffix(Object qty) {
    return '$qty tít.';
  }

  @override
  String lwAllocShowMore(int count) {
    return 'Ver $count más';
  }

  @override
  String get lwAllocShowFewer => 'Ver menos';

  @override
  String get lwAllocDimClass => 'Clase de activo';

  @override
  String get lwAllocDimType => 'Tipo de cuenta';

  @override
  String get lwAllocDimInstitution => 'Institución';

  @override
  String lwAllocConcentration(String holding, String pct) {
    return '$holding es $pct de tu portafolio — una posición concentrada.';
  }

  @override
  String get lwAllocFilteringHint =>
      'Filtrando posiciones a esta categoría: toca de nuevo para quitar el filtro';

  @override
  String lwAllocSemanticLabel(Object category, Object pct, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$category, $pct del portafolio, $count posiciones',
      one: '$category, $pct del portafolio, $count posición',
    );
    return '$_temp0';
  }

  @override
  String get lwRangeOneMonth => '1M';

  @override
  String get lwRangeYearToDate => 'YTD';

  @override
  String get lwRangeOneYear => '1A';

  @override
  String get lwRangeFiveYears => '5A';

  @override
  String get lwRangeAll => 'Todo';

  @override
  String get lwPerfTitle => 'Rendimiento';

  @override
  String get lwPerfValueSubtitle =>
      'Valor de inversión a lo largo del tiempo (incluye aportaciones)';

  @override
  String get lwPerfNotEnough =>
      'Aún no hay suficiente historial para graficar el valor de tu portafolio.';

  @override
  String get lwPerfTwrReturn => 'Rendimiento ponderado por tiempo';

  @override
  String get lwPerfTwrYou => 'Tu portafolio';

  @override
  String get lwPerfTwrSp => 'S&P 500';

  @override
  String get lwPerfTwrMethodNote =>
      'Rendimiento ponderado por tiempo en el periodo seleccionado';

  @override
  String lwPerfTwrCoverage(Object pct) {
    return 'Refleja el $pct de tu portafolio que podemos cotizar a diario';
  }

  @override
  String get ovByCurrency => 'Por moneda';

  @override
  String get lendingGlanceTitle => 'Préstamos';

  @override
  String get lendingGlanceOutstanding => 'Pendiente';

  @override
  String lendingGlanceActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count préstamos activos',
      one: '1 préstamo activo',
    );
    return '$_temp0';
  }

  @override
  String get lendingGlanceNextDue => 'Próximo vencimiento';

  @override
  String lendingGlanceDueIn(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'vence en $days días',
      one: 'vence en 1 día',
    );
    return '$_temp0';
  }

  @override
  String get lendingGlanceDueToday => 'vence hoy';

  @override
  String lendingGlanceOverdueBy(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'vencido hace $days días',
      one: 'vencido hace 1 día',
    );
    return '$_temp0';
  }

  @override
  String get pfGoalPaceAhead => 'Por delante del ritmo';

  @override
  String get pfGoalPaceOnTrack => 'En camino';

  @override
  String get pfGoalPaceBehind => 'Por detrás del ritmo';

  @override
  String get mgmtArchivedTitle => 'Cuentas archivadas automáticamente';

  @override
  String get mgmtArchivedIntro =>
      'Cuentas que la sincronización cerró en el banco. Restaura una para devolverla a tu patrimonio.';

  @override
  String get mgmtArchivedManageAll => 'Administrar todos los elementos ocultos';

  @override
  String get lendingInterest => 'Intereses';

  @override
  String get lendingInterestEarnedLabel => 'Intereses ganados';

  @override
  String get lendingAccruedNotYetPaid => 'Devengado (aún sin pagar)';

  @override
  String get lendingAgingTitle => 'Vencimientos y atrasos';

  @override
  String get lendingAgingOverdue30 => '30+ días de atraso';

  @override
  String get lendingAgingOverdue7 => '7-29 días de atraso';

  @override
  String get lendingAgingOverdue1 => '1-6 días de atraso';

  @override
  String get lendingAgingDueToday => 'Vence hoy';

  @override
  String get lendingAgingDueSoon => 'Vence pronto';

  @override
  String lendingAgingDaysOverdue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count días de atraso',
      one: '1 día de atraso',
    );
    return '$_temp0';
  }

  @override
  String lendingAgingDaysUntil(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'en $count días',
      one: 'en 1 día',
    );
    return '$_temp0';
  }

  @override
  String get pfMoversTodayTitle => 'Mayores movimientos de hoy (por \$)';

  @override
  String get pfBestWorstAllTime => 'Mejores y peores (histórico)';

  @override
  String get pfTopGainersByValue => 'Mayores ganancias';

  @override
  String get pfTopLosersByValue => 'Mayores pérdidas';

  @override
  String get pfLotCurrentValue => 'Valor actual';

  @override
  String get pfLotTerm => 'Plazo';

  @override
  String get pfLotLongTerm => 'Largo plazo';

  @override
  String get pfLotShortTerm => 'Corto plazo';

  @override
  String get pfFlatCostBasis => 'Costo base';

  @override
  String get pfLotsUnavailable => 'Sin detalle de costo base disponible';

  @override
  String get pfLotsUnavailableTooltip =>
      'Esta institución no reportó fechas de adquisición, por lo que no hay desglose por lote.';

  @override
  String get pfViewCostBasis => 'Ver costo base';

  @override
  String get taxHarvestMarginalRate =>
      'Tasa marginal usada para las estimaciones de cosecha';

  @override
  String get taxHarvestMarginalOrdinary => 'Ordinaria (corto plazo)';

  @override
  String get taxHarvestMarginalLtcg => 'Ganancias de capital (largo plazo)';

  @override
  String get projShowNominal => 'Mostrar montos nominales';

  @override
  String get projNominalNote => 'Dólares futuros (nominales)';

  @override
  String projFisherHelp(String nominal, String inflation, String real) {
    return '$nominal% nominal − $inflation% inflación ≈ $real% real (relación de Fisher)';
  }

  @override
  String get lwSyncBadgeSuccess => 'Sincronizadas';

  @override
  String get lwSyncBadgeSyncing => 'Sincronizando';

  @override
  String get lwSyncBadgeError => 'Errores';

  @override
  String get lwSyncBadgeReconnect => 'Reconectar';

  @override
  String get lwSyncBadgeStale => 'Desactualizadas';

  @override
  String get lwSyncFilterProblems => 'Requiere atención';

  @override
  String get lwSyncNoProblems => 'Todo está al día';

  @override
  String pfReturnCoverage(String covered, String total) {
    return 'sobre $covered de $total con costo base conocido';
  }

  @override
  String get taxFbarNoData =>
      'No se encontró historial de saldos de cuentas en el extranjero para este año.';

  @override
  String projNominalHorizonCaption(int years) {
    return 'en dólares de $years años';
  }

  @override
  String get statInvestmentsCashSleeveNote =>
      'Incluye el efectivo no invertido dentro de las cuentas de corretaje, por lo que difiere del total del Portafolio (suma de las posiciones).';

  @override
  String get dashFxStaleLabel => 'aprox.';

  @override
  String get dashFxStaleTooltip =>
      'Aproximado — el tipo de cambio está desactualizado (ausente o con más de 7 días), por lo que esta conversión puede no ser exacta.';

  @override
  String get lwFxEnterManually => 'Ingresar tipo de cambio manualmente';

  @override
  String get lwFxManualDialogTitle => 'Ingresar tipo de cambio';

  @override
  String lwFxManualDialogHint(Object base, Object target) {
    return 'Define un tipo de cambio manual $base/$target. Reemplaza el tipo automático hasta la próxima actualización.';
  }

  @override
  String get lwFxManualInvalid =>
      'Ingresa un tipo de cambio válido mayor que cero';

  @override
  String get lwFxManualSaved => 'Tipo de cambio manual guardado';

  @override
  String lwFxManualFailed(Object error) {
    return 'No se pudo guardar el tipo de cambio: $error';
  }

  @override
  String get taxHeadroomTitle => 'Margen disponible';

  @override
  String get taxHeadroomSubtitle =>
      'Espacio antes del siguiente escalón fiscal de EE. UU.';

  @override
  String taxHeadroomOrdinaryRoom(Object amount, Object rate) {
    return 'Espacio en el tramo actual: $amount antes del $rate%';
  }

  @override
  String taxHeadroomOrdinaryRoomTop(Object amount) {
    return 'Espacio en el tramo actual: $amount';
  }

  @override
  String taxHeadroomLtcg0Room(Object amount) {
    return 'Margen de plusvalías al 0%: $amount libre de impuesto';
  }

  @override
  String taxHeadroomLtcg15Room(Object amount, Object rate) {
    return 'Margen de plusvalías al 15%: $amount antes del $rate%';
  }

  @override
  String get txFilteredNet => 'Neto';

  @override
  String txFilteredOutflow(Object amount) {
    return 'Salida $amount';
  }

  @override
  String txFilteredInflow(Object amount) {
    return 'Entrada $amount';
  }

  @override
  String statDrilldownApprox(Object amount) {
    return '≈ $amount';
  }

  @override
  String get cfBudgetsPacingToExceed => 'En camino a excederse';

  @override
  String cfBudgetsPacingAlert(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count categorías van en camino a exceder su presupuesto',
      one: '1 categoría va en camino a exceder su presupuesto',
    );
    return '$_temp0';
  }

  @override
  String pfGoalOnPaceFor(Object rate, Object when) {
    return 'en camino para ~$when a +$rate/mes';
  }

  @override
  String pfGoalNeedPerMonth(Object amount) {
    return 'necesitas $amount/mes para alcanzar el año meta';
  }

  @override
  String get lendingInterestIncomeTitle => 'Ingresos por intereses';

  @override
  String get lendingInterestIncomeLoadError =>
      'No se pudieron cargar los ingresos por intereses. Inténtalo de nuevo.';

  @override
  String get lendingInterestIncomeRetry => 'Reintentar';

  @override
  String get lendingInterestIncomeAllTime => 'Todo el tiempo';

  @override
  String get lendingInterestIncomeEmpty =>
      'Aún no se han recibido intereses en este periodo.';

  @override
  String get lendingInterestIncomeTotalsByCurrency => 'Totales por moneda';

  @override
  String get lendingInterestIncomeInterestReceived =>
      'Intereses cobrados a la fecha';

  @override
  String get lendingInterestIncomePrincipalReceived => 'Capital recibido';

  @override
  String get lendingInterestIncomePaymentsCount => 'Pagos';

  @override
  String get lendingInterestIncomeByMonth => 'Intereses por mes';

  @override
  String get lendingInterestIncomeByLoan => 'Por préstamo';

  @override
  String get lendingInterestIncomeBorrower => 'Prestatario';

  @override
  String get lendingInterestIncomeBelowMarketTitle =>
      'Préstamos por debajo del mercado (§7872)';

  @override
  String get lendingInterestIncomeBelowMarketBody =>
      'Estos préstamos activos con tasa del 0% superan el umbral de \$10,000 para préstamos-regalo, por lo que el IRS podría imputar intereses según la §7872. Solo informativo: confírmalo con un contador.';

  @override
  String cfSavingsRate(Object rate) {
    return '$rate ahorrado';
  }

  @override
  String get cfPtsAbbrev => 'pts';

  @override
  String taxHarvestFooterTotal(Object count) {
    return 'Pérdida cosechable total ($count lotes)';
  }

  @override
  String taxHarvestFooterSavings(Object amount) {
    return 'Ahorro total est. $amount';
  }

  @override
  String taxHarvestFooterFlow(
    Object carryforward,
    Object gains,
    Object ordinary,
  ) {
    return '$gains de ganancias gravables restantes, $ordinary contra ingresos, $carryforward trasladado a futuro';
  }

  @override
  String taxHarvestFooterCarryforward(Object amount) {
    return '$amount de pérdida se traslada al año siguiente';
  }

  @override
  String get lwPerfBenchSp500 => 'S&P 500';

  @override
  String get lwPerfBenchNdx => 'Nasdaq-100';

  @override
  String get lwPerfBenchAcwi => 'Mundo (ACWI)';

  @override
  String get lwPerfBenchAgg => 'Bonos EE.UU.';

  @override
  String get lwPerfBenchMxx => 'IPC México';

  @override
  String get lwPerfBenchPickerTooltip => 'Índice de referencia';

  @override
  String get lendingDueOverdue => 'Vencido';

  @override
  String lendingDueOn(Object date) {
    return 'Vence $date';
  }

  @override
  String get lendingDuePaidAhead => 'Pago adelantado';

  @override
  String get lendingInterestOwedSoFar => 'Interés adeudado hasta ahora';

  @override
  String get dashLenderNameTitle => 'Tu nombre';

  @override
  String get dashLenderNameSubtitle =>
      'Aparece como prestamista en los contratos de préstamo. Déjalo en blanco para usar tu nombre de usuario.';

  @override
  String get dashLenderNameHint => 'p. ej. Nick Van der Auwermeulen';

  @override
  String get dashLenderNameSaved => 'Nombre guardado';

  @override
  String get dashLenderNameSaveFailed => 'No se pudo guardar tu nombre';

  @override
  String get dashSave => 'Guardar';

  @override
  String get dashDataExportTitle => 'Exportar datos';

  @override
  String get dashDataExportSubtitle =>
      'Descarga tus transacciones y reportes de impuestos. Los archivos se descargan directamente en tu navegador.';

  @override
  String get dashExportTransactionsCsv => 'Todas las transacciones (CSV)';

  @override
  String get dashExportTaxCsv => 'Reporte de impuestos (CSV)';

  @override
  String get dashExportTaxPdf => 'Reporte de impuestos (PDF)';

  @override
  String get dashImportedBatchesTitle => 'Lotes importados';

  @override
  String get dashImportedBatchesSubtitle =>
      'Revisa o deshaz importaciones de estados de cuenta anteriores';

  @override
  String get divCardTitle => 'Ingresos por dividendos';

  @override
  String get divProjectedAnnual => 'Anual proyectado';

  @override
  String get divBlendedYield => 'Rendimiento combinado';

  @override
  String get divTopPayers => 'Principales pagadores';

  @override
  String get divUpcomingExDates => 'Próximas fechas ex-dividendo';

  @override
  String divPaymentsPerYear(Object count) {
    return '$count×/año';
  }

  @override
  String get divFxStaleHint =>
      'Parte de los ingresos se convirtió con un tipo de cambio desactualizado; las cifras son aproximadas.';

  @override
  String get lendCustomStyleLabel => 'Calendario personalizado';

  @override
  String get lendCustomStyleDesc =>
      'Tú defines cada pago a mano: montos y fechas irregulares que suman lo prestado.';

  @override
  String get lendCustomPasteTitle => 'Pegar desde una hoja de cálculo';

  @override
  String get lendCustomPasteHint =>
      'Pega dos columnas de Google Sheets / Excel: fecha y luego monto, un pago por línea.';

  @override
  String get lendCustomPasteButton => 'Procesar filas pegadas';

  @override
  String lendCustomPastedN(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'Se cargaron $count pago$_temp0 desde lo pegado.';
  }

  @override
  String get lendCustomPasteEmpty =>
      'Nada que procesar: primero pega filas de fecha y monto.';

  @override
  String get lendCustomRowsTitle => 'Pagos';

  @override
  String get lendCustomAddRow => 'Agregar pago';

  @override
  String get lendCustomRemoveRow => 'Quitar pago';

  @override
  String get lendCustomRowDate => 'Fecha';

  @override
  String get lendCustomRowAmount => 'Monto';

  @override
  String get lendCustomNoRows =>
      'Aún no hay pagos: pega desde una hoja de cálculo o agrégalos abajo.';

  @override
  String get lendCustomGeneratorTitle => 'Llenado rápido';

  @override
  String get lendCustomGenFirstN => 'Primeros pagos';

  @override
  String get lendCustomGenFirstAmount => 'Primer monto';

  @override
  String get lendCustomGenThenAmount => 'Luego cada uno';

  @override
  String get lendCustomGenDayOfMonth => 'Día del mes';

  @override
  String get lendCustomGenStart => 'Inicio';

  @override
  String get lendCustomGenEnd => 'Fin';

  @override
  String get lendCustomGenApply => 'Llenar pagos';

  @override
  String lendCustomPreviewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pagos',
      one: '1 pago',
    );
    return '$_temp0';
  }

  @override
  String get lendCustomPreviewSum => 'Suma de los pagos';

  @override
  String get lendCustomClosesToZero =>
      'Cierra en 0: los pagos suman lo prestado.';

  @override
  String lendCustomDoesNotAddUp(String sum, String principal) {
    return 'Los pagos suman $sum, pero lo prestado es $principal.';
  }

  @override
  String get lendCustomNeedRows => 'Agrega al menos un pago antes de guardar.';

  @override
  String lendCustomScheduleFailed(String error) {
    return 'No se pudo guardar el calendario: $error';
  }

  @override
  String get lendDisbursementConflict =>
      'Esa transacción ya financia otro préstamo: no se creó el préstamo.';

  @override
  String get lendCopyForSheets => 'Copiar para Google Sheets';

  @override
  String get lendCopiedForSheets => 'Copiado: pega en la hoja con Ctrl/Cmd+V.';

  @override
  String lendSchedulePaidProgress(int paid, int total) {
    return 'Pagados $paid de $total pagos';
  }

  @override
  String lendScheduleRemaining(String amount) {
    return '$amount restante';
  }

  @override
  String get lendScheduleColDue => 'Vence';

  @override
  String get lendScheduleColInterest => 'Interés';

  @override
  String get lendScheduleColPayment => 'Pago';

  @override
  String get lendScheduleColBalance => 'Saldo de capital';

  @override
  String get lendSchedulePrincipalBalanceNote =>
      'El saldo de capital es lo que falta del monto prestado; no incluye intereses.';

  @override
  String lendScheduleRowMeta(String balance, String interest) {
    return 'Saldo $balance · int $interest';
  }

  @override
  String get lendScheduleColStatus => 'Estado';

  @override
  String get lendScheduleNextDue => 'Próximo';

  @override
  String get lendScheduleTotals => 'Total';

  @override
  String get txCreateLoanFromTx => 'Crear préstamo desde esta transacción';

  @override
  String get lendDisbursementNotLinkedOptional =>
      'sin desembolso vinculado (opcional)';

  @override
  String get lendLoadError =>
      'No se pudieron cargar los préstamos. Desliza para reintentar.';

  @override
  String get lendRetry => 'Reintentar';

  @override
  String get lendExportInterestTooltip => 'Exportar ingresos por intereses';

  @override
  String get lendExportPaymentsCsv => 'Pagos de intereses (CSV)';

  @override
  String get lendExportYearEndCsv => 'Resumen anual por prestatario (CSV)';

  @override
  String lendTotalsConvertedNote(String currency) {
    return 'Totales convertidos a $currency al tipo de cambio actual';
  }

  @override
  String get lendUnknownBorrower => 'Desconocido';

  @override
  String get lendStatusActive => 'Activo';

  @override
  String get lendStatusPaidOff => 'Pagado';

  @override
  String get lendStatusWrittenOff => 'Cancelado en libros';

  @override
  String get lendStatusDefaulted => 'En mora';

  @override
  String get lendStatusCancelled => 'Cancelado';

  @override
  String lendLentMeta(String amount, String date) {
    return 'Prestado $amount · $date';
  }

  @override
  String lendLentOutstandingMeta(String principal, String outstanding) {
    return 'Prestado $principal · pendiente $outstanding';
  }

  @override
  String get lendRatePeriodYear => 'Año';

  @override
  String get lendRatePeriodMonth => 'Mes';

  @override
  String get lendRateHintExample => 'p. ej. 5';

  @override
  String get lendRatePerMonthSuffix => '% / mes';

  @override
  String get lendRatePerYearSuffix => '% / año';

  @override
  String get lendFreqLumpSum => 'Pago único';

  @override
  String get lendInterestTypeNone => 'Sin interés';

  @override
  String get lendInterestTypeSimple => 'Interés simple';

  @override
  String get lendInterestTypeAmortized => 'Amortizado';

  @override
  String get lendInterestTypeInterestOnly => 'Solo interés';

  @override
  String get lendInterestTypeCompound => 'Compuesto';

  @override
  String get lendAddLoanSubtitle =>
      'Registra el dinero que prestaste y da seguimiento al pago';

  @override
  String get lendEditLoanTitle => 'Editar préstamo';

  @override
  String get lendEditLoanSubtitle =>
      'Corrige el prestatario, el monto o las condiciones de interés';

  @override
  String get lendFieldBorrowerName => 'Nombre del prestatario';

  @override
  String get lendFieldAmountLent => 'Monto prestado';

  @override
  String get lendFieldCurrency => 'Moneda';

  @override
  String get lendFieldLentOn => 'Prestado el';

  @override
  String get lendFieldInterestRate => 'Tasa de interés';

  @override
  String get lendFieldNotes => 'Notas';

  @override
  String get lendFieldNotesHint => 'p. ej., para el enganche del auto';

  @override
  String get lendFieldPayBackByHint => '¿Para cuándo lo pagarán?';

  @override
  String get lendFieldTermMonths => 'Plazo (meses)';

  @override
  String get lendFieldMostTheyCanPay => 'Máximo que pueden pagar';

  @override
  String get lendFieldRateIsPer => 'La tasa es por';

  @override
  String get lendFieldPaymentFrequency => 'Frecuencia de pago';

  @override
  String get lendFieldPayBackBy => 'Pagar antes del';

  @override
  String get lendFieldInterestType => 'Tipo de interés';

  @override
  String get lendFieldAmountReceived => 'Monto recibido';

  @override
  String get lendFieldReceivedOn => 'Recibido el';

  @override
  String get lendSegSetTheTerm => 'Definir el plazo';

  @override
  String get lendSegSetThePayment => 'Definir el pago';

  @override
  String get lendSegBankTransaction => 'Transacción bancaria';

  @override
  String get lendSegCash => 'Registrar manualmente';

  @override
  String get lendAdvancedOptions => 'Opciones avanzadas';

  @override
  String get lendPreviewTitle => 'Vista previa del préstamo';

  @override
  String get lendPreviewEstimate => 'estimado';

  @override
  String get lendPreviewEnterAmount =>
      'Ingresa un monto para ver la proyección';

  @override
  String get lendPreviewTotalToRepay => 'Total a pagar';

  @override
  String get lendPreviewProjectedInterest => 'Interés proyectado';

  @override
  String get lendPreviewNoInterest => 'Este préstamo no genera interés';

  @override
  String get lendPreviewOpenEnded =>
      'Abierto — paga cuando quieras, sin calendario fijo';

  @override
  String get lendPreviewMinimumPayment => 'Pago mínimo';

  @override
  String get lendPreviewPaidOffIn => 'Liquidado en';

  @override
  String lendPreviewPaidOffValue(int count, String term) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pagos',
      one: '1 pago',
    );
    return '$_temp0  ·  $term';
  }

  @override
  String lendTermMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count meses',
      one: '1 mes',
    );
    return '$_temp0';
  }

  @override
  String lendTermYearsAbbrev(String years) {
    return '~$years a';
  }

  @override
  String get lendSaveChanges => 'Guardar cambios';

  @override
  String get lendDisbursementLinked => 'Vinculado a una transacción bancaria';

  @override
  String get lendWhichTxFunded => '¿Qué transacción financió este préstamo?';

  @override
  String get lendLinkATransaction => 'Vincular una transacción';

  @override
  String get lendNoneRecordedYet => 'Aún no hay registros.';

  @override
  String get lendSuggestedRepayments => 'Pagos sugeridos';

  @override
  String get lendRecordAPayment => 'Registrar un pago';

  @override
  String get lendConfirm => 'Confirmar';

  @override
  String get lendLinkedPaymentUntitled => 'Pago vinculado';

  @override
  String get lendOffBankBadge => 'Registrado manualmente';

  @override
  String get lendMatchStrong => 'Coincidencia fuerte';

  @override
  String get lendMatchLikely => 'Coincidencia probable';

  @override
  String get lendMatchPossible => 'Posible coincidencia';

  @override
  String get lendMatchNameHit => 'Coincide el nombre';

  @override
  String get lendExportPrintablePlan => 'Plan imprimible (PDF)';

  @override
  String get lendExportDownloadCsv => 'Descargar CSV (Google Sheets / Excel)';

  @override
  String get lendActionEdit => 'Editar';

  @override
  String get lendActionAgreement => 'Contrato';

  @override
  String get lendActionMore => 'Más';

  @override
  String get lendAgreementEnglish => 'Inglés';

  @override
  String get lendAgreementSpanish => 'Español';

  @override
  String get lendActionPayOffInFull => 'Liquidar por completo';

  @override
  String get lendActionMarkDefaulted => 'Marcar en mora';

  @override
  String get lendActionWriteOff => 'Dar de baja';

  @override
  String get lendActionReactivate => 'Reactivar';

  @override
  String get lendPayoffConfirmTitle => '¿Liquidar por completo?';

  @override
  String get lendPayoffConfirmButton => 'Liquidar';

  @override
  String get lendDeleteLoan => 'Eliminar préstamo';

  @override
  String get lendDeleteLoanTitle => '¿Eliminar préstamo?';

  @override
  String get lendTooltipClearDate => 'Borrar fecha';

  @override
  String get lendTooltipUnlink => 'Desvincular';

  @override
  String get lendTooltipExportPaymentPlan => 'Exportar plan de pagos';

  @override
  String get lendToastEnterBorrowerName => 'Ingresa el nombre del prestatario';

  @override
  String get lendToastEnterValidAmount => 'Ingresa un monto válido';

  @override
  String lendToastCheckField(String field) {
    return 'Corrige “$field” para continuar';
  }

  @override
  String get lendErrEnterPayment => 'Ingresa un monto de pago mayor que 0';

  @override
  String get lendErrPaymentTooSmall =>
      'Muy pequeño: este pago nunca liquidaría el préstamo';

  @override
  String get lendToastFailedToAddLoan => 'No se pudo agregar el préstamo';

  @override
  String get lendToastCouldntSaveChanges =>
      'No se pudieron guardar los cambios';

  @override
  String get lendToastScheduleGenerated => 'Calendario generado';

  @override
  String get lendToastLoanUpdated => 'Préstamo actualizado';

  @override
  String get lendToastCouldntUpdateStatus => 'No se pudo actualizar el estado';

  @override
  String get lendToastLoanPaidOff => 'Préstamo liquidado';

  @override
  String get lendToastCouldntLinkTx => 'No se pudo vincular esa transacción';

  @override
  String get lendToastCouldntRecordRepayment => 'No se pudo registrar ese pago';

  @override
  String get lendToastCouldntUnlink => 'No se pudo desvincular';

  @override
  String get lendToastCouldntDeleteLoan => 'No se pudo eliminar el préstamo';

  @override
  String get lendToastRecordCashPayment => 'Registrar pago en efectivo';

  @override
  String get lendToastCouldntRecordCashPayment =>
      'No se pudo registrar el pago en efectivo';

  @override
  String get lendSectionBorrowerAmount => 'Prestatario y monto';

  @override
  String get lendSectionHowLoanWorks => 'Cómo funciona el préstamo';

  @override
  String get lendSectionExpectedRepayment => 'Pago esperado';

  @override
  String get lendSectionNotes => 'Notas';

  @override
  String get lendSectionInterestTerms => 'Condiciones de interés';

  @override
  String get lendSectionDisbursement => 'Desembolso';

  @override
  String get lendSectionRepayments => 'Pagos';

  @override
  String get lendSectionPaymentSchedule => 'Calendario de pagos';

  @override
  String get lendStyleNoInterestDesc =>
      'Pagan exactamente lo que pidieron prestado.';

  @override
  String get lendStyleStandardLabel => 'Pagos regulares con tasa';

  @override
  String get lendStyleStandardDesc =>
      'Pagos iguales a lo largo del tiempo con una tasa de interés — como un préstamo bancario.';

  @override
  String get lendStyleFlatLabel => 'Interés fijo';

  @override
  String get lendStyleFlatDesc =>
      'Un monto de interés fijo, repartido por igual entre los pagos. Ingrésalo como monto total o como tasa.';

  @override
  String get lendFlatModeAmount => 'Monto fijo';

  @override
  String get lendFlatModeRate => 'Tasa';

  @override
  String get lendMoreLoanTypes => 'Más tipos de préstamo';

  @override
  String get lendFieldAgreedInterest => 'Interés acordado (total)';

  @override
  String get lendFieldPaymentAmount => 'Monto del pago';

  @override
  String get lendStyleInterestOnlyLabel =>
      'Solo interés ahora, monto total al final';

  @override
  String get lendStyleInterestOnlyDesc =>
      'Pagan solo el interés cada período y luego el monto completo al final.';

  @override
  String get lendStylePayAtEndLabel => 'Un solo pago al final';

  @override
  String get lendStylePayAtEndDesc =>
      'No se debe nada hasta el final; el interés se acumula hasta entonces.';

  @override
  String get lendPreviewSinglePayment => 'Pago único';

  @override
  String get lendPreviewPayment => 'Pago';

  @override
  String lendPreviewPerPaymentInterest(
    String amount,
    String cadence,
    int count,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pagos',
      one: '1 pago',
    );
    return '$amount$cadence de interés  ·  $_temp0';
  }

  @override
  String lendPreviewPerPaymentCount(String amount, String cadence, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pagos',
      one: '1 pago',
    );
    return '$amount$cadence  ·  $_temp0';
  }

  @override
  String get lendPreviewPrincipalAtMaturity => 'Capital al vencimiento';

  @override
  String lendPreviewDueWithFinalPayment(String amount) {
    return '$amount  ·  con el pago final';
  }

  @override
  String get lendPreviewEnterPaymentSolve =>
      'Ingresa un pago para ver cuánto tarda';

  @override
  String get lendToastEnterPaymentCompute =>
      'Ingresa un pago para calcular el plazo';

  @override
  String lendEditRatePerPeriod(String period) {
    String _temp0 = intl.Intl.selectLogic(period, {
      'monthly': 'Tasa % por mes',
      'other': 'Tasa % por año',
    });
    return '$_temp0';
  }

  @override
  String lendTermsSummaryTermMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'plazo de $count meses',
      one: 'plazo de 1 mes',
    );
    return '$_temp0';
  }

  @override
  String get lendTermsSummaryMonthlyPayments => 'pagos mensuales';

  @override
  String get lendTermsSummaryWeeklyPayments => 'pagos semanales';

  @override
  String get lendTermsSummaryLumpSumPayment => 'pago único';

  @override
  String lendTermsSummaryFixed(String parts) {
    return 'El plazo y el calendario ($parts) son fijos — elimina y vuelve a agregar para cambiarlos.';
  }

  @override
  String get lendNoMatchingOutflow =>
      'No se encontró ninguna salida cercana a la fecha del préstamo — elige una manualmente abajo.';

  @override
  String get lendScheduleGenerate => 'Generar';

  @override
  String get lendScheduleRegenerate => 'Regenerar';

  @override
  String get lendScheduleEmptyHasTerms =>
      'Aún no hay calendario. Genera uno para ver el plan de amortización (capital + interés por cuota).';

  @override
  String get lendScheduleEmptyNoTerms =>
      'Este préstamo no tiene plazo ni frecuencia de pago, así que no hay calendario fijo — registra los pagos a medida que lleguen.';

  @override
  String lendPayBackByWhen(String date, String when) {
    return 'Pagar antes del $date · $when';
  }

  @override
  String get lendToastUnreconcileFirst =>
      'Primero anula la conciliación de los pagos para regenerar';

  @override
  String get lendToastCouldntGenerateSchedule =>
      'No se pudo generar el calendario';

  @override
  String get lendPayoffConfirmBody =>
      'Marca el préstamo como liquidado y borra cualquier cuota programada pendiente. Esto no crea un pago — vincula la transacción final real desde la lista de Pagos para que los ingresos por intereses sigan siendo exactos.';

  @override
  String get lendToastLoanNoLongerActive => 'El préstamo ya no está activo';

  @override
  String get lendToastCouldntPayOff => 'No se pudo liquidar el préstamo';

  @override
  String get lendDeleteLoanBody =>
      'Esto elimina el préstamo y sus registros de pago. Las transacciones bancarias en sí no se eliminan.';

  @override
  String get lendSheetRecordPayment => 'Registrar un pago';

  @override
  String get lendSheetLinkDisbursement => 'Vincular el desembolso';

  @override
  String get lendSearchInflows => 'Buscar entradas (dinero recibido)';

  @override
  String get lendSearchOutflows => 'Buscar salidas (dinero enviado)';

  @override
  String get lendNoIncomingTx =>
      'No se encontraron transacciones entrantes. Prueba la pestaña de Efectivo para registrar un pago fuera del banco.';

  @override
  String get lendNoOutgoingTx => 'No se encontraron transacciones salientes.';

  @override
  String get lendCashFormHint =>
      'Registra un pago recibido en efectivo — o en una cuenta cuyas transacciones aún no se han importado (p. ej. una cuenta con estado de cuenta mensual). Reduce el saldo pendiente ahora; cuando aparezca la transacción bancaria, vincúlala desde el botón de enlace del pago.';

  @override
  String get lendToastTxAlreadyLinked => 'Esa transacción ya está vinculada';

  @override
  String get lendToastCouldntRecordThat => 'No se pudo registrar eso';

  @override
  String get lendLinkBankTx => 'Vincular transacción bancaria';

  @override
  String get lendLinkBankTxTitle => 'Vincular una transacción bancaria';

  @override
  String get lendLinkBankTxNone =>
      'Aún no se encontraron transacciones bancarias coincidentes — primero sube tu estado de cuenta.';

  @override
  String get lendLinkBankTxError =>
      'No se pudo vincular esa transacción bancaria';

  @override
  String pfFilterNoMatches(Object filter) {
    return 'Ninguna posición coincide con \"$filter\"';
  }

  @override
  String get pfFilterClear => 'Quitar filtro';

  @override
  String pfFilterShownOfTotal(int shown, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$total posiciones',
      one: '1 posición',
    );
    return '$shown de $_temp0';
  }

  @override
  String get pfFilterAssetEquity => 'Acciones y fondos';

  @override
  String get pfFilterAssetBonds => 'Bonos';

  @override
  String get pfFilterAssetCash => 'Efectivo';

  @override
  String get pfFilterAssetCrypto => 'Cripto';

  @override
  String get pfFilterAssetRealEstate => 'Bienes raíces';

  @override
  String get pfFilterAssetCommodities => 'Materias primas';

  @override
  String get pfFilterAssetOther => 'Otros';

  @override
  String pfDivShowAllPayers(int count) {
    return 'Ver todos ($count)';
  }

  @override
  String get pfDivShowFewerPayers => 'Ver menos';

  @override
  String get pfDivLoadError =>
      'No se pudieron cargar los ingresos por dividendos';

  @override
  String get pfDivRetry => 'Reintentar';

  @override
  String get pfDivDetailFreqMonthly => 'Mensual';

  @override
  String get pfDivDetailFreqQuarterly => 'Trimestral';

  @override
  String get pfDivDetailFreqSemiAnnual => 'Semestral';

  @override
  String get pfDivDetailFreqAnnual => 'Anual';

  @override
  String get pfDivDetailSubtitle =>
      'Estimado a partir del historial de pagos reciente; las fechas y montos reales pueden variar.';

  @override
  String get pfDivDetailShares => 'Acciones';

  @override
  String get pfDivDetailMarketValue => 'Valor de mercado';

  @override
  String get pfDivDetailRatePerShare => 'Tasa / acción (anual)';

  @override
  String get pfDivDetailPerPayment => 'Por pago';

  @override
  String get pfDivDetailAnnualIncome => 'Ingreso anual';

  @override
  String get pfDivDetailYield => 'Rendimiento';

  @override
  String get pfDivDetailYieldOnCost => 'Rendimiento sobre costo';

  @override
  String get pfDivDetailLastExDate => 'Última fecha ex-dividendo';

  @override
  String get pfDivDetailNextExDate => 'Próxima fecha ex-dividendo (est.)';

  @override
  String get pfDivDetailSchedule => 'Próximos 12 meses';

  @override
  String get pfDivDetailHistory => 'Historial de pagos';

  @override
  String get pfDivDetailPerShare => 'por acción';

  @override
  String get pfDivDetailAccounts => 'En cuentas';

  @override
  String get pfDivDetailTaxAdvantaged => 'Con ventaja fiscal';

  @override
  String get pfDivDetailNoHistory =>
      'Este símbolo aún no tiene historial de dividendos.';

  @override
  String get pfDivDetailLoadError =>
      'No se pudo cargar el detalle de dividendos';

  @override
  String rgShowAll(int count) {
    return 'Mostrar todas ($count)';
  }

  @override
  String get rgShowFewer => 'Mostrar menos';

  @override
  String rgYearTile(String year) {
    return '$year';
  }

  @override
  String get rgEmpty => 'Aún no hay ganancias realizadas';

  @override
  String get rgLoadError => 'No se pudieron cargar las ganancias realizadas';

  @override
  String get rgRetry => 'Reintentar';

  @override
  String acctDeleteHoldingTitle(String symbol) {
    return '¿Eliminar $symbol?';
  }

  @override
  String get acctDeleteHoldingBody =>
      'Esto elimina permanentemente la posición, todos sus lotes de compra y sus registros fiscales de ganancias realizadas. No se puede deshacer.';

  @override
  String get acctDeleteHoldingConfirm => 'Eliminar permanentemente';

  @override
  String get allocTapToFilterHint =>
      'Toca una banda para filtrar la tabla de posiciones';

  @override
  String allocActiveFilter(String label) {
    return 'Filtrado: $label';
  }

  @override
  String get allocClearFilter => 'Quitar filtro';

  @override
  String allocBandSemanticsHoldings(String label, String value, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count posiciones',
      one: '$count posición',
    );
    return '$label, $value, $_temp0';
  }

  @override
  String allocBandSemanticsAccounts(String label, String value, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cuentas',
      one: '$count cuenta',
    );
    return '$label, $value, $_temp0';
  }

  @override
  String allocBandSemanticsNoCount(String label, String value) {
    return '$label, $value';
  }

  @override
  String get allocBandFiltersTable => 'filtra la tabla de posiciones';

  @override
  String get insLoadError => 'No se pudo cargar el detalle del instrumento';

  @override
  String insAsOf(String date) {
    return 'al $date';
  }

  @override
  String get insRange1m => '1M';

  @override
  String get insRange3m => '3M';

  @override
  String get insRange1y => '1A';

  @override
  String get insRangeMax => 'Máx';

  @override
  String get insNoPriceHistory => 'Sin historial de precios para esta posición';

  @override
  String get insStatMarketValue => 'Valor de mercado';

  @override
  String get insStatQuantity => 'Cantidad';

  @override
  String get insStatCostBasis => 'Costo base';

  @override
  String get insStatGain => 'Ganancia';

  @override
  String get insStatWeight => 'Peso en el portafolio';

  @override
  String get insStatAssetClass => 'Clase de activo';

  @override
  String get insLotsSection => 'Lotes de compra';

  @override
  String insLotQtyAtPrice(String qty, String price) {
    return '$qty acciones a $price';
  }

  @override
  String get insLotsTotal => 'Total';

  @override
  String get insDividendsLink => 'Detalle de dividendos';

  @override
  String get insDivPaymentsSection => 'Pagos recibidos';

  @override
  String insDivShowAllPayments(int count) {
    return 'Mostrar todos ($count)';
  }

  @override
  String get insDivShowFewerPayments => 'Mostrar menos';

  @override
  String get rgxAllYears => 'Todos';

  @override
  String rgxNoSalesInYear(String year) {
    return 'Sin ventas en $year';
  }

  @override
  String get rgxTaxAdvBadge => 'Vent. fiscal';

  @override
  String get rgxTaxAdvTooltip => 'Roth/IRA/401k/HSA — no gravable';

  @override
  String get rgxTaxableCaptionPrefix => 'Gravable';

  @override
  String rgxTaxableCaptionSuffix(String total) {
    return 'de $total — el resto está en cuentas con ventajas fiscales';
  }

  @override
  String get rgxExportCsvTooltip => 'Exportar CSV';

  @override
  String get rgxPerfPortfolioValue => 'Valor del portafolio';

  @override
  String pfDayPillToday(String change) {
    return '$change hoy';
  }

  @override
  String pfDayPillTooltip(String date, String coverage) {
    return 'Al cierre del $date · cubre el $coverage% del valor del portafolio';
  }

  @override
  String get pfDayColHeader => 'Día';

  @override
  String get pfDayUnavailable =>
      'Sin precio de cierre reciente para esta posición';

  @override
  String pfDaySemPayerRow(String symbol, String income) {
    return '$symbol, $income al año, abre el detalle de dividendos';
  }

  @override
  String pfDaySemExDateRow(String symbol, String date, String amount) {
    return '$symbol, fecha ex-dividendo estimada $date, pago esperado $amount';
  }

  @override
  String pfDaySemPositionsSubtotal(int count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count posiciones',
      one: '1 posición',
    );
    return '$_temp0, subtotal $amount';
  }

  @override
  String pfDaySemHoldingRow(
    String symbol,
    String qty,
    String value,
    String ret,
  ) {
    return '$symbol, $qty acciones, $value, rendimiento de $ret';
  }

  @override
  String get pfCsvExportTooltip => 'Exportar CSV';

  @override
  String get pfCsvHoldings => 'Posiciones (CSV)';

  @override
  String get pfCsvLots => 'Lotes de compra (CSV)';

  @override
  String get ovwOpensAccountDetails => 'Abre los detalles de la cuenta';

  @override
  String ovwEndingIn(String digits) {
    return 'terminada en $digits';
  }

  @override
  String ovwAccountActionsFor(String name) {
    return 'Acciones de la cuenta $name';
  }

  @override
  String get alloc2UnclassifiedBand => 'Sin clasificar (saldo de la cuenta)';

  @override
  String get alloc2UnclassifiedTooltip =>
      'Saldo de la cuenta sin detalle de posiciones — abre la cuenta para verlo';

  @override
  String get ins3EditAssetClass => 'Editar clase de activo';

  @override
  String get ins3Automatic => 'Automática';

  @override
  String ins3AutomaticWithClass(String className) {
    return 'Automática — $className';
  }

  @override
  String get ins3ManualCaption => 'manual';

  @override
  String get ins3UpdateError => 'No se pudo actualizar la clase de activo';

  @override
  String pf3LotQtyShares(String qty) {
    return '$qty títulos';
  }

  @override
  String pf3LotCurrentNow(String value) {
    return '$value ahora';
  }

  @override
  String pf3LotCost(String cost) {
    return 'costo $cost';
  }

  @override
  String get rg3AllTaxable =>
      'Todas las ganancias realizadas de este período son gravables.';

  @override
  String get acct3DeleteHoldingBody =>
      'Esto elimina la posición, todos sus lotes de compra y sus registros fiscales de ganancias realizadas.';

  @override
  String get acct3UndoHint =>
      'Puedes deshacer durante unos segundos después de eliminar.';

  @override
  String acct3DeletedSnack(String symbol) {
    return 'Se eliminó $symbol';
  }

  @override
  String get acct3Undo => 'Deshacer';

  @override
  String get acct3RestoreGone =>
      'No se pudo restaurar — la eliminación ya es permanente.';

  @override
  String get acct3RestoreFailed =>
      'No se pudo restaurar la posición. Inténtalo de nuevo.';

  @override
  String get ovw3DividendsPerYear => 'Dividendos/año';

  @override
  String ovw3DividendsTooltip(String yieldPct) {
    return 'Ingreso anual proyectado por dividendos · rendimiento combinado de $yieldPct% — toca para ver los pagadores';
  }

  @override
  String get ovw3DividendsTooltipNoYield =>
      'Ingreso anual proyectado por dividendos — toca para ver los pagadores';

  @override
  String get proj3ShowDividends =>
      'Mostrar panorama de ingresos por dividendos';

  @override
  String get proj3ShowDividendsHelp =>
      'Añade un panel informativo de ingresos bajo la gráfica — nunca modifica la proyección.';

  @override
  String get proj3ShowDividendsUnavailable =>
      'Tu portafolio no tiene ingreso proyectado por dividendos';

  @override
  String get proj3OutlookTitle => 'Panorama de ingresos por dividendos';

  @override
  String get proj3RowToday => 'Hoy';

  @override
  String proj3RowRetirement(String year) {
    return 'Al retiro (~$year)';
  }

  @override
  String proj3RowHorizon(String year) {
    return 'Al horizonte ($year)';
  }

  @override
  String proj3PerYear(String amount) {
    return '$amount/año';
  }

  @override
  String proj3PerYearApprox(String amount) {
    return '≈$amount/año';
  }

  @override
  String proj3BlendedYieldNote(String pct) {
    return 'rendimiento combinado de $pct%';
  }

  @override
  String get proj3InTodaysDollars => 'en dólares de hoy';

  @override
  String get proj3DisclaimerBody =>
      'Supone que el rendimiento combinado actual se mantiene. Los dividendos ya forman parte del rendimiento total esperado de arriba: es informativo y no se suma al crecimiento.';

  @override
  String axPortfolioHero(String value, String allTime) {
    return 'Valor del portafolio $value, histórico $allTime';
  }

  @override
  String axHeroToday(String change) {
    return 'hoy $change';
  }

  @override
  String axActiveFilter(String label) {
    return 'Filtro activo: $label';
  }

  @override
  String get axClearFilter => 'Quitar filtro';

  @override
  String axLotRow(String date, String qty, String cost, String term) {
    return 'Adquirido el $date, $qty acciones a $cost, $term';
  }

  @override
  String axYearChip(String year) {
    return 'Año $year';
  }

  @override
  String get axAllYears => 'Todos los años';

  @override
  String axSoldOn(String date) {
    return 'vendido el $date';
  }

  @override
  String axGroupBy(String dimension) {
    return 'Agrupar por $dimension';
  }

  @override
  String axGroupAccounts(String name, int count, String total) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cuentas',
      one: '1 cuenta',
    );
    return '$name, $_temp0, $total';
  }

  @override
  String get axTapToExpand => 'Toca para expandir';

  @override
  String get axTapToCollapse => 'Toca para contraer';

  @override
  String axRemoveHolding(String symbol) {
    return 'Eliminar $symbol';
  }

  @override
  String axAccountActionsFor(String name) {
    return 'Acciones de la cuenta $name';
  }

  @override
  String axDividendPerYear(String amount) {
    return 'dividendo de $amount al año';
  }

  @override
  String axProjectionChart(String start, String end, String value) {
    return 'Saldo proyectado de $start a $end, mediana final $value';
  }

  @override
  String get axInformational =>
      'Informativo: los dividendos ya forman parte del rendimiento total esperado y no se suman al crecimiento';

  @override
  String get calShowCalendar => 'Mostrar calendario de 12 meses';

  @override
  String get calHideCalendar => 'Ocultar calendario de 12 meses';

  @override
  String get calEstimateCaption =>
      'Estimado con la tasa y cadencia actuales de cada pagador — no son fechas anunciadas.';

  @override
  String get calExpandHint => 'Mostrar desglose por pagador';

  @override
  String get calCollapseHint => 'Ocultar desglose por pagador';

  @override
  String calEstExDate(String date) {
    return 'Fecha ex estimada: $date';
  }

  @override
  String calMonthSem(String month, String amount, String symbols) {
    return '$month, $amount esperados, $symbols';
  }

  @override
  String calMonthSemEmpty(String month) {
    return '$month, sin dividendos esperados';
  }

  @override
  String get pfDivDetailRefresh => 'Actualizar datos de dividendos';

  @override
  String get rebCardTitle => 'Asignación objetivo';

  @override
  String get rebEditTargets => 'Editar objetivos';

  @override
  String get rebSetTargetsCta =>
      'Define porcentajes objetivo por clase de activo para ver la desviación y sugerencias de rebalanceo';

  @override
  String get rebSetTargetsButton => 'Definir objetivos';

  @override
  String get rebRepairBanner =>
      'Los objetivos guardados necesitan atención: no suman 100 %.';

  @override
  String get rebRepairButton => 'Corregir objetivos';

  @override
  String get rebOnTargetChip => 'en objetivo';

  @override
  String rebDeltaChip(String delta) {
    return '$delta pp';
  }

  @override
  String rebRowSemantics(
    String label,
    String actual,
    String target,
    String delta,
  ) {
    return '$label: actual $actual %, objetivo $target %, $delta';
  }

  @override
  String rebUnclassifiedFootnote(String pct) {
    return 'Sin clasificar: $pct — clasifica estas posiciones para incluirlas en los objetivos';
  }

  @override
  String rebUnclassifiedBalanceFootnote(String pct) {
    return 'Sin clasificar: $pct — saldos de cuentas sin detalle de posiciones, incluidos en los totales';
  }

  @override
  String get rebGuidanceTitle => 'Para alcanzar los objetivos';

  @override
  String rebMoveLine(String amount, String from, String to) {
    return 'Mueve $amount de $from a $to';
  }

  @override
  String get rebMoreAdjustments => '…y ajustes menores';

  @override
  String get rebNoMoves =>
      'A menos de 2 pp de cada objetivo: no se necesitan movimientos.';

  @override
  String get rebBelowFloor =>
      'La desviación restante está por debajo del umbral de acción: sin movimientos sugeridos.';

  @override
  String get rebTaxCaption =>
      'Solo orientativo: considera impuestos y selección de lotes antes de vender.';

  @override
  String get rebEditorTitle => 'Editar asignación objetivo';

  @override
  String rebEditorTotal(String total) {
    return 'Total: $total / 100';
  }

  @override
  String get rebDistributeRemainder => 'Repartir el resto';

  @override
  String get rebRemoveTargets => 'Quitar objetivos';

  @override
  String get rebRemoveConfirmTitle => '¿Quitar objetivos?';

  @override
  String get rebRemoveConfirmBody =>
      'La tarjeta vuelve a su estado inicial. Tus posiciones no se ven afectadas.';

  @override
  String get rebSaveError =>
      'No se pudieron guardar los objetivos. Inténtalo de nuevo.';

  @override
  String get rebRemoveError =>
      'No se pudieron quitar los objetivos. Inténtalo de nuevo.';

  @override
  String nwMoversSince(String date) {
    return 'Desde $date';
  }

  @override
  String get nwMoversToggleTooltip => 'Qué impulsó este cambio';

  @override
  String get fxcPillTapHint => 'Toca para ver historial y herramientas';

  @override
  String get fxcChipHoldHint =>
      'Mantén presionado para ver historial y herramientas';

  @override
  String get fxcRange30d => '30 días';

  @override
  String get fxcRange90d => '90 días';

  @override
  String get fxcNoHistory => 'Aún no hay historial del tipo de cambio';

  @override
  String get fxcHistoryFailed =>
      'No se pudo cargar el historial del tipo de cambio';

  @override
  String fxcChartSemantics(int count, String latest, String pair) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count puntos diarios',
      one: '$count punto diario',
    );
    return 'Historial del tipo de cambio $pair: $_temp0, último $latest';
  }

  @override
  String get fxcConverterTitle => 'Convertidor';

  @override
  String get fxcAlertTitle => 'Alerta de tipo de cambio';

  @override
  String fxcAlertHint(String base, String target) {
    return 'Recibe una notificación cuando el tipo de cambio $base/$target cruce este valor.';
  }

  @override
  String fxcAlertActive(String threshold) {
    return 'Alerta configurada: se te notificará cuando el tipo de cambio cruce $threshold';
  }

  @override
  String get fxcAlertClear => 'Quitar alerta';

  @override
  String get fxcAlertSaved => 'Alerta de tipo de cambio guardada';

  @override
  String get fxcAlertCleared => 'Alerta de tipo de cambio eliminada';

  @override
  String get fxcAlertInvalid => 'Ingresa un umbral mayor que cero';

  @override
  String get fxcAlertFailed => 'No se pudo guardar la alerta';

  @override
  String get fxcRefreshFailed => 'No se pudo actualizar el tipo de cambio';

  @override
  String get recTitle => 'Recurrentes';

  @override
  String get recExpectedChip => 'Previsto';

  @override
  String get recExpectedNote =>
      'Previsto según tus reglas recurrentes — no son transacciones reales.';

  @override
  String get recExpectedIn => 'Entradas previstas';

  @override
  String get recExpectedOut => 'Salidas previstas';

  @override
  String get recManage => 'Administrar';

  @override
  String get recManageTitle => 'Reglas recurrentes';

  @override
  String get recNoRules =>
      'Aún no hay reglas recurrentes. Usa \"Hacer recurrente\" en una transacción o la opción Se repite al agregarla.';

  @override
  String get recNothingUpcoming => 'No se espera nada más en este período.';

  @override
  String get recPaused => 'En pausa';

  @override
  String get recPauseRule => 'Pausar';

  @override
  String get recResumeRule => 'Reanudar';

  @override
  String get recCadenceWeekly => 'Semanal';

  @override
  String get recCadenceBiweekly => 'Cada 2 semanas';

  @override
  String get recCadenceMonthly => 'Mensual';

  @override
  String get recCadenceYearly => 'Anual';

  @override
  String recNextDue(Object date) {
    return 'Próximo: $date';
  }

  @override
  String get recMakeRecurring => 'Hacer recurrente';

  @override
  String get recRuleCreated => 'Regla recurrente creada';

  @override
  String get recRuleDeleted => 'Regla recurrente eliminada';

  @override
  String get recDeleteConfirmTitle => '¿Eliminar la regla recurrente?';

  @override
  String recDeleteConfirmBody(Object description) {
    return '\"$description\" ya no aparecerá en el flujo de efectivo previsto. Las transacciones pasadas no se ven afectadas.';
  }

  @override
  String get recRepeats => 'Se repite';

  @override
  String get recRepeatsNever => 'No se repite';

  @override
  String get recNextDueDate => 'Próxima fecha';

  @override
  String get recCreateRule => 'Crear regla';

  @override
  String get projMxToggle => 'Retiro en México';

  @override
  String get projMxToggleOn =>
      'El gasto en el retiro se divide en una parte en USD y otra en MXN, con un supuesto de deriva cambiaria de largo plazo';

  @override
  String get projMxToggleOff =>
      'Apagado: el gasto en el retiro es una sola cifra en dólares';

  @override
  String get projMxUsdPortion => 'Gasto en EE. UU. (USD/año)';

  @override
  String get projMxHelpUsdPortion =>
      'La parte de tu gasto en el retiro que se queda en dólares, en dólares de hoy.';

  @override
  String get projMxMxnPortion => 'Gasto en México (MXN/año)';

  @override
  String get projMxHelpMxnPortion =>
      'La parte de tu gasto en el retiro en pesos, en pesos de hoy.';

  @override
  String get projMxFxDrift => 'Deriva cambiaria de largo plazo (USD/MXN)';

  @override
  String get projMxHelpFxDrift =>
      'Cambio anual supuesto del tipo de cambio USD/MXN más allá de la inflación. Positivo = el peso se debilita y el gasto en pesos cuesta menos dólares; 0% = se mantiene la paridad de poder de compra.';

  @override
  String get projMxPanelTitle => 'Escenario de retiro en México';

  @override
  String get projMxIncomeRow => 'Ingreso en el retiro (mensual)';

  @override
  String get projMxEffectiveSpend => 'Gasto anual efectivo';

  @override
  String projMxRateLine(String now, String retire) {
    return 'USD/MXN $now hoy → ≈$retire al retiro';
  }

  @override
  String get projMxDisclaimer =>
      'La parte en pesos se convierte al tipo de cambio proyectado al momento del retiro y el modelo sigue calculando en dólares de hoy. Las cifras en pesos se muestran a ese mismo tipo de cambio.';
}
