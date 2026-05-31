// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Patrimonio';

  @override
  String get navOverview => 'Overview';

  @override
  String get navPortfolio => 'Portfolio';

  @override
  String get navTransactions => 'Transactions';

  @override
  String get navCashFlow => 'Cash flow';

  @override
  String get navProjections => 'Projections';

  @override
  String get navTaxPlanning => 'Tax planning';

  @override
  String get navLending => 'Lending';

  @override
  String get navSettings => 'Settings';

  @override
  String get navShortOverview => 'Home';

  @override
  String get navShortPortfolio => 'Invest';

  @override
  String get navShortTransactions => 'Activity';

  @override
  String get navShortCashFlow => 'Cash';

  @override
  String get navShortProjections => 'Proj.';

  @override
  String get navShortTaxPlanning => 'Tax';

  @override
  String get navShortLending => 'Loans';

  @override
  String get navShortSettings => 'Settings';

  @override
  String get navMore => 'More';

  @override
  String get navMoreGroup => 'MORE';

  @override
  String get actionAdd => 'Add';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionSave => 'Save';

  @override
  String get actionApply => 'Apply';

  @override
  String get actionDelete => 'Delete';

  @override
  String get actionClose => 'Close';

  @override
  String get commonRequired => 'Required';

  @override
  String get searchTransactionsHint => 'Search transactions…';

  @override
  String get languageLabel => 'Language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSpanish => 'Español';

  @override
  String currencyToggleTooltip(String code) {
    return 'Reporting in $code · tap to swap';
  }

  @override
  String get authSignInToContinue => 'Sign in to continue';

  @override
  String get authUsername => 'Username';

  @override
  String get authPassword => 'Password';

  @override
  String get authSignIn => 'Sign in';

  @override
  String get authSignInWithPasskey => 'Sign in with passkey';

  @override
  String get authForgotPassword => 'Forgot password?';

  @override
  String get authEnterUsernameFirst => 'Enter your username first.';

  @override
  String get statNetWorth => 'Net worth';

  @override
  String get statAssets => 'Assets';

  @override
  String get statLiabilities => 'Liabilities';

  @override
  String get statCash => 'Cash';

  @override
  String get statInvestments => 'Investments';

  @override
  String get lendingTitle => 'Money I\'ve lent';

  @override
  String get lendingAddLoan => 'Add loan';

  @override
  String get lendingOutstanding => 'Outstanding';

  @override
  String get lendingTotalLent => 'Total lent';

  @override
  String get lendingActive => 'Active';

  @override
  String get lendingInterestEarned => 'Interest earned';

  @override
  String get lendingRepaid => 'Repaid';

  @override
  String get lendingNoLoans => 'No loans yet';

  @override
  String get lendingEmptySubtitle =>
      'Lent money to a friend? Add it here, then designate the bank transactions that funded it and paid it back.';

  @override
  String get txOverrideCleared => 'Override cleared';

  @override
  String get txRenamed => 'Renamed';

  @override
  String txRenameFailed(Object error) {
    return 'Rename failed: $error';
  }

  @override
  String get txRenameFailedShort => 'Rename failed';

  @override
  String get txFlowExpense => 'Expense';

  @override
  String get txFlowIncome => 'Income';

  @override
  String get txFlowAll => 'All';

  @override
  String get txFlow => 'Flow';

  @override
  String get txStatusPending => 'Pending';

  @override
  String get txStatusSettled => 'Settled';

  @override
  String get txStatusAll => 'All';

  @override
  String get txStatus => 'Status';

  @override
  String get txClearAll => 'Clear all';

  @override
  String get txEmptyTitle => 'No transactions yet';

  @override
  String get txEmptyBody =>
      'Link a bank, import a statement, or add an account manually\nto start seeing activity here.';

  @override
  String get txAddAccount => 'Add an account';

  @override
  String txShowingCount(Object shown, Object total) {
    return 'Showing $shown of $total';
  }

  @override
  String get txLoadMore => 'Load more';

  @override
  String get txSelectAll => 'Select all';

  @override
  String get txDeselectAll => 'Deselect all';

  @override
  String get txSetCategory => 'Set category';

  @override
  String get txMoveAccount => 'Move account';

  @override
  String get txRename => 'Rename';

  @override
  String get txClear => 'Clear';

  @override
  String txSelectedCount(Object count) {
    return '$count selected';
  }

  @override
  String get txCategoryHint => 'e.g. Restaurants';

  @override
  String txRenameNTitle(Object count) {
    return 'Rename $count transactions';
  }

  @override
  String get txNewDescription => 'New description';

  @override
  String get txRenameHint => 'e.g. Rent — March';

  @override
  String txDeleteNTitle(Object count) {
    return 'Delete $count transactions?';
  }

  @override
  String get txBulkDeleteBody =>
      'They\'ll be removed from your lists and totals. A future sync may re-import bank-linked transactions.';

  @override
  String txDeletingN(Object count) {
    return 'Deleting $count transactions…';
  }

  @override
  String txDeletedN(Object count) {
    return 'Deleted $count transactions';
  }

  @override
  String get txDeleteSomeFailed => 'Couldn\'t delete some transactions';

  @override
  String get txMoveToAccount => 'Move to account';

  @override
  String txSplitIntoN(Object count) {
    return 'Split into $count parts';
  }

  @override
  String txSplitFailed(Object error) {
    return 'Split failed: $error';
  }

  @override
  String get txSplitChildrenNotFound =>
      'Could not find split children to edit.';

  @override
  String txSplitUpdatedN(Object count) {
    return 'Split updated ($count parts)';
  }

  @override
  String txEditSplitFailed(Object error) {
    return 'Edit split failed: $error';
  }

  @override
  String get txRenameTransaction => 'Rename transaction';

  @override
  String get txRenameDisplayLabelHelp =>
      'Display label only. The original bank description is preserved and remains visible in this row\'s detail panel under \"Raw bank text\".';

  @override
  String get txDisplayLabel => 'Display label';

  @override
  String get txDisplayLabelHint => 'e.g. Rent — John';

  @override
  String txAlsoApplyToN(Object count) {
    return 'Also apply to $count matching transactions';
  }

  @override
  String get txAlsoApplySubtitle =>
      'Rows that share this raw bank description.';

  @override
  String get txClearOverride => 'Clear override';

  @override
  String txRenamedN(Object count) {
    return 'Renamed $count transactions';
  }

  @override
  String txRenamedNFailed(Object failed, Object ok) {
    return 'Renamed $ok · $failed failed';
  }

  @override
  String txUpdatingN(Object count) {
    return 'Updating $count transactions…';
  }

  @override
  String txUpdatedN(Object count) {
    return 'Updated $count transactions';
  }

  @override
  String txUpdatedNFailed(Object failed, Object ok) {
    return 'Updated $ok · $failed failed';
  }

  @override
  String get txCloseSearch => 'Close search';

  @override
  String get txRecentTransactions => 'Recent transactions';

  @override
  String get txFilterTransactions => 'Filter transactions';

  @override
  String get txExitSelectionMode => 'Exit selection mode';

  @override
  String get txSelectMultiple => 'Select multiple';

  @override
  String get txAddTransaction => 'Add transaction';

  @override
  String get txExportCsv => 'Export CSV';

  @override
  String get txScanTransfers =>
      'Scan for cross-currency transfers (Wise / Remitly / etc.)';

  @override
  String get txSearchTransactions => 'Search transactions';

  @override
  String get txDateToday => 'Today';

  @override
  String get txDateYesterday => 'Yesterday';

  @override
  String get txInlineEditHint => 'New label · Enter to save';

  @override
  String get txSplitPill => 'Split';

  @override
  String get txDismiss => 'Dismiss';

  @override
  String txRenamePlusMatching(Object count) {
    return 'Rename (+$count matching)';
  }

  @override
  String get txOutflow => 'OUTFLOW';

  @override
  String get txInflow => 'INFLOW';

  @override
  String txApproxEstimated(Object amount) {
    return '≈ $amount (estimated)';
  }

  @override
  String get txRawBankText => 'Raw bank text';

  @override
  String get txCategoryAndNotes => 'Category & notes';

  @override
  String get txCategory => 'Category';

  @override
  String txCategoryExample(Object category) {
    return 'e.g. $category';
  }

  @override
  String get txNotes => 'Notes';

  @override
  String get txNotesHint => 'Why does this transaction matter?';

  @override
  String get txRecentAtMerchant => 'Recent at this merchant';

  @override
  String txMerchantTotal(Object amount, Object count) {
    return 'Total: $amount across $count transactions';
  }

  @override
  String get txMoveToDifferentAccount => 'Move to a different account';

  @override
  String txMoveFailed(Object error) {
    return 'Move failed: $error';
  }

  @override
  String get txSplitThisTransaction => 'Split this transaction';

  @override
  String get txEditSplit => 'Edit split';

  @override
  String get txSplitRemoved => 'Split removed';

  @override
  String txUnsplitFailed(Object error) {
    return 'Unsplit failed: $error';
  }

  @override
  String get txUnsplitRestore => 'Unsplit (restore original)';

  @override
  String get txDeleteOneTitle => 'Delete transaction?';

  @override
  String get txDeleteOneBody =>
      'This permanently removes the transaction. To re-import from CSV/PDF you will need to upload the file again.';

  @override
  String txDeleteFailed(Object error) {
    return 'Delete failed: $error';
  }

  @override
  String get txLinkedTransfer => 'Linked cross-currency transfer';

  @override
  String get txConfirmed => 'Confirmed';

  @override
  String txAutoConfidence(Object confidence) {
    return 'Auto · $confidence%';
  }

  @override
  String txAutoConfidenceKeyword(Object confidence, Object keyword) {
    return 'Auto · $confidence% · $keyword';
  }

  @override
  String txTransferImpliedRate(
    Object dstAmount,
    Object dstCurrency,
    Object rate,
    Object srcAmount,
    Object srcCurrency,
  ) {
    return '$srcAmount → $dstAmount · implied $rate $dstCurrency/$srcCurrency';
  }

  @override
  String get txConfirm => 'Confirm';

  @override
  String get txUnlink => 'Unlink';

  @override
  String get txSourcePlaid => 'Synced via Plaid';

  @override
  String get txSourceCsv => 'Imported (CSV)';

  @override
  String get txSourceManual => 'Manual entry';

  @override
  String get txSourceUnknown => 'Unknown source';

  @override
  String get txReassignTo => 'Reassign to…';

  @override
  String get txMove => 'Move';

  @override
  String get txDateAllTime => 'All time';

  @override
  String get txDateLast7Days => 'Last 7 days';

  @override
  String get txDateLast30Days => 'Last 30 days';

  @override
  String get txDateLast90Days => 'Last 90 days';

  @override
  String get txDateYtd => 'Year to date';

  @override
  String get txDateLastYear => 'Last year';

  @override
  String get txDateCustomRange => 'Custom range';

  @override
  String get txReset => 'Reset';

  @override
  String get txDateRange => 'Date range';

  @override
  String get txAccounts => 'Accounts';

  @override
  String get txCategories => 'Categories';

  @override
  String get txSplitSameAsParentUncategorised =>
      'Same as parent (uncategorised)';

  @override
  String txSplitSameAsParent(Object category) {
    return 'Same as parent ($category)';
  }

  @override
  String txSplitExistingCategory(Object category) {
    return '$category  (existing)';
  }

  @override
  String get txSplitTransactionTitle => 'Split transaction';

  @override
  String get txQuickSplit => 'Quick split';

  @override
  String get txSplitEven => 'Even split…';

  @override
  String txSplitTotal(Object amount, Object kind) {
    return 'Total: $amount $kind';
  }

  @override
  String get txSplitExpenseTag => '(expense)';

  @override
  String get txSplitIncomeTag => '(income)';

  @override
  String get txSplitDescription => 'Description';

  @override
  String get txSplitAmount => 'Amount';

  @override
  String get txSplitRemoveRow => 'Remove row';

  @override
  String get txSplitAddRow => 'Add row';

  @override
  String get txSplitMatches => 'Splits match the parent total.';

  @override
  String txSplitOffBy(Object amount) {
    return 'Off by $amount.';
  }

  @override
  String txSplitApproxIn(Object amount, Object currency) {
    return '≈ $amount in $currency';
  }

  @override
  String get txSplitSaveChanges => 'Save changes';

  @override
  String get txSplitSave => 'Save split';

  @override
  String get txSplitEvenlyTitle => 'Split evenly';

  @override
  String txSplitEvenlyBody(Object count) {
    return 'Divide the parent amount into $count equal parts.';
  }

  @override
  String get secTitle => 'Security';

  @override
  String get secPasswordSection => 'Password';

  @override
  String get secChangePassword => 'Change password';

  @override
  String get secChangePasswordSubtitle => 'Sign out of every other session.';

  @override
  String get secTwoFactorSection => 'Two-factor authentication';

  @override
  String get secTotpEnabled => 'TOTP enabled';

  @override
  String get secAddAuthenticatorApp => 'Add an authenticator app';

  @override
  String get secTotpEnabledSubtitle =>
      'You will be asked for a 6-digit code at each sign-in.';

  @override
  String get secAddAuthenticatorSubtitle =>
      'Scan a QR code with Authy / Google Authenticator / 1Password.';

  @override
  String get secRecoveryCodesSection => 'Recovery codes';

  @override
  String get secNoCodesLeft => 'No recovery codes left';

  @override
  String secFewCodesLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'Only $count recovery code$_temp0 left';
  }

  @override
  String get secLowCodesWarningBody =>
      'If you lose your authenticator and run out of codes you can be locked out. Regenerate now to restore a full set of 10.';

  @override
  String get secRegenerate => 'Regenerate';

  @override
  String secUnusedCodes(Object count) {
    return '$count unused codes';
  }

  @override
  String get secUnusedCodesSubtitle =>
      'Regenerate if you lose your saved codes — all old codes stop working.';

  @override
  String get secRegenerateCodesTitle => 'Regenerate recovery codes?';

  @override
  String get secRegenerateCodesBody =>
      'Your old codes will stop working immediately. Make sure you save the new ones before closing the dialog.';

  @override
  String get secGenerateNew => 'Generate new';

  @override
  String get secPasswordChangedSnack =>
      'Password changed. Other sessions signed out.';

  @override
  String get secTwoFactorEnabledSnack => 'Two-factor authentication enabled.';

  @override
  String get secTwoFactorDisabledSnack => 'Two-factor authentication disabled.';

  @override
  String get secDisableTwoFactorTitle => 'Disable two-factor authentication?';

  @override
  String get secDisableTwoFactorBody =>
      'Enter your password to confirm. Disabling TOTP makes your account less secure.';

  @override
  String secFailedWithReason(Object reason) {
    return 'Failed: $reason';
  }

  @override
  String get secSignOutSessionTitle => 'Sign out this session?';

  @override
  String secSignOutSessionBody(Object device) {
    return 'This will sign out the device \"$device\" immediately. They will have to enter the password (and TOTP) to sign in again.';
  }

  @override
  String get secSignOut => 'Sign out';

  @override
  String get secSessionSignedOutSnack => 'Session signed out.';

  @override
  String get secSignOutThisDeviceTitle => 'Sign out of this device?';

  @override
  String get secSignOutThisDeviceBody =>
      'You will need to enter your password again (and TOTP, if enabled) to sign back in.';

  @override
  String get secSignOutEverywhereTitle => 'Sign out everywhere else?';

  @override
  String secSignOutEverywhereBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'This will end $count other session$_temp0 immediately. This device will stay signed in.';
  }

  @override
  String get secSignOutOthers => 'Sign out others';

  @override
  String secOtherSessionsSignedOutSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count other sessions signed out.',
      one: '1 other session signed out.',
    );
    return '$_temp0';
  }

  @override
  String secOnOs(Object os) {
    return 'on $os';
  }

  @override
  String get secUnknownDevice => 'Unknown device';

  @override
  String get secActiveJustNow => 'Active just now';

  @override
  String secActiveMinutesAgo(Object minutes) {
    return 'Active ${minutes}m ago';
  }

  @override
  String secActiveHoursAgo(Object hours) {
    return 'Active ${hours}h ago';
  }

  @override
  String secActiveDaysAgo(Object days) {
    return 'Active ${days}d ago';
  }

  @override
  String secActiveOnDate(Object date) {
    return 'Active on $date';
  }

  @override
  String get secInviteUsersSection => 'Invite users';

  @override
  String get secNewInviteLink => 'New invite link';

  @override
  String get secNoInvites => 'No invites';

  @override
  String get secNoInvitesSubtitle =>
      'Generate a one-time link to let another person sign up for their own Patrimonio account.';

  @override
  String get secInviteRedeemed => 'Redeemed';

  @override
  String get secInviteExpired => 'Expired';

  @override
  String get secInviteActive => 'Active';

  @override
  String get secReadOnlyChip => 'Read-only';

  @override
  String secInviteUsedOn(Object date) {
    return 'Used $date';
  }

  @override
  String secInviteExpiresOn(Object date) {
    return 'Expires $date';
  }

  @override
  String get secRevoke => 'Revoke';

  @override
  String secManyActiveInvitesHint(Object count) {
    return 'You have $count active invites — consider revoking unused links.';
  }

  @override
  String get secReadOnlyInviteReadyTitle => 'Read-only invite link ready';

  @override
  String get secInviteReadyTitle => 'Invite link ready';

  @override
  String get secReadOnlyInviteReadyBody =>
      'Share this URL with the new user. They will be able to view your data but not change anything. It works for one account creation and expires on:';

  @override
  String get secInviteReadyBody =>
      'Share this URL with the new user. It works for one account creation and expires on:';

  @override
  String get secCopiedToClipboard => 'Copied to clipboard.';

  @override
  String get secCopyAgain => 'Copy again';

  @override
  String get secDone => 'Done';

  @override
  String get secRevokeInviteTitle => 'Revoke invite?';

  @override
  String get secRevokeInviteBody =>
      'The link will stop working immediately. You can mint a new one if you change your mind.';

  @override
  String secRevokeFailedWithReason(Object reason) {
    return 'Revoke failed: $reason';
  }

  @override
  String get secPasskeysSection => 'Passkeys';

  @override
  String get secAdd => 'Add';

  @override
  String get secThisDevice => 'This device';

  @override
  String get secThisDeviceSubtitle => 'Face ID / Touch ID / Windows Hello';

  @override
  String get secSecurityKey => 'Security key';

  @override
  String get secSecurityKeySubtitle => 'USB / NFC key — YubiKey, Titan';

  @override
  String get secPasskeysUnavailable => 'Passkeys not available';

  @override
  String get secPasskeysUnavailableSubtitle =>
      'This browser does not expose the WebAuthn API. Try Chrome, Safari, or Edge on a recent OS to register a passkey.';

  @override
  String get secNoPasskeys => 'No passkeys registered';

  @override
  String get secNoPasskeysSubtitle =>
      'Add this device, your phone, or a hardware security key (YubiKey, Titan, etc.) so you can sign in with biometrics or a tap instead of a password.';

  @override
  String get secInsertSecurityKeyPrompt =>
      'Insert your security key and tap it (choose the USB/security-key option if your browser offers a saved passkey)…';

  @override
  String get secConfirmBiometricPrompt => 'Confirm with your device biometric…';

  @override
  String get secPasskeyAddedSnack => 'Passkey added.';

  @override
  String get secRemovePasskeyTitle => 'Remove this passkey?';

  @override
  String secRemovePasskeyBody(Object name) {
    return 'You will no longer be able to sign in with \"$name\". This cannot be undone.';
  }

  @override
  String get secThisDeviceFallback => 'this device';

  @override
  String get secRemove => 'Remove';

  @override
  String get secPasskeyRemovedSnack => 'Passkey removed.';

  @override
  String get secActiveSessionsSection => 'Active sessions';

  @override
  String secSignOutNOthers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Sign out $count others',
      one: 'Sign out 1 other',
    );
    return '$_temp0';
  }

  @override
  String get secNoActiveSessions => 'No active sessions';

  @override
  String get secNoActiveSessionsSubtitle =>
      'You should at least see this device. Refresh to retry.';

  @override
  String get secThisDeviceBadge => 'This device';

  @override
  String get secNewSinceLastVisit => 'New since last visit';

  @override
  String get secSignOutSessionTooltip => 'Sign out this session';

  @override
  String get secChangePasswordTitle => 'Change password';

  @override
  String get secCurrentPasswordLabel => 'Current password';

  @override
  String get secNewPasswordLabel => 'New password (12+ characters)';

  @override
  String get secPasswordTooShort => 'At least 12 characters';

  @override
  String get secConfirmPasswordLabel => 'Confirm';

  @override
  String get secPasswordsDoNotMatch => 'Passwords do not match';

  @override
  String get secChangeButton => 'Change';

  @override
  String get secEnterSixDigitCode => 'Enter the 6-digit code from your app.';

  @override
  String get secEnrollTitle => 'Set up two-factor authentication';

  @override
  String get secEnrollSteps =>
      '1. Open your authenticator app (Authy, Google Authenticator, 1Password, etc.).\n2. Scan the QR code below — or choose \"Enter a setup key\" and paste the secret.\n3. Enter the 6-digit code your app shows.';

  @override
  String get secSetupLinkSecret => 'Setup link / secret';

  @override
  String get secHide => 'Hide';

  @override
  String get secShow => 'Show';

  @override
  String get secCopyOtpauthUri => 'Copy otpauth:// URI';

  @override
  String get secSixDigitCodeLabel => '6-digit code from your app';

  @override
  String get secEnable => 'Enable';

  @override
  String get secConfirm => 'Confirm';

  @override
  String secPasskeyRegisteredOn(Object date) {
    return 'Registered $date';
  }

  @override
  String get secLastUsedJustNow => 'Last used just now';

  @override
  String secLastUsedMinutesAgo(Object minutes) {
    return 'Last used ${minutes}m ago';
  }

  @override
  String secLastUsedHoursAgo(Object hours) {
    return 'Last used ${hours}h ago';
  }

  @override
  String secLastUsedDaysAgo(Object days) {
    return 'Last used ${days}d ago';
  }

  @override
  String secLastUsedOn(Object date) {
    return 'Last used $date';
  }

  @override
  String get secHardwareKeyTitle => 'Hardware security key';

  @override
  String get secDevicePasskeyTitle => 'Device passkey';

  @override
  String get secHardwareKeyKind => 'Hardware security key';

  @override
  String get secPlatformPasskeyKind => 'Platform passkey';

  @override
  String get secRemovePasskeyTooltip => 'Remove passkey';

  @override
  String get secInviteAccessQuestion =>
      'What level of access should this invite grant?';

  @override
  String get secFullAccess => 'Full access';

  @override
  String get secFullAccessSubtitle =>
      'Can view and change everything — link accounts, edit transactions, run syncs.';

  @override
  String get secReadOnlyAccess => 'Read-only';

  @override
  String get secReadOnlyAccessSubtitle =>
      'Can view everything but cannot make changes. Good for a spouse, advisor, or accountant.';

  @override
  String get secCreateLink => 'Create link';

  @override
  String get secNamePasskeyTitle => 'Name this passkey';

  @override
  String get secNamePasskeyBody =>
      'Optional label so you can tell this passkey apart later. Examples: \"iPhone 15\", \"Work MacBook\", \"YubiKey on keychain\".';

  @override
  String get secDeviceNameLabel => 'Device name';

  @override
  String get secDeviceNameHint => 'e.g. iPhone 15';

  @override
  String get secContinue => 'Continue';

  @override
  String get cfMonthlyTitle => 'Cash flow this month';

  @override
  String get cfMonthlyExcludesTooltip =>
      'Excludes internal transfers between your accounts and credit-card payments — those move money around your own balance sheet without changing your spending.';

  @override
  String get cfIncome => 'Income';

  @override
  String get cfExpense => 'Expense';

  @override
  String get cfMonthlyEmpty =>
      'Cash flow will appear here once a few weeks of transactions are synced.';

  @override
  String cfVsLastMonth(Object delta) {
    return '$delta vs last month';
  }

  @override
  String get cfNotEnoughHistory => 'Not enough history yet';

  @override
  String get cfSubscriptionsTitle => 'Recurring charges';

  @override
  String cfSubscriptionsActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count active',
      one: '1 active',
    );
    return '$_temp0';
  }

  @override
  String cfSubscriptionsStoppedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stopped',
      one: '1 stopped',
    );
    return '$_temp0';
  }

  @override
  String cfPerMonthApprox(Object amount) {
    return '≈ $amount / mo';
  }

  @override
  String get cfSubscriptionsSubtitle =>
      'Charges that repeat every 5–62 days. Tap a row to filter the transactions list.';

  @override
  String get cfSubscriptionsNoneActive => 'No active subscriptions detected.';

  @override
  String cfSubscriptionsStoppedHeader(Object count) {
    return 'Stopped ($count)';
  }

  @override
  String get cfSubscriptionsStoppedHint => 'Last charged > 90 days ago';

  @override
  String get cfCadenceWeekly => 'Weekly';

  @override
  String get cfCadenceBiweekly => 'Bi-weekly';

  @override
  String get cfCadenceMonthly => 'Monthly';

  @override
  String cfCadenceEveryNDays(Object days) {
    return 'Every ${days}d';
  }

  @override
  String cfChargesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count charges',
      one: '1 charge',
    );
    return '$_temp0';
  }

  @override
  String cfLastCharged(Object date) {
    return 'last $date';
  }

  @override
  String cfPerMonth(Object amount) {
    return '$amount / mo';
  }

  @override
  String cfWasPerMonth(Object amount) {
    return 'was $amount / mo';
  }

  @override
  String get cfNotASubscription => 'Not a subscription — hide this row';

  @override
  String cfPlusNMore(Object count) {
    return '+$count more';
  }

  @override
  String get cfBudgetsTitle => 'Budgets this month';

  @override
  String get cfBudgetsEdit => 'Edit';

  @override
  String get cfBudgetsEmpty =>
      'Set a monthly budget for any category to track spending against it here.';

  @override
  String get cfBudgetsDialogTitle => 'Edit monthly budgets';

  @override
  String get cfTransfersTitle => 'Cross-currency transfers';

  @override
  String get cfTransfersSubtitle =>
      'Linked Wise / Remitly / wire pairs. Implied rate is the effective FX the service used; spot is the market rate on the source date.';

  @override
  String cfTransfersSpot(Object rate) {
    return 'spot $rate';
  }

  @override
  String get cfTransfersConfirm => 'Confirm';

  @override
  String get cfTransfersConfirmed => 'Confirmed';

  @override
  String get cfTransfersUnlink => 'Unlink';

  @override
  String get cfCreditNoAccounts => 'No credit accounts found.';

  @override
  String get cfCreditUtilizationHeader => 'CREDIT UTILIZATION';

  @override
  String get cfCreditAccountFallback => 'Credit account';

  @override
  String get cfCreditShowFewer => 'Show fewer';

  @override
  String cfCreditShowMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show $count more cards',
      one: 'Show 1 more card',
    );
    return '$_temp0';
  }

  @override
  String get authCreateAccount => 'Create account';

  @override
  String get authInviteIntro =>
      'You were invited. Pick a username and password to finish setting up your account.';

  @override
  String get authUsernameMaxLength => 'Max 64 characters';

  @override
  String get authEmailOptional => 'Email (optional)';

  @override
  String get authPasswordMinHelper => 'At least 12 characters';

  @override
  String get authConfirmPassword => 'Confirm password';

  @override
  String get authPasswordsDoNotMatch => 'Passwords do not match';

  @override
  String get authResetPasswordTitle => 'Reset password';

  @override
  String get authPasswordResetDoneTitle => 'Password reset';

  @override
  String get authPasswordResetDoneBody =>
      'Sign in with your new password. The code you used has been consumed.';

  @override
  String get authBackToSignIn => 'Back to sign in';

  @override
  String get authUseRecoveryCodeTitle => 'Use a recovery code';

  @override
  String get authUseRecoveryCodeBody =>
      'Enter one of the recovery codes you saved at setup. Each code is single-use — once redeemed it cannot be reused.';

  @override
  String get authRecoveryCodeLabel => 'Recovery code (e.g. XK4T-9PMQ-7HZL)';

  @override
  String get authRecoveryCodeHint => 'Hyphens and case are optional';

  @override
  String get authRecoveryCodeInvalid =>
      'Codes are 12 letters/digits (hyphens optional)';

  @override
  String get authNewPasswordLabel => 'New password (12+ characters)';

  @override
  String get authConfirmNewPassword => 'Confirm new password';

  @override
  String get authWelcomeTitle => 'Welcome to Patrimonio';

  @override
  String get authBootstrapSubtitle =>
      'Create the owner account. This is a one-time setup.';

  @override
  String get authPasswordWithMin => 'Password (12+ characters)';

  @override
  String get authTotpEnterCode => 'Enter the 6-digit code from your app.';

  @override
  String get authTotpTitle => 'Two-factor required';

  @override
  String get authTotpSubtitle =>
      'Open your authenticator app and enter the 6-digit code for Patrimonio.';

  @override
  String get authTotpVerify => 'Verify';

  @override
  String get impTitle => 'Import statement';

  @override
  String get impUploadHeading => 'Upload account statement';

  @override
  String impUploadSubtitle(Object banks) {
    return 'Upload CSV or PDF statements from $banks. We will automatically detect the format.';
  }

  @override
  String get impWaitForUpload =>
      'Wait for the current import to finish before adding more files.';

  @override
  String get impAddedFileFromDrop => 'Added 1 file from drop';

  @override
  String impAddedFilesFromDrop(Object count) {
    return 'Added $count files from drop';
  }

  @override
  String impUploadTooLarge(Object count, Object totalMb) {
    return 'These $count files total $totalMb MB, over the 100 MB upload limit. Remove some files and import them in separate batches.';
  }

  @override
  String get impLargeUploadTitle => 'Large upload';

  @override
  String impLargeUploadBody(Object totalMb) {
    return 'This batch is $totalMb MB — close to the 100 MB limit. Large uploads can be slow and may be rejected. Import anyway?';
  }

  @override
  String get impImportAnyway => 'Import anyway';

  @override
  String impFoundTransactions(Object count) {
    return 'Found $count transactions.';
  }

  @override
  String impFoundWithAutoDeselected(Object count, Object message) {
    return '$message ($count auto-deselected as informational)';
  }

  @override
  String impUploadFailed(Object error) {
    return 'Upload failed: $error';
  }

  @override
  String get impSelectAccountFirst =>
      'Please select a destination account first.';

  @override
  String get impNoTransactionsSelected =>
      'No transactions selected. Please check at least one.';

  @override
  String get impImportSuccessful => 'Import successful';

  @override
  String impConfirmationFailed(Object error) {
    return 'Confirmation failed: $error';
  }

  @override
  String get impReadingFiles => 'Reading files…';

  @override
  String get impReadingOneFile => 'Reading 1 file…';

  @override
  String impReadingNFiles(Object count) {
    return 'Reading $count files…';
  }

  @override
  String get impReadingHint =>
      'Loading file contents into the browser before sending. This step is local — no upload yet.';

  @override
  String get impProcessingOneFile => 'Processing 1 file…';

  @override
  String impProcessingProgress(Object done, Object total) {
    return 'Processing $done of $total files…';
  }

  @override
  String impProcessingNFiles(Object count) {
    return 'Processing $count files…';
  }

  @override
  String impLastFile(Object file) {
    return 'Last: $file';
  }

  @override
  String impLastFileSkipped(Object file) {
    return 'Last: $file (skipped)';
  }

  @override
  String get impLargeBatchHint =>
      'Large batches can take 30-120 seconds — each PDF is parsed individually on the server.';

  @override
  String get impDropToImport => 'Drop to import';

  @override
  String get impDropHint =>
      'Drop CSV or PDF files anywhere on this page, or select them manually below.';

  @override
  String get impNoFilesSelected => 'No files selected';

  @override
  String get impOneFileSelected => '1 file selected';

  @override
  String impNFilesSelected(Object count) {
    return '$count files selected';
  }

  @override
  String get impRemoveFile => 'Remove';

  @override
  String get impSelectFiles => 'Select files';

  @override
  String get impAddMoreFiles => 'Add more files';

  @override
  String get impAssignToAccount => 'Assign to account';

  @override
  String impPreviewSelected(Object selected, Object total) {
    return 'Preview ($selected/$total selected)';
  }

  @override
  String get impSelectAll => 'Select all';

  @override
  String get impDeselectAll => 'Deselect all';

  @override
  String get impAutoDeselectedTooltip => 'Auto-deselected: informational entry';

  @override
  String get impImportOneTransaction => 'Import 1 Transaction';

  @override
  String impImportNTransactions(Object count) {
    return 'Import $count Transactions';
  }

  @override
  String get impPdfPassword => 'PDF password (e.g. RFC)';

  @override
  String get impProcessStatement => 'Process statement';

  @override
  String get dashConnectViaOauth => 'Connect via OAuth';

  @override
  String get dashConnectWithApiKey => 'Connect with an API key';

  @override
  String dashPaletteJumpTo(Object name) {
    return 'Jump to $name';
  }

  @override
  String get dashPaletteSection => 'Section';

  @override
  String get dashPaletteSectionLending => 'Section · money you\'ve lent';

  @override
  String dashPaletteAccount(Object institution) {
    return 'Account · $institution';
  }

  @override
  String get dashPaletteHolding => 'Holding';

  @override
  String dashPaletteTransaction(Object account, Object date) {
    return 'Transaction · $account · $date';
  }

  @override
  String get dashHiddenFromSubscriptions => 'Hidden from subscriptions';

  @override
  String get dashHiddenFromSubscriptionsHint =>
      'You dismissed these as \"not a subscription.\" Unhide a row to let the detector reconsider it.';

  @override
  String get dashUnhide => 'Unhide';

  @override
  String dashSubscriptionRestored(Object merchant) {
    return '\"$merchant\" is back in the subscription detector';
  }

  @override
  String dashUnhideFailed(Object error) {
    return 'Unhide failed: $error';
  }

  @override
  String get dashModuleLendingTitle => 'Personal lending';

  @override
  String get dashModuleLendingSubtitle =>
      'Track money you lend to friends — designate the bank transactions that fund and repay each loan. Adds a Lending section.';

  @override
  String get dashRemindBeforeRepayment => 'Remind me before a repayment is due';

  @override
  String get dashFewerDays => 'Fewer days';

  @override
  String get dashMoreDays => 'More days';

  @override
  String dashDaysShort(Object count) {
    return '$count d';
  }

  @override
  String get dashReminderSaveFailed => 'Couldn\'t save reminder setting';

  @override
  String get dashSettingSaveFailed => 'Couldn\'t save that setting';

  @override
  String get dashEnvSandbox => 'Sandbox';

  @override
  String get dashEnvDev => 'Dev';

  @override
  String dashEnvTooltip(Object env) {
    return 'Plaid is in $env mode. Linked accounts will not access real bank data.';
  }

  @override
  String get dashFxLoading => 'Exchange rate loading…';

  @override
  String get dashFxLive => 'Live USD/MXN exchange rate';

  @override
  String dashFxStaleAt(Object timestamp) {
    return 'Stale rate — $timestamp';
  }

  @override
  String dashFxUpdatedAt(Object timestamp) {
    return 'Updated $timestamp';
  }

  @override
  String get dashLinkUsBank => 'Link a US bank';

  @override
  String get dashLinkUsBankSubtitle =>
      'Securely connect via Plaid — balances and transactions sync automatically.';

  @override
  String get dashLinkUsBankDisabledHint =>
      'Plaid credentials not configured yet — use CSV or manual for now.';

  @override
  String get dashImportMxCsvPdf => 'Import Mexico CSV or PDF';

  @override
  String dashImportMxCsvPdfSubtitle(Object banks) {
    return 'Drop a statement from $banks.';
  }

  @override
  String get dashAddManualAccount => 'Add a manual account';

  @override
  String get dashAddManualAccountSubtitle =>
      'Track a cash balance, brokerage, or anything else by hand.';

  @override
  String get dashTrackMoneyLent => 'Track money you\'ve lent';

  @override
  String get dashTrackMoneyLentSubtitle =>
      'Lend to friends or family? Record loans, reconcile repayments, and track interest.';

  @override
  String get dashConnectCryptoExchangeTile => 'Connect a crypto exchange';

  @override
  String get dashConnectCryptoExchangeTileSubtitle =>
      'Link Coinbase or Bitso to track crypto alongside your accounts.';

  @override
  String get dashOnboardingWelcome => 'Welcome to Patrimonio';

  @override
  String get dashOnboardingSubtitle =>
      'Connect your first account to see your net worth, transactions, and projections in one place.';

  @override
  String get dashOnboardingAlreadyLinked =>
      'Already linked accounts elsewhere? They will appear here as soon as the first sync completes.';

  @override
  String get dashAccountLinkedSuccess => 'Account linked successfully!';

  @override
  String get dashAccountLinkFailed =>
      'Failed to link account. Please try again.';

  @override
  String dashReconnectFailed(Object error) {
    return 'Reconnect failed: $error';
  }

  @override
  String dashWebhookPushed(Object count) {
    return 'Webhook URL pushed to $count institution(s)';
  }

  @override
  String dashWebhookPartial(Object failed, Object updated) {
    return '$updated updated, $failed failed';
  }

  @override
  String get dashUnknown => 'Unknown';

  @override
  String dashPushFailed(Object error) {
    return 'Push failed: $error';
  }

  @override
  String dashErrorLoading(Object error) {
    return 'Error loading dashboard: $error';
  }

  @override
  String get dashRetry => 'Retry';

  @override
  String dashUpdateFailed(Object error) {
    return 'Update failed: $error';
  }

  @override
  String get dashAccountDeleted => 'Account deleted';

  @override
  String dashDeleteFailed(Object error) {
    return 'Delete failed: $error';
  }

  @override
  String get dashNicknameCleared => 'Nickname cleared';

  @override
  String dashRenamedTo(Object nickname) {
    return 'Renamed to \"$nickname\"';
  }

  @override
  String dashRenameFailed(Object error) {
    return 'Rename failed: $error';
  }

  @override
  String get dashRevalued => 'Revalued';

  @override
  String get dashRevaluedNoteSaved => 'Revalued · note saved';

  @override
  String dashRevalueFailed(Object error) {
    return 'Revalue failed: $error';
  }

  @override
  String get dashNetWorthHistory => 'Net worth history';

  @override
  String get dashSyncingAll => 'Syncing all institutions…';

  @override
  String get dashSyncComplete => 'Sync complete';

  @override
  String dashSyncFailed(Object error) {
    return 'Sync failed: $error';
  }

  @override
  String get dashLaunchSetup => 'Launch setup';

  @override
  String get dashLaunchSetupReady =>
      'Plaid linking can start. Optional services may still improve data quality.';

  @override
  String get dashLaunchSetupBlocked =>
      'Complete required setup before real users can link Plaid accounts.';

  @override
  String dashPushToInstitutions(Object count) {
    return 'Push to $count institution(s)';
  }

  @override
  String dashRecommendedBeforeProduction(Object labels) {
    return 'Recommended before production: $labels.';
  }

  @override
  String dashConfirmFailed(Object error) {
    return 'Confirm failed: $error';
  }

  @override
  String dashUnlinkFailed(Object error) {
    return 'Unlink failed: $error';
  }

  @override
  String get dashScanningTransfers => 'Scanning for cross-currency transfers…';

  @override
  String dashTransfersLinked(Object checked, Object inserted) {
    return 'Linked $inserted transfer pair(s) (checked $checked candidates)';
  }

  @override
  String get dashNoNewTransfers => 'No new transfers found';

  @override
  String dashDetectionFailed(Object error) {
    return 'Detection failed: $error';
  }

  @override
  String dashUpdateTransactionFailed(Object error) {
    return 'Failed to update transaction: $error';
  }

  @override
  String get dashTransactionDeleted => 'Transaction deleted';

  @override
  String get dashLinkConfirmed => 'Link confirmed';

  @override
  String get dashPairUnlinked => 'Pair unlinked';

  @override
  String dashMerchantHidden(Object merchant) {
    return '\"$merchant\" hidden from subscriptions';
  }

  @override
  String dashFailedGeneric(Object error) {
    return 'Failed: $error';
  }

  @override
  String get dashDataSources => 'Data sources & sync';

  @override
  String dashRetryFailed(Object error) {
    return 'Retry failed: $error';
  }

  @override
  String get dashDeleteInstitutionTitle => 'Delete institution';

  @override
  String get dashDeleteInstitutionBody =>
      'Are you sure? This will remove ALL accounts and history for this institution.';

  @override
  String get dashDeleteEverything => 'Delete everything';

  @override
  String get dashFxRateRefreshed => 'FX rate refreshed';

  @override
  String dashRefreshFailed(Object error) {
    return 'Refresh failed: $error';
  }

  @override
  String get dashConnectStandardAccounts => 'Connect standard accounts';

  @override
  String get dashSyncAllAccounts => 'Sync all accounts';

  @override
  String get dashLinkPlaidUsBanks => 'Link Plaid (US Banks)';

  @override
  String get dashImportMxShort => 'Import Mexico (CSV/PDF)';

  @override
  String get dashAddManualAccountShort => 'Add manual account';

  @override
  String get dashConnectCryptoExchanges => 'Connect crypto exchanges';

  @override
  String get dashLinkCoinbase => 'Link Coinbase';

  @override
  String get dashConnectBitso => 'Connect Bitso';

  @override
  String get dashHiddenItems => 'Hidden items';

  @override
  String get dashSecurity => 'Security';

  @override
  String get dashSignOut => 'Sign out';

  @override
  String get dashThemeSystem => 'System theme';

  @override
  String get dashThemeLight => 'Light theme';

  @override
  String get dashThemeDark => 'Dark theme';

  @override
  String get dashThemeSystemDefault => 'System default';

  @override
  String get dashThemeLightShort => 'Light';

  @override
  String get dashThemeDarkShort => 'Dark';

  @override
  String dashThemeTooltip(Object label) {
    return '$label · tap to cycle, long-press to pick';
  }
}
