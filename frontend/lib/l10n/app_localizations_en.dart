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
  String get txAmount => 'Amount';

  @override
  String get txAmountMin => 'Min';

  @override
  String get txAmountMax => 'Max';

  @override
  String get txAmountFilterHelp =>
      'Matches the amount regardless of sign or currency.';

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
  String get txNoMatchesTitle => 'No transactions match';

  @override
  String get txNoMatchesBody => 'Try adjusting your search or filters.';

  @override
  String get txClearFiltersSearch => 'Clear filters & search';

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
  String get txExportCsvAllNote =>
      'Export CSV — exports all transactions (filters and search don\'t apply)';

  @override
  String get txExportAllTitle => 'Export all transactions?';

  @override
  String get txExportAllBody =>
      'Filters and search don\'t apply to the CSV export — it will include your entire transaction history.';

  @override
  String get txExportAllConfirm => 'Export all';

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
  String txMonthNet(Object amount) {
    return '$amount net';
  }

  @override
  String txMonthNetPartial(Object amount) {
    return '$amount net (partial)';
  }

  @override
  String get txInlineEditHint => 'New label · Enter to save';

  @override
  String get txSplitPill => 'Split';

  @override
  String get txTransferPill => 'Transfer';

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
  String get bmTitle => 'Investments vs S&P 500';

  @override
  String get bmSubtitle =>
      'If your contributions had bought the index, by purchase date';

  @override
  String bmAheadPts(Object pts) {
    return 'You\'re ahead of the index by $pts pts';
  }

  @override
  String bmBehindPts(Object pts) {
    return 'The index is ahead by $pts pts';
  }

  @override
  String get bmYou => 'You';

  @override
  String get bmSp500 => 'S&P 500';

  @override
  String bmAhead(Object pct) {
    return 'You\'re ahead of the market by $pct';
  }

  @override
  String bmBehind(Object pct) {
    return 'The market is ahead by $pct';
  }

  @override
  String get bmContribTitle => 'By contribution date';

  @override
  String get bmContribYou => 'Your tracked lots';

  @override
  String get bmContribIndex => 'Same money in S&P 500';

  @override
  String bmContribNote(Object count, Object invested) {
    return '$count purchases · $invested invested';
  }

  @override
  String get dpTitle => 'Debt payoff';

  @override
  String get dpMonthlyPayment => 'Monthly payment';

  @override
  String get dpAvalanche => 'Avalanche';

  @override
  String get dpSnowball => 'Snowball';

  @override
  String get dpAvalancheSub => 'Highest rate first';

  @override
  String get dpSnowballSub => 'Smallest balance first';

  @override
  String dpDebtFree(Object months) {
    return '$months mo to debt-free';
  }

  @override
  String dpInterest(Object amount) {
    return '$amount interest';
  }

  @override
  String get dpRecommended => 'Recommended';

  @override
  String dpSaves(Object amount) {
    return 'Saves $amount vs snowball';
  }

  @override
  String get dpInfeasible => 'Increase the monthly payment to cover minimums.';

  @override
  String get dpSetApr => 'Set APR';

  @override
  String get dpAprDialogTitle => 'Interest rate (APR)';

  @override
  String get dpAprLabel => 'Annual rate';

  @override
  String dpEditApr(Object name) {
    return '$name rate';
  }

  @override
  String get efTitle => 'Emergency fund';

  @override
  String get efMonthsUnit => 'months of expenses';

  @override
  String get efStatusHealthy => 'Fully funded';

  @override
  String get efStatusOnTrack => 'On track';

  @override
  String get efStatusBuilding => 'Keep building';

  @override
  String efCashLabel(Object amount) {
    return '$amount liquid cash';
  }

  @override
  String efSpendLabel(Object amount) {
    return '$amount / mo avg';
  }

  @override
  String get efScale0 => '0';

  @override
  String get efScale3 => '3 mo';

  @override
  String get efScale6 => '6 mo+';

  @override
  String get efNoSpendTitle => 'Runway not available yet';

  @override
  String get efNoSpendBody =>
      'Once you have about a month of transactions, we\'ll estimate how long your cash would last.';

  @override
  String get efNoCashHint =>
      'No liquid cash detected — link a checking or savings account to track your runway.';

  @override
  String get billsTitle => 'Upcoming recurring bills';

  @override
  String get billsNext12 => 'Projected · next 12 months';

  @override
  String get rgTitle => 'Realized gains';

  @override
  String get rgThisYear => 'This year';

  @override
  String get rgAllTime => 'All time';

  @override
  String get rgProceeds => 'Proceeds';

  @override
  String get rgCost => 'Cost';

  @override
  String get rgLongTerm => 'LT';

  @override
  String get rgShortTerm => 'ST';

  @override
  String rgMoreCount(Object count) {
    return '+$count more disposals';
  }

  @override
  String get spendByCatTitle => 'Spending by category';

  @override
  String get spendByCatEmpty => 'No spending recorded in this period yet.';

  @override
  String get spendByCatTotal => 'Total';

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
  String cfBudgetsOverAlert(int count, String amount) {
    return 'Over budget in $count — $amount over total';
  }

  @override
  String cfBudgetsNearAlert(Object count) {
    return 'Approaching budget in $count';
  }

  @override
  String cfBudgetsOverBy(Object amount) {
    return '$amount over';
  }

  @override
  String cfBudgetsLeft(Object amount) {
    return '$amount left';
  }

  @override
  String get cfBudgetsSuggest => 'Suggest';

  @override
  String get cfBudgetsSuggestTooltip =>
      'Fill in budgets from your recent average spending';

  @override
  String cfBudgetsSuggestedSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Added budgets for $count categories',
      one: 'Added a budget for $count category',
    );
    return '$_temp0';
  }

  @override
  String get cfBudgetsSuggestNone =>
      'No new suggestions — these are already budgeted, or there isn\'t enough recent spending to suggest from.';

  @override
  String get cfBudgetsSuggestDialogTitle => 'Suggested budgets';

  @override
  String cfBudgetsSuggestDialogSubtitle(int months) {
    return 'Based on your last $months months of spending. Pick the ones to add.';
  }

  @override
  String cfBudgetsSuggestAvg(String amount) {
    return 'Averages $amount/mo';
  }

  @override
  String get cfBudgetsSuggestSelectAll => 'Select all';

  @override
  String get cfBudgetsSuggestClear => 'Clear';

  @override
  String cfBudgetsSuggestApply(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Add $count',
      zero: 'Add',
    );
    return '$_temp0';
  }

  @override
  String cfBudgetsShowAll(int count) {
    return 'Show $count more';
  }

  @override
  String get cfBudgetsShowFewer => 'Show fewer';

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
  String get impAlreadyImported => 'Already imported';

  @override
  String get impCreateAccountForImport => 'New account (e.g. Banamex)';

  @override
  String get impOcrHint =>
      'Scanned or photographed statements are read with text recognition (OCR), which can take up to a minute each — this is normal, not stuck.';

  @override
  String get impCleanupTitle => 'Manage imports';

  @override
  String get impRecentImports => 'Recent imports';

  @override
  String get impNoRecentImports =>
      'No tracked imports yet. Imports you do from now on appear here and can be undone.';

  @override
  String get impUndo => 'Undo';

  @override
  String get impUndoImport => 'Undo import';

  @override
  String impUndoImportConfirm(Object count) {
    return 'Delete all $count transactions from this import?';
  }

  @override
  String get impDelete => 'Delete';

  @override
  String impDeletedN(Object count) {
    return 'Deleted $count transactions';
  }

  @override
  String get impBulkDelete => 'Clean up by account & date';

  @override
  String get impBulkDeleteHint =>
      'For imports done before this update (no batch). Removes transactions in the chosen account and date range.';

  @override
  String get impOnlyImported => 'Only imported transactions';

  @override
  String get impPreview => 'Preview';

  @override
  String impWillDelete(Object count) {
    return '$count transactions will be deleted';
  }

  @override
  String get impFrom => 'From';

  @override
  String get impTo => 'To';

  @override
  String get impTransactionsLabel => 'transactions';

  @override
  String get impCleanupFillAll => 'Pick an account and both dates';

  @override
  String get impFileWaiting => 'waiting…';

  @override
  String get impFileParsing => 'parsing…';

  @override
  String get impFileSkipped => 'skipped';

  @override
  String impFileTransactions(Object count) {
    return '$count transactions';
  }

  @override
  String impFileTooLarge(Object file, Object totalMb) {
    return '\"$file\" is $totalMb MB, over the 100 MB limit for a single file — it can\'t be split. Try exporting a shorter statement period.';
  }

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
  String get dashImportMxCsvPdf => 'Import a statement (CSV or PDF)';

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
  String dashSyncedAt(Object when) {
    return 'Synced $when';
  }

  @override
  String get dashSyncNow => 'Sync now';

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
  String get dashImportMxShort => 'Import statement';

  @override
  String get dashAddManualAccountShort => 'Add manual account';

  @override
  String get dashConnectCryptoExchanges => 'Connect crypto exchanges';

  @override
  String get dashLinkCoinbase => 'Link Coinbase';

  @override
  String get dashConnectBitso => 'Connect Bitso';

  @override
  String get dashAddAccountsTitle => 'Add accounts';

  @override
  String get dashSetupReadyPill => 'Ready';

  @override
  String get dashSetupShowDetails => 'Show details';

  @override
  String get dashSetupHideDetails => 'Hide details';

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

  @override
  String get projTitle => 'Wealth projection';

  @override
  String get projSubtitle =>
      'Project your financial future based on current assets and savings strategy.';

  @override
  String get projMonthlySavings => 'Monthly savings';

  @override
  String get projExpectedReturn => 'Expected return';

  @override
  String get projAnnualExpenses => 'Annual expenses';

  @override
  String get projSafeWithdrawalRate => 'Safe withdrawal rate';

  @override
  String get projProjectionYears => 'Projection years';

  @override
  String get projGoal => 'Goal';

  @override
  String get projClear => 'Clear';

  @override
  String projGoalHitBy(Object amount, Object year) {
    return 'Hit $amount by $year';
  }

  @override
  String get projGoalSetTarget => 'Set a target — e.g. \$1M by 2030';

  @override
  String get projSetTargetTitle => 'Set a target';

  @override
  String get projTargetNetWorth => 'Target net worth';

  @override
  String get projTargetYear => 'Target year';

  @override
  String get projNetWorthProjection => 'Net worth projection';

  @override
  String get projScenarios => 'Scenarios';

  @override
  String projYearAxisLabel(Object year) {
    return 'Yr $year';
  }

  @override
  String projTooltipYearAmount(Object amount, Object year) {
    return 'Year $year\n$amount';
  }

  @override
  String get projFiNumber => 'FI number';

  @override
  String get projProgress => 'Progress';

  @override
  String get projTowardFire => 'Toward FIRE';

  @override
  String get projYearsToFi => 'Years to FI';

  @override
  String get projEstimate => 'Estimate';

  @override
  String get projFiIncome => 'FI income';

  @override
  String get projMonthlyAtWithdrawalRate => 'Monthly @ withdrawal rate';

  @override
  String get projInflation => 'Inflation';

  @override
  String get projYearsToRetirement => 'Years to retirement';

  @override
  String get projVolatility => 'Return volatility';

  @override
  String get projExpectedReturnNominal => 'Expected return (nominal)';

  @override
  String get projRange => 'Range';

  @override
  String get projRealNote => 'All figures in today\'s dollars';

  @override
  String get projSuccessRate => 'Success rate';

  @override
  String get projSuccessRateSub => 'Chance the plan lasts the horizon';

  @override
  String get projMedian => 'Median outcome';

  @override
  String get projMedianSub => 'Most likely path (50th pct)';

  @override
  String get projCoastReached => 'Coast FIRE reached';

  @override
  String get projCoastReachedSub =>
      'Growth alone reaches your goal — you can stop contributing.';

  @override
  String projCoastNeed(Object amount) {
    return 'Coast FIRE: need $amount invested today';
  }

  @override
  String get projCoastNeedSub =>
      'Invest this much now and growth alone gets you to FI by retirement.';

  @override
  String get projBaristaFi => 'Barista FI number';

  @override
  String get projBaristaFiSub =>
      'Nest egg needed once part-time income helps cover spending';

  @override
  String get projBaristaIncome => 'Barista / pension income';

  @override
  String get projFromYourData => 'From your tracked spending';

  @override
  String get projBandLegend => '10th–90th percentile range';

  @override
  String get projHelpExpectedReturn =>
      'Gross annual return before inflation. ~7% ≈ the long-run stock-market average.';

  @override
  String get projHelpInflation =>
      'Shrinks future money to today\'s value. ~3% is the long-run average.';

  @override
  String get projHelpVolatility =>
      'How bumpy returns are — widens the shaded range of outcomes. ~13% ≈ a stock-heavy mix.';

  @override
  String get projHelpAnnualExpenses =>
      'Your target yearly spending in retirement, in today\'s dollars.';

  @override
  String get projHelpSwr =>
      'How much you withdraw from the portfolio each year in retirement. The classic \'4% rule\' implies a 25× nest egg.';

  @override
  String get projHelpBaristaIncome =>
      'Part-time work, a pension, or Social Security in retirement. Lowers the nest egg you need — this drives the Barista FI number.';

  @override
  String get projHelpTaxDrag =>
      'What taxes and fund fees take out of your return each year. ~0.5–1% is typical.';

  @override
  String get projLegendProjected => 'Projected';

  @override
  String projLegendTarget(Object flavor) {
    return '$flavor target';
  }

  @override
  String get projLegendGoal => 'Your goal';

  @override
  String get projHelpYearsToRetirement =>
      'When you stop contributing and start withdrawing — also sets the Coast FIRE target.';

  @override
  String get projGlossaryTitle => 'What do these terms mean?';

  @override
  String get projTermCoast => 'Coast FIRE';

  @override
  String get projTermBarista => 'Barista FI';

  @override
  String get projTermRange => 'The shaded range';

  @override
  String get projTermRealDollars => 'Today\'s dollars';

  @override
  String get projGlossaryFiNumberDef =>
      'The nest egg that lets you live on withdrawals indefinitely — roughly your yearly spending × 25 at a 4% withdrawal rate.';

  @override
  String get projGlossaryCoastDef =>
      'The amount that, invested today, would grow to your FI number by retirement with no more saving — reach it and you can stop contributing.';

  @override
  String get projGlossaryBaristaDef =>
      'A smaller target: part-time work or a pension covers some of your spending, so your portfolio only has to fund the rest.';

  @override
  String get projGlossarySwrDef =>
      'The share of your portfolio you withdraw each year in retirement. The well-known \'4% rule\' is the default here.';

  @override
  String get projGlossaryRangeDef =>
      'The band is a 1,000-run market simulation — the spread of good and bad luck. \'Success rate\' is how often the money lasts the whole horizon.';

  @override
  String get projGlossaryRealDef =>
      'Every figure is in today\'s dollars, so a future amount already accounts for inflation.';

  @override
  String get projFireFocusTitle => 'Which FIRE are you aiming for?';

  @override
  String get projFirePlanTitle => 'Your FIRE plan';

  @override
  String get projGoalLabel => 'Goal';

  @override
  String get projTermLifestyle => 'Lean / Standard / Fat';

  @override
  String get projGlossaryLifestyleDef =>
      'Lifestyle levels — Lean is frugal, Fat is generous, Standard ≈ your tracked spending. They set your annual expenses, which sets every target.';

  @override
  String get projFocusFull => 'Full FIRE';

  @override
  String get projFullReached =>
      'You\'ve reached your FI number — full FIRE is covered.';

  @override
  String projFullYearsAway(Object years) {
    return 'About $years years away at your current pace.';
  }

  @override
  String get projFullUnreachable =>
      'Not reachable in this horizon — raise savings or returns.';

  @override
  String projCoastTake(Object amount) {
    return 'You\'re at $amount today — close the gap and growth alone finishes the job.';
  }

  @override
  String get projBaristaPrompt =>
      'Set \'Barista / pension income\' above to see this lower target.';

  @override
  String get projSpendingLevel => 'Lifestyle';

  @override
  String get projPresetLean => 'Lean';

  @override
  String get projPresetStandard => 'Standard';

  @override
  String get projPresetFat => 'Fat';

  @override
  String get projTaxDrag => 'Tax drag';

  @override
  String get projGuardrails => 'Spending guardrails';

  @override
  String get projGuardrailsOn =>
      'Guardrails on — spending flexes with the market';

  @override
  String get projGuardrailsOff => 'Fixed spending — no adjustment in downturns';

  @override
  String get taxTitle => 'Tax planning';

  @override
  String get taxFilingSingle => 'Single';

  @override
  String get taxFilingMarried => 'Married';

  @override
  String get taxFilingHeadOfHousehold => 'Head of Household';

  @override
  String get taxCsvLaunchFailed => 'Could not launch CSV export.';

  @override
  String get taxPdfLaunchFailed => 'Could not launch PDF export.';

  @override
  String taxLoadError(Object error) {
    return 'Error loading tax data: $error';
  }

  @override
  String get taxRetry => 'Retry';

  @override
  String get taxExportCsv => 'Export CSV';

  @override
  String get taxExportPdf => 'PDF';

  @override
  String get taxTotalTaxableIncome => 'Total taxable income';

  @override
  String taxOrdinaryIncome(Object amount) {
    return 'Ordinary income: $amount';
  }

  @override
  String taxCapitalGains(Object amount) {
    return 'Capital gains: $amount';
  }

  @override
  String taxStLtBreakdown(String st, String lt) {
    return 'Short-term $st · Long-term $lt';
  }

  @override
  String get taxUsEstimatedLiability => 'US estimated liability (IRS)';

  @override
  String get taxMxEstimatedLiability => 'MX estimated liability (SAT)';

  @override
  String taxEffectiveRate(Object rate) {
    return 'Effective rate: $rate%';
  }

  @override
  String get taxTaxableEvents => 'Taxable events';

  @override
  String get taxNoEventsTitle => 'No taxable events found for this year.';

  @override
  String get taxNoEventsBody =>
      'Income, salary, interest, and investment sale transactions will appear here.';

  @override
  String get taxDisclaimer =>
      'Disclaimer: Tax estimates are approximations using 2026 IRS/SAT brackets. Consult a qualified tax professional for filing.';

  @override
  String get acctxRenameAccount => 'Rename account';

  @override
  String get acctxNickname => 'Nickname';

  @override
  String get acctxAccountFallback => 'Account';

  @override
  String acctxUpdateBalanceTitle(Object account) {
    return 'Update $account balance';
  }

  @override
  String get acctxCurrentBalance => 'Current balance';

  @override
  String get acctxAccountActions => 'Account actions';

  @override
  String get acctxUpdateBalance => 'Update balance';

  @override
  String acctxLoadError(Object error) {
    return 'Error loading transactions: $error';
  }

  @override
  String get acctxRetry => 'Retry';

  @override
  String get acctxBalanceOverTime => 'Balance over time';

  @override
  String get acctxSetLowBalanceAlert => 'Set low-balance alert';

  @override
  String get acctxEditLowBalanceAlert => 'Edit low-balance alert';

  @override
  String get acctxLowBalanceAlertTitle => 'Low-balance alert';

  @override
  String get acctxLowBalanceAlertBody =>
      'We\'ll flag this account and add a notification when its balance drops to or below this amount.';

  @override
  String get acctxThresholdLabel => 'Alert me below';

  @override
  String get acctxRemoveAlert => 'Remove alert';

  @override
  String get acctxAlertSaved => 'Low-balance alert saved';

  @override
  String get acctxAlertRemoved => 'Low-balance alert removed';

  @override
  String acctxLowBalanceBanner(Object amount) {
    return 'Balance is at or below your $amount alert';
  }

  @override
  String get acctxNoTransactionsTitle => 'No transactions yet';

  @override
  String get acctxNoTransactionsBody =>
      'Records might just be starting, or offline accounts have no history.';

  @override
  String acctxUpdateFailed(Object error) {
    return 'Failed to update transaction: $error';
  }

  @override
  String get acctxDismissBarrier => 'Dismiss';

  @override
  String get hiddenTitle => 'Hidden items';

  @override
  String hiddenRestoredMerchant(Object merchant) {
    return 'Restored \"$merchant\"';
  }

  @override
  String hiddenRestoreFailed(Object error) {
    return 'Failed to restore: $error';
  }

  @override
  String get hiddenBannerWillReappear =>
      'Since-last-login banner will reappear.';

  @override
  String hiddenFxPairRestored(Object summary) {
    return 'Restored — the detector may re-propose $summary on the next sync.';
  }

  @override
  String get hiddenIntro =>
      'Things you told Patrimonio to stop showing. Restoring a row brings it back where it normally lives.';

  @override
  String get hiddenRecurringCharges => 'Recurring charges';

  @override
  String get hiddenNoSubscriptions =>
      'No subscriptions are currently hidden. When you dismiss a row with × on the Recurring charges card it shows up here.';

  @override
  String get hiddenBanners => 'Banners';

  @override
  String get hiddenNoBanners => 'No banners are currently dismissed.';

  @override
  String get hiddenSinceLastLogin => 'Since last login';

  @override
  String hiddenHiddenForVisit(Object date) {
    return 'Hidden for the visit starting $date';
  }

  @override
  String get hiddenShowAgain => 'Show again';

  @override
  String get hiddenFxTransferPairs => 'FX-transfer pairs';

  @override
  String get hiddenNoFxPairs =>
      'No FX pairs are currently dismissed. When you unlink a detected Wise / Remitly / Xoom transfer on the Transactions tab, it lands here so the detector won\'t re-propose it.';

  @override
  String hiddenDismissedAt(Object date) {
    return 'Dismissed $date';
  }

  @override
  String get hiddenRestore => 'Restore';

  @override
  String get cbTitle => 'Connect bank';

  @override
  String get cbSetupIncompleteTitle => 'Plaid setup is incomplete.';

  @override
  String get cbSetupIncompleteBody =>
      'Set Plaid credentials and ENCRYPTION_KEY before linking real bank accounts.';

  @override
  String get cbConnectWithPlaid => 'Connect with Plaid';

  @override
  String get cbEnvSandbox => 'Plaid Sandbox Mode — Mock data only';

  @override
  String get cbEnvDevelopment =>
      'Plaid Development Mode — Real account data (test items)';

  @override
  String get cbEnvProduction => 'Plaid Production Mode — Real account data';

  @override
  String cbEnvUnknown(Object env) {
    return 'Plaid Environment: $env';
  }

  @override
  String get cbConnected => 'Bank connected. Initial sync has started.';

  @override
  String get cbExchangeTokenFailed => 'Failed to exchange token';

  @override
  String cbBackendCommError(Object error) {
    return 'Error communicating with backend: $error';
  }

  @override
  String get cbLinkTokenFailed => 'Failed to retrieve link token';

  @override
  String cbBackendConnectError(Object error) {
    return 'Error connecting to backend: $error';
  }

  @override
  String cbHttpError(Object fallback, Object status) {
    return '$fallback: HTTP $status';
  }

  @override
  String cbPlaidError(Object message) {
    return 'Plaid Error: $message';
  }

  @override
  String get pfAssetBreakdown => 'Asset breakdown';

  @override
  String get pfByType => 'By type';

  @override
  String get pfByInstitution => 'By institution';

  @override
  String get pfOther => 'Other';

  @override
  String get pfBank => 'Bank';

  @override
  String get pfNetWorthGoal => 'Net-worth goal';

  @override
  String get pfGoalDueNow => 'due now';

  @override
  String pfGoalYearsLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count years left',
      one: '1 year left',
    );
    return '$_temp0';
  }

  @override
  String pfGoalHitBy(Object amount, Object remaining, Object year) {
    return 'Hit $amount by $year · $remaining';
  }

  @override
  String pfGoalCurrent(Object amount) {
    return 'Current: $amount';
  }

  @override
  String get pfShowingBands => 'Showing per-institution bands';

  @override
  String get pfShowingLine => 'Showing only the net worth line';

  @override
  String get pfSimple => 'Simple';

  @override
  String get pfDetailed => 'Detailed';

  @override
  String pfTotalNetWorthCurrency(Object currency) {
    return 'Total net worth ($currency)';
  }

  @override
  String get pfTotalNetWorth => 'Total net worth';

  @override
  String pfTooltipNetWorth(Object value) {
    return 'Net worth: $value';
  }

  @override
  String pfTooltipAssets(Object value) {
    return 'Assets: $value';
  }

  @override
  String pfTooltipLiabilities(Object value) {
    return 'Liabilities: $value';
  }

  @override
  String pfDeltaVsAgo(Object window) {
    return 'vs $window ago';
  }

  @override
  String get pfNoAccountsYet => 'No accounts yet';

  @override
  String get pfNoAccountsBody =>
      'Link a bank, import a CSV, or add a manual account to\nget started.';

  @override
  String get pfAddAnAccount => 'Add an account';

  @override
  String get pfAccountsHeader => 'ACCOUNTS';

  @override
  String get pfSearchAccounts => 'Search accounts';

  @override
  String get pfHideZero => 'Hide \$0';

  @override
  String get pfNoAccountMatches => 'No accounts match';

  @override
  String get pfClearFilters => 'Clear filters';

  @override
  String get pfGroupCash => 'Cash';

  @override
  String get pfGroupInvestments => 'Investments';

  @override
  String get pfGroupCrypto => 'Crypto';

  @override
  String get pfGroupCreditCards => 'Credit cards';

  @override
  String get pfGroupLoans => 'Loans & mortgages';

  @override
  String get pfGroupRealAssets => 'Real assets';

  @override
  String get pfGroupOther => 'Other';

  @override
  String pfUnknownSubtypes(int count, Object list) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Unknown subtypes: $list',
      one: 'Unknown subtype: $list',
    );
    return '$_temp0';
  }

  @override
  String get pfVaults => 'Vaults';

  @override
  String get pfBase => 'base';

  @override
  String get pfAccountsDescriptor => 'Accounts';

  @override
  String pfInstDescriptor(Object descriptor, Object inst) {
    return '$inst · $descriptor';
  }

  @override
  String get pfVault => 'Vault';

  @override
  String get pfUnknownAccount => 'Unknown account';

  @override
  String get pfAccountActions => 'Account actions';

  @override
  String get pfRename => 'Rename';

  @override
  String get pfRevalue => 'Revalue';

  @override
  String get pfDelete => 'Delete';

  @override
  String get pfDeleteAccountTitle => 'Delete account';

  @override
  String pfDeleteAccountConfirm(Object name) {
    return 'Are you sure you want to delete \"$name\"? This will remove all its history.';
  }

  @override
  String pfRevalueTitle(Object name) {
    return 'Revalue $name';
  }

  @override
  String pfRevalueCurrent(Object amount, Object currency) {
    return 'Current: $amount $currency';
  }

  @override
  String get pfNewBalance => 'New balance';

  @override
  String get pfNotesOptional => 'Notes (optional)';

  @override
  String get pfNotesHint => 'e.g. Zillow estimate, 2026 appraisal, last round';

  @override
  String get pfHistoryPointNote =>
      'A new history point is recorded with today\'s date.';

  @override
  String get pfEnterNumericBalance => 'Enter a numeric balance';

  @override
  String get pfAssetFallback => 'asset';

  @override
  String get pfRenameAccountTitle => 'Rename account';

  @override
  String pfRenameOriginal(Object name) {
    return 'Original: $name';
  }

  @override
  String get pfNickname => 'Nickname';

  @override
  String get pfNicknameHint => 'e.g. Joint checking';

  @override
  String get pfRenameBlankHint => 'Leave blank to clear and use the bank name.';

  @override
  String get pfInvestmentPortfolio => 'Investment portfolio';

  @override
  String get pfTotalValue => 'Total value';

  @override
  String get pfProfitLoss => 'Profit / Loss';

  @override
  String get pfUsDollar => 'US Dollar';

  @override
  String get pfMexicanPeso => 'Mexican Peso';

  @override
  String get pfHoldings => 'Holdings';

  @override
  String pfAccountsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count accounts',
      one: '1 account',
    );
    return '$_temp0';
  }

  @override
  String get pfTopPosition => 'Top position';

  @override
  String get pfBiggestGainer => 'Biggest gainer';

  @override
  String get pfBiggestLoser => 'Biggest loser';

  @override
  String get pfSignalsTitle => 'Signals';

  @override
  String get pfConcentrated => 'Concentrated';

  @override
  String get pfViewLots => 'View lots';

  @override
  String get pfUnknown => 'Unknown';

  @override
  String pfInstPositions(Object inst, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count positions',
      one: '1 position',
    );
    return '$inst · $_temp0';
  }

  @override
  String pfSharesSuffix(Object qty) {
    return '$qty sh';
  }

  @override
  String pfCategoryFilter(Object category) {
    return 'Category: $category';
  }

  @override
  String get pfSearchHint => 'Search ticker, name, account, or institution…';

  @override
  String pfHoldingsAccountsCount(int accounts, int holdings) {
    String _temp0 = intl.Intl.pluralLogic(
      holdings,
      locale: localeName,
      other: '$holdings holdings',
      one: '1 holding',
    );
    String _temp1 = intl.Intl.pluralLogic(
      accounts,
      locale: localeName,
      other: '$accounts accounts',
      one: '1 account',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String pfShownOfTotal(Object shown, Object total) {
    return '$shown of $total';
  }

  @override
  String get pfFlat => 'Flat';

  @override
  String get pfByAccount => 'By account';

  @override
  String get pfNoHoldingsYet => 'No holdings yet';

  @override
  String get pfNoHoldingsBody =>
      'Once you link a brokerage with Plaid (or import a CSV) your\npositions will appear here.';

  @override
  String pfHoldingsShowAll(int count) {
    return 'Show all $count holdings';
  }

  @override
  String get pfHoldingsShowFewer => 'Show fewer';

  @override
  String get pfColAsset => 'Asset';

  @override
  String get pfColShares => 'Shares';

  @override
  String get pfColPrice => 'Price';

  @override
  String get pfColValue => 'Value';

  @override
  String get pfColCostBasis => 'Cost basis';

  @override
  String get pfCostBasisUnavailable =>
      'Cost basis unavailable from this institution';

  @override
  String get pfColGain => 'Gain';

  @override
  String get pfColReturn => 'Return';

  @override
  String get pfShares => 'sh';

  @override
  String get pfHolding => 'Holding';

  @override
  String pfLotBreakdownTitle(Object title) {
    return 'Lot breakdown · $title';
  }

  @override
  String get pfLotBreakdownSubtitle =>
      'FIFO order. Cost basis sums each lot at its historical USD/native FX rate, not today\'s.';

  @override
  String get pfLotAcquired => 'Acquired';

  @override
  String get pfLotQty => 'Qty';

  @override
  String get pfLotCostPerUnit => 'Cost / unit';

  @override
  String get pfLotFxAtLot => 'FX at lot';

  @override
  String get pfLotUsdCost => 'USD cost';

  @override
  String get dlgAccountTitle => 'Add manual account';

  @override
  String get dlgAccountName => 'Account name';

  @override
  String get dlgAccountNameHint => 'e.g. My savings, Rental property';

  @override
  String get dlgAccountType => 'Account type';

  @override
  String get dlgAccountClabe => 'CLABE';

  @override
  String get dlgAccountHolder => 'Account holder';

  @override
  String get dlgAccountClabeInvalid => 'CLABE must be 18 digits';

  @override
  String get acctTypeChecking => 'Checking';

  @override
  String get acctTypeSavings => 'Savings';

  @override
  String get acctTypeCD => 'Certificate of deposit';

  @override
  String get acctTypeBrokerage => 'Brokerage';

  @override
  String get acctTypeInvestment => 'Investment';

  @override
  String get acctTypeBonds => 'Bonds';

  @override
  String get acctTypeStockPlan => 'Stock plan';

  @override
  String get acctTypeIRA => 'IRA';

  @override
  String get acctType401k => '401(k)';

  @override
  String get acctTypeCrypto => 'Crypto';

  @override
  String get acctTypeRealEstate => 'Real estate';

  @override
  String get acctTypeVehicle => 'Vehicle';

  @override
  String get acctTypePrivateEquity => 'Private equity';

  @override
  String get acctTypeCollectibles => 'Collectibles';

  @override
  String get acctTypeOtherAsset => 'Other asset';

  @override
  String get acctTypeCreditCard => 'Credit card';

  @override
  String get acctTypeLoan => 'Loan';

  @override
  String get acctTypeMortgage => 'Mortgage';

  @override
  String get acctTypeOtherLiability => 'Other liability';

  @override
  String impAccountMatched(Object account) {
    return 'Matched to $account from the statement';
  }

  @override
  String get impNoAccountMatch =>
      'No existing account matches this statement — create one below.';

  @override
  String impAccountCreatedCue(Object account) {
    return 'Created $account — importing here';
  }

  @override
  String get impSummaryFound => 'Found';

  @override
  String get impSummaryInflow => 'Inflow';

  @override
  String get impSummaryOutflow => 'Outflow';

  @override
  String impSummaryFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

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
    return 'Possible missing statement: ‘$fromFile’ ends at $fromBalance ($fromDate), but ‘$toFile’ opens at $toBalance ($toDate) — an unexplained difference of $diff. A statement covering the period between them may be missing.';
  }

  @override
  String get dlgAccountCurrency => 'Currency';

  @override
  String get dlgAccountInitialBalance => 'Initial balance';

  @override
  String get dlgAccountBalanceHelper =>
      'For credit cards / loans, enter the amount owed as a positive number.';

  @override
  String get dlgAccountBalanceInvalid => 'Enter a numeric amount';

  @override
  String get dlgAccountCreate => 'Create account';

  @override
  String get dlgAccountGroupCashBanking => 'Cash & banking';

  @override
  String get dlgAccountGroupInvestments => 'Investments';

  @override
  String get dlgAccountGroupCrypto => 'Crypto';

  @override
  String get dlgAccountGroupRealAssets => 'Real assets';

  @override
  String get dlgAccountGroupLiabilities => 'Liabilities';

  @override
  String dlgAccountCreated(Object name) {
    return 'Account \"$name\" created!';
  }

  @override
  String dlgAccountCreateError(Object error) {
    return 'Could not add account: $error';
  }

  @override
  String dlgCryptoLinkTitle(Object exchange) {
    return 'Link $exchange';
  }

  @override
  String dlgCryptoIntro(Object exchange) {
    return 'Generate a \"Read-Only\" API key in $exchange settings. We only use this to fetch balances and estimate their value.';
  }

  @override
  String get dlgCryptoWhereApiKeys => 'Where do I find my API keys? ↗';

  @override
  String dlgCryptoDisplayName(Object example) {
    return 'Display Name (e.g. $example)';
  }

  @override
  String get dlgCryptoApiKey => 'API Key';

  @override
  String get dlgCryptoApiSecret => 'API Secret';

  @override
  String get dlgCryptoLinkAccount => 'Link account';

  @override
  String dlgCryptoApiKeysTitle(Object exchange) {
    return '$exchange API keys';
  }

  @override
  String dlgCryptoApiKeysFallbackBody(Object exchange) {
    return 'Generate a Read-Only API key in your $exchange settings, then paste it here. Open:';
  }

  @override
  String dlgCryptoLinkSuccess(Object exchange) {
    return 'Successfully linked $exchange!';
  }

  @override
  String dlgCryptoLinkError(Object error) {
    return 'Error linking: $error';
  }

  @override
  String get dlgTxTitle => 'Add transaction';

  @override
  String get dlgTxAdded => 'Transaction added';

  @override
  String get dlgTxNoAccounts =>
      'You need at least one account before you can add a transaction.';

  @override
  String get dlgTxAccount => 'Account';

  @override
  String get dlgTxExpense => 'Expense';

  @override
  String get dlgTxIncome => 'Income';

  @override
  String get dlgTxAmount => 'Amount';

  @override
  String get dlgTxAmountRequired => 'Enter an amount';

  @override
  String get dlgTxAmountPositive => 'Enter a positive amount';

  @override
  String get dlgTxDate => 'Date';

  @override
  String get dlgTxDescription => 'Description';

  @override
  String get dlgTxDescriptionHint => 'e.g. Coffee with Sam';

  @override
  String get dlgTxDescriptionRequired => 'Description is required';

  @override
  String get dlgTxCategory => 'Category (optional)';

  @override
  String get dlgTxCategoryHint => 'e.g. Restaurants';

  @override
  String get dlgTxNotes => 'Notes (optional)';

  @override
  String get dlgRecoveryTitle => 'Save your recovery codes';

  @override
  String get dlgRecoveryWarning =>
      'These codes will NOT be shown again. Each is single-use; use one if you lose your password.';

  @override
  String get dlgRecoveryCopied => 'Copied';

  @override
  String get dlgClabeCopied => 'CLABE copied to clipboard';

  @override
  String get dlgCopyClabe => 'Copy CLABE';

  @override
  String get dlgRecoveryCopyAll => 'Copy all';

  @override
  String get dlgRecoverySavedConfirm =>
      'I\'ve saved these codes somewhere safe';

  @override
  String get dlgRecoveryContinue => 'Continue';

  @override
  String get lwFxExchangeRate => 'Exchange rate';

  @override
  String get lwFxRefreshNow => 'Refresh rate now';

  @override
  String lwFxSource(Object source) {
    return 'Source: $source';
  }

  @override
  String get lwFxUpdatedUnknown => 'Updated: unknown';

  @override
  String lwFxStalePrefix(Object age) {
    return 'Stale · $age';
  }

  @override
  String get lwFxUpdatedJustNow => 'Updated just now';

  @override
  String lwFxUpdatedMinutesAgo(Object minutes) {
    return 'Updated ${minutes}m ago';
  }

  @override
  String lwFxUpdatedHoursAgo(Object hours) {
    return 'Updated ${hours}h ago';
  }

  @override
  String lwFxUpdatedDaysAgo(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Updated $days days ago',
      one: 'Updated $days day ago',
    );
    return '$_temp0';
  }

  @override
  String get lwSyncInstitutionsHeader => 'INSTITUTIONS';

  @override
  String lwSyncRetryFailed(Object count) {
    return 'Retry $count failed';
  }

  @override
  String get lwSyncNoInstitutions => 'No institutions linked yet';

  @override
  String get lwSyncNoInstitutionsHint =>
      'Use the buttons below to connect a bank, import a\nstatement, or add a manual account.';

  @override
  String get lwSyncNever => 'Never';

  @override
  String get lwSyncUnknownInstitution => 'Unknown';

  @override
  String get lwSyncFailedUnknownReason =>
      'Sync failed. Reason unknown — try Retry or Reconnect.';

  @override
  String get lwSyncReconnect => 'Reconnect';

  @override
  String get lwSyncRetrySync => 'Retry sync';

  @override
  String get lwSyncDeleteInstitution => 'Delete institution';

  @override
  String lwSyncVia(Object source) {
    return 'Via $source';
  }

  @override
  String get lwSyncDetailSyncingNow => 'Syncing now';

  @override
  String get lwSyncDetailSetupRequired => 'Setup required before sync';

  @override
  String get lwSyncDetailReconnectRequired => 'Reconnect required';

  @override
  String get lwSyncDetailWaitingFirstSync => 'Waiting for first sync';

  @override
  String get lwSyncDetailManualSource => 'Manual/offline source';

  @override
  String get lwSyncStaleSuffix => '(Stale)';

  @override
  String lwSyncBannerOneNeedsAttention(Object name) {
    return '$name needs attention';
  }

  @override
  String lwSyncBannerManyNeedAttention(Object count) {
    return '$count institutions need attention';
  }

  @override
  String get lwSyncBannerReconnect => 'Reconnect';

  @override
  String lwSyncBannerReconnectName(Object name) {
    return 'Reconnect $name';
  }

  @override
  String lwSyncBannerReconnectCount(Object count) {
    return 'Reconnect $count…';
  }

  @override
  String get lwSyncBannerOpenSettings => 'Open settings';

  @override
  String lwSinceNewTransactions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count new transactions',
      one: '$count new transaction',
    );
    return '$_temp0';
  }

  @override
  String lwSinceLargestMove(Object account, Object amount) {
    return '$amount on $account';
  }

  @override
  String lwSinceSyncErrors(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sync errors',
      one: '$count sync error',
    );
    return '$_temp0';
  }

  @override
  String get lwSinceLastVisit => 'Since your last visit';

  @override
  String lwSinceDate(Object date) {
    return 'Since $date';
  }

  @override
  String get lwSinceViewAction => 'View';

  @override
  String get lwSinceFixAction => 'Fix';

  @override
  String get lwSinceDismiss => 'Dismiss';

  @override
  String get lwNotifBorrowerFallback => 'Borrower';

  @override
  String get lwNotifInstitutionFallback => 'Institution';

  @override
  String get lwNotifAccountFallback => 'Account';

  @override
  String lwNotifLowBalanceTitle(Object account) {
    return '$account is running low';
  }

  @override
  String lwNotifLowBalanceDetail(Object balance, Object threshold) {
    return 'Balance $balance is at or below your $threshold alert.';
  }

  @override
  String lwNotifRepaymentOverdueTitle(Object borrower) {
    return '$borrower repayment overdue';
  }

  @override
  String lwNotifRepaymentOverdueDetail(
    Object amount,
    Object daysOverdue,
    Object dueDate,
    Object number,
  ) {
    return 'Installment #$number of $amount was due $dueDate (${daysOverdue}d ago).';
  }

  @override
  String lwNotifRepaymentDueTitle(Object borrower, Object days) {
    return '$borrower repayment due in ${days}d';
  }

  @override
  String lwNotifRepaymentDueDetail(
    Object amount,
    Object dueDate,
    Object number,
  ) {
    return 'Installment #$number of $amount due $dueDate.';
  }

  @override
  String lwNotifNeedsReconnectTitle(Object name) {
    return '$name needs reconnect';
  }

  @override
  String get lwNotifNeedsReconnectDetail =>
      'Plaid token expired — reconnect to resume sync.';

  @override
  String lwNotifSyncFailedTitle(Object name) {
    return '$name sync failed';
  }

  @override
  String get lwNotifUnknownSyncError => 'Unknown sync error';

  @override
  String lwNotifStaleSyncTitle(Object days, Object name) {
    return '$name last synced ${days}d ago';
  }

  @override
  String get lwNotifStaleSyncDetail =>
      'Trigger a sync to pull in transactions and balance updates.';

  @override
  String lwNotifNetWorthDropTitle(Object pct) {
    return 'Net worth dropped $pct in 30 days';
  }

  @override
  String lwNotifNetWorthDropDetail(Object latest, Object reference) {
    return 'Latest $latest vs $reference.';
  }

  @override
  String lwNotifSpendingUpTitle(String category, String pct) {
    return '$category up $pct';
  }

  @override
  String lwNotifSpendingUpDetail(int months, String avg) {
    return 'vs your $months-month average of $avg';
  }

  @override
  String lwNotifSubPriceUpTitle(String merchant) {
    return '$merchant price increased';
  }

  @override
  String lwNotifSubPriceUpDetail(String newAmount, String oldAmount) {
    return 'Now $newAmount, was $oldAmount';
  }

  @override
  String get lwNotifTooltipNone => 'Notifications';

  @override
  String lwNotifTooltipCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alerts',
      one: '$count alert',
    );
    return '$_temp0';
  }

  @override
  String get lwNotifAllClear => 'All clear';

  @override
  String get lwNotifNoAlerts => 'No alerts right now.';

  @override
  String get lwPaletteSearchHint =>
      'Search accounts, holdings, transactions, or jump to a tab…';

  @override
  String get lwPaletteNoMatches => 'No matches.';

  @override
  String get lwPaletteHintNavigate => 'navigate';

  @override
  String get lwPaletteHintSelect => 'select';

  @override
  String get lwPaletteHintClose => 'close';

  @override
  String get lwTrendsTitle => 'Cash flow trends';

  @override
  String get lwTrendsIncome => 'Income';

  @override
  String get lwTrendsSpending => 'Spending';

  @override
  String get lwTrendsTapToView => 'Tap to view transactions';

  @override
  String get lwTrendsInfoTooltip =>
      'Internal transfers (between your accounts) and credit-card bill payments are excluded so the bars reflect actual external income and spending.';

  @override
  String get lwTrendsSemanticNoData => 'Cash flow trends chart, no data';

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
          'Cash flow trends, $count months. Latest $month: income $income, spending $spending.',
      one:
          'Cash flow trends, $count month. Latest $month: income $income, spending $spending.',
    );
    return '$_temp0';
  }

  @override
  String lwTrendsSemanticMonth(Object income, Object month, Object spending) {
    return '$month: income $income, spending $spending';
  }

  @override
  String get lwAllocTitle => 'Asset distribution';

  @override
  String lwAllocTotal(Object amount) {
    return 'Total: $amount';
  }

  @override
  String get lwAllocOtherCategory => 'Other';

  @override
  String lwAllocHoldingsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count holdings',
      one: '$count holding',
    );
    return '$_temp0';
  }

  @override
  String lwAllocSharesSuffix(Object qty) {
    return '$qty sh';
  }

  @override
  String lwAllocShowMore(int count) {
    return 'Show $count more';
  }

  @override
  String get lwAllocShowFewer => 'Show fewer';

  @override
  String get lwAllocDimClass => 'Asset class';

  @override
  String get lwAllocDimType => 'Account type';

  @override
  String get lwAllocDimInstitution => 'Institution';

  @override
  String lwAllocConcentration(String holding, String pct) {
    return '$holding is $pct of your portfolio — a concentrated position.';
  }

  @override
  String get lwAllocFilteringHint =>
      'Filtering holdings to this category — tap again to clear';

  @override
  String lwAllocSemanticLabel(Object category, Object pct, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$category, $pct of portfolio, $count holdings',
      one: '$category, $pct of portfolio, $count holding',
    );
    return '$_temp0';
  }

  @override
  String get lwRangeOneMonth => '1M';

  @override
  String get lwRangeYearToDate => 'YTD';

  @override
  String get lwRangeOneYear => '1Y';

  @override
  String get lwRangeFiveYears => '5Y';

  @override
  String get lwRangeAll => 'ALL';

  @override
  String get lwPerfTitle => 'Performance';

  @override
  String get lwPerfValueSubtitle =>
      'Investment value over time (includes contributions)';

  @override
  String get lwPerfNotEnough =>
      'Not enough history yet to chart your portfolio value over time.';

  @override
  String get lwPerfTwrReturn => 'Time-weighted return';

  @override
  String get lwPerfTwrYou => 'Your portfolio';

  @override
  String get lwPerfTwrSp => 'S&P 500';

  @override
  String lwPerfTwrCoverage(Object pct) {
    return 'Reflects $pct of your portfolio we can price daily';
  }
}
