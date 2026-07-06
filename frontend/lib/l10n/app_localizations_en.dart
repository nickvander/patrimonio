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
  String lendViewInstallments(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'View $count installment$_temp0';
  }

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
  String get txDeletedOne => 'Transaction deleted';

  @override
  String get txDeleteOneFailed => 'Couldn\'t delete the transaction';

  @override
  String get txDeleteSomeFailed => 'Couldn\'t delete some transactions';

  @override
  String get txUndo => 'Undo';

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
  String get txFilterLoadingHistory =>
      'Loading your full history so every option is available…';

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
  String get txExportCsvFiltered =>
      'Export CSV — exports the transactions matching your current filter';

  @override
  String get txExportNoRows =>
      'Nothing to export — no transactions match the current filter.';

  @override
  String get txExportAllTitle => 'Export all transactions?';

  @override
  String get txExportAllBody =>
      'Filters and search don\'t apply to the CSV export — it will include your entire transaction history.';

  @override
  String get txExportAllConfirm => 'Export all';

  @override
  String get txSortBy => 'Sort by';

  @override
  String get txSortDateNewest => 'Date (newest first)';

  @override
  String get txSortDateOldest => 'Date (oldest first)';

  @override
  String get txSortAmountHigh => 'Amount (largest first)';

  @override
  String get txSortAmountLow => 'Amount (smallest first)';

  @override
  String get txSortMerchant => 'Merchant (A–Z)';

  @override
  String get txScanTransfers =>
      'Scan for cross-currency transfers (Wise / Remitly / etc.)';

  @override
  String get txMoreActions => 'More actions';

  @override
  String get txDetails => 'Details';

  @override
  String get txMoreDetails => 'More details';

  @override
  String get txDate => 'Date';

  @override
  String get txAccount => 'Account';

  @override
  String get txAutoCategory => 'Auto-category';

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
  String txBalanceAfter(Object amount) {
    return 'Bal. $amount';
  }

  @override
  String get txBalanceAfterTooltip => 'Balance after this transaction';

  @override
  String get txBalanceAfterEstimatedTooltip => 'Estimated from current balance';

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
  String get secAccountSection => 'Account';

  @override
  String get secAccountNoEmail => 'No email on file';

  @override
  String get secPasswordSection => 'Password';

  @override
  String get secChangePassword => 'Change password';

  @override
  String get secChangePasswordSubtitle => 'Sign out of every other session.';

  @override
  String get secSetPasswordWithPasskey => 'Set a new password (with passkey)';

  @override
  String get secSetPasswordWithPasskeySubtitle =>
      'Use your passkey instead of your current password.';

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
  String get secSetPasswordWithPasskeyTitle => 'Set a new password';

  @override
  String get secSetPasswordWithPasskeyBody =>
      'Your passkey verified you. Choose a new password — you won\'t need your old one.';

  @override
  String get secSetPasswordButton => 'Set password';

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
  String get cfPeriodLabel => 'Period';

  @override
  String get cfPeriodThisMonth => 'This month';

  @override
  String get cfPeriodLastMonth => 'Last month';

  @override
  String get cfPeriod3Months => 'Last 3 months';

  @override
  String get cfPeriodYtd => 'Year to date';

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
      'Money-weighted, all time — if your contributions had bought the index on each purchase date';

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
  String get dpSimulator => 'Payoff simulator';

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
  String get spendByCatAvgPerMonth => 'Average per month';

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
  String get ovDetailsTitle => 'Details';

  @override
  String get ovDetailsSubtitle => 'Stats, goal & emergency fund';

  @override
  String get mgmtConnectionsTitle => 'Connections & sync';

  @override
  String get mgmtConnectionsSubtitle => 'Banks, sync status & exchange rate';

  @override
  String get dashSyncingAll => 'Syncing all institutions…';

  @override
  String dashSyncingProgress(int done, int total) {
    return 'Updating… ($done of $total)';
  }

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
  String get dashSearchCommandsTooltip => 'Search & commands (⌘K)';

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
  String get projAdvancedAssumptions => 'Advanced assumptions';

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
  String taxIncomeDecomposition(
    String wages,
    String dividends,
    String interest,
  ) {
    return 'Wages $wages · Dividends $dividends · Interest $interest';
  }

  @override
  String taxMxWithheld(String withheld, String net) {
    return 'ISR already withheld $withheld · est. remaining $net';
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
  String taxDisclaimer(String bracketYear) {
    return 'Disclaimer: Tax estimates are approximations using $bracketYear IRS/SAT brackets. Consult a qualified tax professional for filing.';
  }

  @override
  String get taxConstantsUnverified =>
      'Estimates — tax constants pending verification';

  @override
  String get taxFilingStatusLabel => 'Filing status';

  @override
  String get taxYearLabel => 'Tax year';

  @override
  String get taxRealizedGainsTitle => 'Realized gains';

  @override
  String get taxIncomeSectionTitle => 'Income';

  @override
  String get taxTermShort => 'Short';

  @override
  String get taxTermLong => 'Long';

  @override
  String get taxTermUnknown => 'Unknown';

  @override
  String get taxColProceeds => 'Proceeds';

  @override
  String get taxColCost => 'Cost';

  @override
  String get taxAcquiredUnknown => 'Acquired —';

  @override
  String taxAcquiredToSold(String acquired, String sold) {
    return '$acquired → $sold';
  }

  @override
  String get taxTaxAdvantagedBadge => 'Tax-advantaged';

  @override
  String get taxTaxAdvantagedSection =>
      'Tax-advantaged accounts (excluded from taxable totals)';

  @override
  String get taxTaxAdvantagedNote =>
      'Disposals inside 401(k)/IRA/HSA-type accounts. Not part of the taxable headline above.';

  @override
  String taxGainsSubtotal(String amount) {
    return 'Net realized gain: $amount';
  }

  @override
  String taxIncomeSubtotal(String amount) {
    return 'Total income: $amount';
  }

  @override
  String taxSubtotalReconcileNote(String kpi) {
    return 'Matches the $kpi card above.';
  }

  @override
  String get taxNoDisposals => 'No realized disposals for this year.';

  @override
  String get taxScenarioUsSubtitle => 'If all income were taxed in the US';

  @override
  String get taxScenarioMxSubtitle => 'If all income were taxed in Mexico';

  @override
  String get taxScenarioUsCaveat =>
      'Federal only — excludes NIIT and state tax, no foreign tax credit.';

  @override
  String get taxScenarioMxCaveat =>
      'Everything run through the salary ISR tarifa (a simplification).';

  @override
  String get taxScenariosNote =>
      'These are two alternative scenarios over the same income, not amounts you add together.';

  @override
  String get taxRoughEstimateBadge => 'Rough estimate';

  @override
  String get taxRoughEstimateTooltip =>
      'No purchase lots on record — gains use a blended cost-basis guess.';

  @override
  String get taxAssumptionsTitle => 'Assumptions';

  @override
  String taxAssumptionBracketYear(String year) {
    return 'Bracket year: $year';
  }

  @override
  String get taxAssumptionFx =>
      'FX: each row converted at its own date\'s stored USD/MXN rate.';

  @override
  String taxAssumptionFilingStatus(String status) {
    return 'Filing status: $status';
  }

  @override
  String get taxAssumptionExclusions =>
      'Excludes tax-advantaged accounts (401(k)/IRA/HSA).';

  @override
  String taxAssumptionHoldingsNoBasis(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count holdings have no cost basis on record',
      one: '1 holding has no cost basis on record',
    );
    return '$_temp0';
  }

  @override
  String get taxAssumptionProReview =>
      'Wording and constants are pending review by a tax professional — treat as guidance, not advice.';

  @override
  String get taxUnrealizedTitle => 'Unrealized positions — what if I sell';

  @override
  String get taxUnrealizedShortTerm => 'Short-term lots';

  @override
  String get taxUnrealizedLongTerm => 'Long-term lots';

  @override
  String get taxNoUnrealizedLots => 'No taxable lots to evaluate.';

  @override
  String taxUnrealizedSubtotal(String amount) {
    return 'Unrealized: $amount';
  }

  @override
  String taxFlipsToLongIn(String days, String date) {
    return 'Long-term in ${days}d — $date';
  }

  @override
  String get taxColBasis => 'Basis';

  @override
  String get taxColValue => 'Value';

  @override
  String get taxHarvestTitle => 'Harvest candidates';

  @override
  String taxHarvestEstimate(String amount) {
    return 'Est. tax saving $amount';
  }

  @override
  String get taxHarvestEstimateBadge => 'Estimate';

  @override
  String get taxHarvestEstimateTooltip =>
      'Loss × your marginal rate — an estimate on unverified constants, not a guaranteed saving.';

  @override
  String get taxHarvestNote =>
      'Selling these losers could offset gains. Estimated saving = loss × your marginal rate.';

  @override
  String get taxNoHarvestCandidates => 'No loss lots to harvest right now.';

  @override
  String get taxWashSaleMarker => 'Wash sale';

  @override
  String taxWashSaleSafeAfter(String date) {
    return 'Safe to re-buy after $date';
  }

  @override
  String get taxWashSaleTooltip =>
      'A same-security buy near this date can disallow the loss. Re-buying after the safe date avoids the wash-sale rule.';

  @override
  String get taxFbarTitle => 'Foreign accounts — FBAR monitor';

  @override
  String get taxFbarPeakAggregate =>
      'Peak aggregate foreign balance (this year)';

  @override
  String taxFbarThreshold(String amount) {
    return 'FBAR reporting threshold: $amount';
  }

  @override
  String get taxFbarExceeded => 'Aggregate exceeded the threshold this year';

  @override
  String get taxFbarUnder => 'Aggregate stayed under the threshold this year';

  @override
  String taxFbarPeakDate(String date) {
    return 'Peak on $date';
  }

  @override
  String get taxFbarInformational =>
      'Informational only — this does not decide an FBAR filing obligation. Consult a tax professional.';

  @override
  String get taxFbarFatcaNote =>
      'FATCA Form 8938 thresholds are different and higher, and are not computed here.';

  @override
  String get taxFbarNoForeignAccounts =>
      'No foreign accounts detected for this year.';

  @override
  String taxFbarAccountPeak(String amount) {
    return 'On peak date: $amount';
  }

  @override
  String taxFbarAccountYtdMax(String amount) {
    return 'Own YTD max: $amount';
  }

  @override
  String get taxRetirementTitle => 'Retirement contributions';

  @override
  String get taxRetirementGroup401k => '401(k) / 403(b) / 457(b)';

  @override
  String get taxRetirementGroupIra => 'IRA (Traditional + Roth)';

  @override
  String get taxRetirementGroupHsa => 'HSA';

  @override
  String taxContributedOfLimit(String ytd, String limit) {
    return '$ytd of $limit';
  }

  @override
  String get taxBackdoorRothBadge => 'Backdoor Roth';

  @override
  String taxMegaBackdoorNote(String elective, String room) {
    return '§415(c) total (elective + employer + after-tax); elective limit $elective. $room mega-backdoor Roth room left.';
  }

  @override
  String get taxHsaFamilyCoverage => 'Family coverage';

  @override
  String taxHsaEmployerNote(String amount) {
    return 'includes $amount employer';
  }

  @override
  String get tax401kElectiveSet => '+ Set your elective deferral to split this';

  @override
  String tax401kElectiveSplit(String elective, String limit, String rest) {
    return 'Elective $elective of $limit · employer + after-tax $rest';
  }

  @override
  String get tax401kElectiveDialogTitle => 'Annual 401k elective deferral';

  @override
  String tax401kElectiveDialogHint(String limit) {
    return 'Your employee contribution (pre-tax + Roth); limit $limit';
  }

  @override
  String taxRemainingRoom(String amount) {
    return 'Room left: $amount';
  }

  @override
  String taxContributionDeadline(String date) {
    return 'Deadline: $date';
  }

  @override
  String get taxPriorYearWindowNote =>
      'Prior-year contributions allowed until this deadline.';

  @override
  String get taxMatchRolloverCaveat =>
      'May include employer match or rollovers — personal contributions could be overcounted.';

  @override
  String get taxContributionOverLimit => 'Over the base limit';

  @override
  String taxCatchUpNote(String amount) {
    return '+$amount catch-up if age-eligible';
  }

  @override
  String get taxNoRetirementAccounts =>
      'No retirement accounts with contributions this year.';

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
  String get hiddenClosedAccounts => 'Closed accounts';

  @override
  String get hiddenClosedAccountsIntro =>
      'Accounts Patrimonio archived because they were closed or removed at the bank. They no longer count toward your net worth. Restore one to bring it back, or delete it permanently.';

  @override
  String get hiddenNoClosedAccounts =>
      'No closed accounts. When a bank reports an account as closed, it lands here instead of disappearing.';

  @override
  String get accountRestore => 'Restore';

  @override
  String accountRestored(String name) {
    return 'Restored \"$name\"';
  }

  @override
  String get accountDeletePermanently => 'Delete permanently';

  @override
  String get accountDeleteConfirmTitle => 'Delete account permanently?';

  @override
  String accountDeleteConfirmBody(String name) {
    return 'This permanently deletes \"$name\" and all of its transactions. This can\'t be undone.';
  }

  @override
  String accountDeleted(String name) {
    return 'Deleted \"$name\"';
  }

  @override
  String accountClosedOn(Object date) {
    return 'Closed $date';
  }

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
  String get pfCards => 'Cards';

  @override
  String get pfBase => 'base';

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
  String pfHoldingsAccountsCount(int holdings, int accounts) {
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
  String get impCoverageTitle => 'Statement coverage';

  @override
  String impCoverageThrough(String month) {
    return 'through $month';
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
      other: '$count imports',
      one: '1 import',
    );
    return '$_temp0';
  }

  @override
  String get impCoverageMaybeDue => 'A newer statement may be available';

  @override
  String get impCoverageEmpty => 'No statements imported yet';

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
  String lwNotifRepaymentDueTodayTitle(Object borrower) {
    return '$borrower repayment due today';
  }

  @override
  String lwNotifRepaymentDueTodayDetail(Object amount, Object number) {
    return 'Installment #$number of $amount is due today.';
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
  String lwNotifNetWorthUpTitle(String amount, String pct) {
    return 'Net worth up $amount ($pct)';
  }

  @override
  String lwNotifNetWorthDownTitle(String amount, String pct) {
    return 'Net worth down $amount ($pct)';
  }

  @override
  String lwNotifNetWorthSinceSyncDetail(String date) {
    return 'Since your last sync · $date';
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
  String lwNotifAccountArchivedTitle(String institution) {
    return 'Account closed: $institution';
  }

  @override
  String lwNotifAccountArchivedDetail(String account, String institution) {
    return '$account is no longer at $institution — it\'s been archived. Tap to restore or remove.';
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
  String get lwNotifHeader => 'Notifications';

  @override
  String get lwNotifMarkAllRead => 'Mark all read';

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
  String get lwPerfTwrMethodNote =>
      'Time-weighted return over the selected period';

  @override
  String lwPerfTwrCoverage(Object pct) {
    return 'Reflects $pct of your portfolio we can price daily';
  }

  @override
  String get heroDeltaSince30d => 'vs 30d ago';

  @override
  String get ovByCurrency => 'By currency';

  @override
  String get lendingGlanceTitle => 'Lending';

  @override
  String get lendingGlanceOutstanding => 'Outstanding';

  @override
  String lendingGlanceActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count active loans',
      one: '1 active loan',
    );
    return '$_temp0';
  }

  @override
  String get lendingGlanceNextDue => 'Next due';

  @override
  String lendingGlanceDueIn(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'due in $days days',
      one: 'due in 1 day',
    );
    return '$_temp0';
  }

  @override
  String get lendingGlanceDueToday => 'due today';

  @override
  String lendingGlanceOverdueBy(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'overdue by $days days',
      one: 'overdue by 1 day',
    );
    return '$_temp0';
  }

  @override
  String get pfGoalPaceAhead => 'Ahead of pace';

  @override
  String get pfGoalPaceOnTrack => 'On track';

  @override
  String get pfGoalPaceBehind => 'Behind pace';

  @override
  String get mgmtArchivedTitle => 'Auto-archived accounts';

  @override
  String get mgmtArchivedIntro =>
      'Accounts the sync closed at the bank. Restore one to bring it back into your net worth.';

  @override
  String get mgmtArchivedManageAll => 'Manage all hidden items';

  @override
  String get lendingInterest => 'Interest';

  @override
  String get lendingInterestEarnedLabel => 'Interest earned';

  @override
  String get lendingAccruedNotYetPaid => 'Accrued (not yet paid)';

  @override
  String get lendingAgingTitle => 'Due & overdue';

  @override
  String get lendingAgingOverdue30 => '30+ days overdue';

  @override
  String get lendingAgingOverdue7 => '7-29 days overdue';

  @override
  String get lendingAgingOverdue1 => '1-6 days overdue';

  @override
  String get lendingAgingDueToday => 'Due today';

  @override
  String get lendingAgingDueSoon => 'Due soon';

  @override
  String lendingAgingDaysOverdue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days overdue',
      one: '1 day overdue',
    );
    return '$_temp0';
  }

  @override
  String lendingAgingDaysUntil(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'in $count days',
      one: 'in 1 day',
    );
    return '$_temp0';
  }

  @override
  String get pfTopMoversByValue => 'Top movers (by \$)';

  @override
  String get pfTopGainersByValue => 'Top gainers';

  @override
  String get pfTopLosersByValue => 'Top losers';

  @override
  String get pfLotCurrentValue => 'Current value';

  @override
  String get pfLotTerm => 'Term';

  @override
  String get pfLotLongTerm => 'Long-term';

  @override
  String get pfLotShortTerm => 'Short-term';

  @override
  String get pfFlatCostBasis => 'Cost basis';

  @override
  String get pfLotsUnavailable => 'No cost-basis detail available';

  @override
  String get pfLotsUnavailableTooltip =>
      'This institution did not report acquisition dates, so a per-lot breakdown isn\'t available.';

  @override
  String get pfViewCostBasis => 'View cost basis';

  @override
  String get taxHarvestMarginalRate =>
      'Marginal rate used for harvest estimates';

  @override
  String get taxHarvestMarginalOrdinary => 'Ordinary (short-term)';

  @override
  String get taxHarvestMarginalLtcg => 'LTCG (long-term)';

  @override
  String get projShowNominal => 'Show nominal amounts';

  @override
  String get projNominalNote => 'Future (nominal) dollars';

  @override
  String projFisherHelp(String nominal, String inflation, String real) {
    return '$nominal% nominal − $inflation% inflation ≈ $real% real (Fisher relation)';
  }

  @override
  String get lwSyncBadgeSuccess => 'Synced';

  @override
  String get lwSyncBadgeSyncing => 'Syncing';

  @override
  String get lwSyncBadgeError => 'Errors';

  @override
  String get lwSyncBadgeReconnect => 'Reconnect';

  @override
  String get lwSyncBadgeStale => 'Stale';

  @override
  String get lwSyncFilterProblems => 'Needs attention';

  @override
  String get lwSyncNoProblems => 'Everything is up to date';

  @override
  String pfReturnCoverage(String covered, String total) {
    return 'on $covered of $total with known cost basis';
  }

  @override
  String get taxFbarNoData =>
      'No foreign-account balance history found for this year.';

  @override
  String projNominalHorizonCaption(int years) {
    return 'in $years-yr dollars';
  }

  @override
  String get statInvestmentsCashSleeveNote =>
      'Includes uninvested cash inside brokerage accounts, so this differs from the Portfolio total (sum of holdings).';

  @override
  String get dashFxStaleLabel => 'approx.';

  @override
  String get dashFxStaleTooltip =>
      'Approximate — the exchange rate is stale (missing or over 7 days old), so this conversion may be off.';

  @override
  String get lwFxEnterManually => 'Enter rate manually';

  @override
  String get lwFxManualDialogTitle => 'Enter exchange rate';

  @override
  String lwFxManualDialogHint(Object base, Object target) {
    return 'Set a manual $base/$target rate. This overrides the automatic rate until the next refresh.';
  }

  @override
  String get lwFxManualInvalid => 'Enter a valid rate greater than zero';

  @override
  String get lwFxManualSaved => 'Manual exchange rate saved';

  @override
  String lwFxManualFailed(Object error) {
    return 'Could not save rate: $error';
  }

  @override
  String get taxHeadroomTitle => 'Headroom';

  @override
  String get taxHeadroomSubtitle => 'Room before the next US tax step';

  @override
  String taxHeadroomOrdinaryRoom(Object amount, Object rate) {
    return 'Room in current bracket: $amount before $rate%';
  }

  @override
  String taxHeadroomOrdinaryRoomTop(Object amount) {
    return 'Room in current bracket: $amount';
  }

  @override
  String taxHeadroomLtcg0Room(Object amount) {
    return 'LTCG 0% room: $amount tax-free';
  }

  @override
  String taxHeadroomLtcg15Room(Object amount, Object rate) {
    return 'LTCG 15% room: $amount before $rate%';
  }

  @override
  String get txFilteredNet => 'Net';

  @override
  String txFilteredOutflow(Object amount) {
    return 'Out $amount';
  }

  @override
  String txFilteredInflow(Object amount) {
    return 'In $amount';
  }

  @override
  String statDrilldownApprox(Object amount) {
    return '≈ $amount';
  }

  @override
  String get cfBudgetsPacingToExceed => 'On track to exceed';

  @override
  String cfBudgetsPacingAlert(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count categories are on track to exceed their budgets',
      one: '1 category is on track to exceed its budget',
    );
    return '$_temp0';
  }

  @override
  String pfGoalOnPaceFor(Object rate, Object when) {
    return 'on pace for ~$when at +$rate/mo';
  }

  @override
  String pfGoalNeedPerMonth(Object amount) {
    return 'need $amount/mo to hit goal year';
  }

  @override
  String get lendingInterestIncomeTitle => 'Interest income';

  @override
  String get lendingInterestIncomeLoadError =>
      'Couldn\'t load interest income. Try again.';

  @override
  String get lendingInterestIncomeRetry => 'Retry';

  @override
  String get lendingInterestIncomeAllTime => 'All time';

  @override
  String get lendingInterestIncomeEmpty =>
      'No interest received in this period yet.';

  @override
  String get lendingInterestIncomeTotalsByCurrency => 'Totals by currency';

  @override
  String get lendingInterestIncomeInterestReceived => 'Interest received';

  @override
  String get lendingInterestIncomePrincipalReceived => 'Principal received';

  @override
  String get lendingInterestIncomePaymentsCount => 'Payments';

  @override
  String get lendingInterestIncomeByMonth => 'Interest by month';

  @override
  String get lendingInterestIncomeByLoan => 'By loan';

  @override
  String get lendingInterestIncomeBorrower => 'Borrower';

  @override
  String get lendingInterestIncomeBelowMarketTitle =>
      '§7872 below-market loans';

  @override
  String get lendingInterestIncomeBelowMarketBody =>
      'These active 0%-rate loans exceed the \$10,000 gift-loan threshold, so the IRS may impute interest under §7872. Informational only — confirm with an accountant.';

  @override
  String cfSavingsRate(Object rate) {
    return '$rate saved';
  }

  @override
  String get cfPtsAbbrev => 'pts';

  @override
  String taxHarvestFooterTotal(Object count) {
    return 'Total harvestable loss ($count lots)';
  }

  @override
  String taxHarvestFooterSavings(Object amount) {
    return 'Est. total savings $amount';
  }

  @override
  String taxHarvestFooterFlow(
    Object carryforward,
    Object gains,
    Object ordinary,
  ) {
    return '$gains taxable gains remain, $ordinary offset against income, $carryforward carried forward';
  }

  @override
  String taxHarvestFooterCarryforward(Object amount) {
    return '$amount loss carries forward to next year';
  }

  @override
  String get lwPerfBenchSp500 => 'S&P 500';

  @override
  String get lwPerfBenchNdx => 'Nasdaq-100';

  @override
  String get lwPerfBenchAcwi => 'World (ACWI)';

  @override
  String get lwPerfBenchAgg => 'US Bonds';

  @override
  String get lwPerfBenchMxx => 'IPC Mexico';

  @override
  String get lwPerfBenchPickerTooltip => 'Benchmark';

  @override
  String get lendingDueOverdue => 'Overdue';

  @override
  String lendingDueOn(Object date) {
    return 'Due $date';
  }

  @override
  String get lendingDuePaidAhead => 'Paid ahead';

  @override
  String get lendingInterestOwedSoFar => 'Interest owed so far';

  @override
  String get dashDataExportTitle => 'Data export';

  @override
  String get dashDataExportSubtitle =>
      'Download your transactions and tax reports. Files download directly in your browser.';

  @override
  String get dashExportTransactionsCsv => 'All transactions (CSV)';

  @override
  String get dashExportTaxCsv => 'Tax report (CSV)';

  @override
  String get dashExportTaxPdf => 'Tax report (PDF)';

  @override
  String get dashImportedBatchesTitle => 'Imported batches';

  @override
  String get dashImportedBatchesSubtitle =>
      'Review or undo past statement imports';

  @override
  String get divCardTitle => 'Dividend income';

  @override
  String get divProjectedAnnual => 'Projected annual';

  @override
  String get divBlendedYield => 'Blended yield';

  @override
  String get divTopPayers => 'Top payers';

  @override
  String get divUpcomingExDates => 'Upcoming ex-dates';

  @override
  String divPaymentsPerYear(Object count) {
    return '$count×/yr';
  }

  @override
  String get divFxStaleHint =>
      'Some income converted with a stale FX rate — figures are approximate.';

  @override
  String get lendCustomStyleLabel => 'Custom schedule';

  @override
  String get lendCustomStyleDesc =>
      'You set every payment by hand — irregular amounts and dates that add up to the amount lent.';

  @override
  String get lendCustomPasteTitle => 'Paste from a spreadsheet';

  @override
  String get lendCustomPasteHint =>
      'Paste two columns from Google Sheets / Excel: date then amount, one payment per line.';

  @override
  String get lendCustomPasteButton => 'Parse pasted rows';

  @override
  String lendCustomPastedN(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 's',
      one: '',
    );
    return 'Loaded $count payment$_temp0 from the paste.';
  }

  @override
  String get lendCustomPasteEmpty =>
      'Nothing to parse — paste some date + amount rows first.';

  @override
  String get lendCustomRowsTitle => 'Payments';

  @override
  String get lendCustomAddRow => 'Add payment';

  @override
  String get lendCustomRemoveRow => 'Remove payment';

  @override
  String get lendCustomRowDate => 'Date';

  @override
  String get lendCustomRowAmount => 'Amount';

  @override
  String get lendCustomNoRows =>
      'No payments yet — paste from a spreadsheet or add them below.';

  @override
  String get lendCustomGeneratorTitle => 'Quick fill';

  @override
  String get lendCustomGenFirstN => 'First payments';

  @override
  String get lendCustomGenFirstAmount => 'First amount';

  @override
  String get lendCustomGenThenAmount => 'Then each';

  @override
  String get lendCustomGenDayOfMonth => 'Day of month';

  @override
  String get lendCustomGenStart => 'Start';

  @override
  String get lendCustomGenEnd => 'End';

  @override
  String get lendCustomGenApply => 'Fill payments';

  @override
  String lendCustomPreviewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count payments',
      one: '1 payment',
    );
    return '$_temp0';
  }

  @override
  String get lendCustomPreviewSum => 'Sum of payments';

  @override
  String get lendCustomClosesToZero =>
      'Closes to 0 — the payments add up to the amount lent.';

  @override
  String lendCustomDoesNotAddUp(String sum, String principal) {
    return 'Payments total $sum, but the amount lent is $principal.';
  }

  @override
  String get lendCustomNeedRows => 'Add at least one payment before saving.';

  @override
  String lendCustomScheduleFailed(String error) {
    return 'Couldn\'t save the schedule: $error';
  }

  @override
  String get lendDisbursementConflict =>
      'That transaction already funds another loan — the loan wasn\'t created.';

  @override
  String get lendCopyForSheets => 'Copy for Google Sheets';

  @override
  String get lendCopiedForSheets =>
      'Copied — paste into the sheet with Ctrl/Cmd+V.';

  @override
  String lendSchedulePaidProgress(int paid, int total) {
    return 'Paid $paid of $total payments';
  }

  @override
  String lendScheduleRemaining(String amount) {
    return '$amount remaining';
  }

  @override
  String get lendScheduleColPayment => 'Payment';

  @override
  String get lendScheduleColBalance => 'Balance remaining';

  @override
  String get lendScheduleColStatus => 'Status';

  @override
  String get lendScheduleNextDue => 'Next due';

  @override
  String get lendScheduleTotals => 'Total';

  @override
  String get txCreateLoanFromTx => 'Create loan from this transaction';

  @override
  String get lendDisbursementNotLinkedOptional =>
      'no disbursement linked (optional)';

  @override
  String get lendLoadError => 'Couldn\'t load loans. Pull to retry.';

  @override
  String get lendRetry => 'Retry';

  @override
  String get lendExportInterestTooltip => 'Export interest income';

  @override
  String get lendExportPaymentsCsv => 'Interest payments (CSV)';

  @override
  String get lendExportYearEndCsv => 'Year-end summary by borrower (CSV)';

  @override
  String lendTotalsConvertedNote(String currency) {
    return 'Totals converted to $currency at the current spot rate';
  }

  @override
  String get lendUnknownBorrower => 'Unknown';

  @override
  String get lendStatusActive => 'Active';

  @override
  String get lendStatusPaidOff => 'Paid off';

  @override
  String get lendStatusWrittenOff => 'Written off';

  @override
  String get lendStatusDefaulted => 'Defaulted';

  @override
  String get lendStatusCancelled => 'Cancelled';

  @override
  String lendLentMeta(String amount, String date) {
    return 'Lent $amount · $date';
  }

  @override
  String lendLentOutstandingMeta(String principal, String outstanding) {
    return 'Lent $principal · outstanding $outstanding';
  }

  @override
  String get lendRatePeriodYear => 'Year';

  @override
  String get lendRatePeriodMonth => 'Month';

  @override
  String get lendFreqLumpSum => 'Lump sum';

  @override
  String get lendInterestTypeNone => 'No interest';

  @override
  String get lendInterestTypeSimple => 'Simple interest';

  @override
  String get lendInterestTypeAmortized => 'Amortized';

  @override
  String get lendInterestTypeInterestOnly => 'Interest-only';

  @override
  String get lendInterestTypeCompound => 'Compound';

  @override
  String get lendAddLoanSubtitle => 'Record money you lent and track repayment';

  @override
  String get lendEditLoanTitle => 'Edit loan';

  @override
  String get lendEditLoanSubtitle =>
      'Correct the borrower, amount, or interest terms';

  @override
  String get lendFieldBorrowerName => 'Borrower name';

  @override
  String get lendFieldAmountLent => 'Amount lent';

  @override
  String get lendFieldCurrency => 'Currency';

  @override
  String get lendFieldLentOn => 'Lent on';

  @override
  String get lendFieldInterestRate => 'Interest rate';

  @override
  String get lendFieldOptional => 'Optional';

  @override
  String get lendFieldTermMonths => 'Term (months)';

  @override
  String get lendFieldMostTheyCanPay => 'Most they can pay';

  @override
  String get lendFieldRateIsPer => 'Rate is per';

  @override
  String get lendFieldPaymentFrequency => 'Payment frequency';

  @override
  String get lendFieldPayBackBy => 'Pay back by';

  @override
  String get lendFieldInterestType => 'Interest type';

  @override
  String get lendFieldAmountReceived => 'Amount received';

  @override
  String get lendFieldReceivedOn => 'Received on';

  @override
  String get lendSegSetTheTerm => 'Set the term';

  @override
  String get lendSegSetThePayment => 'Set the payment';

  @override
  String get lendSegBankTransaction => 'Bank transaction';

  @override
  String get lendSegCash => 'Cash';

  @override
  String get lendAdvancedOptions => 'Advanced options';

  @override
  String get lendPreviewTitle => 'Loan preview';

  @override
  String get lendPreviewEstimate => 'estimate';

  @override
  String get lendPreviewEnterAmount => 'Enter an amount to see the projection';

  @override
  String get lendPreviewTotalToRepay => 'Total to repay';

  @override
  String get lendPreviewProjectedInterest => 'Projected interest';

  @override
  String get lendPreviewNoInterest => 'No interest on this loan';

  @override
  String get lendPreviewOpenEnded =>
      'Open-ended — repay anytime, no fixed schedule';

  @override
  String get lendPreviewMinimumPayment => 'Minimum payment';

  @override
  String get lendPreviewPaidOffIn => 'Paid off in';

  @override
  String lendPreviewPaidOffValue(int count, String term) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count payments',
      one: '1 payment',
    );
    return '$_temp0  ·  $term';
  }

  @override
  String lendTermMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count months',
      one: '1 month',
    );
    return '$_temp0';
  }

  @override
  String lendTermYearsAbbrev(String years) {
    return '~$years yr';
  }

  @override
  String get lendSaveChanges => 'Save changes';

  @override
  String get lendDisbursementLinked => 'Linked to a bank transaction';

  @override
  String get lendWhichTxFunded => 'Which transaction funded this loan?';

  @override
  String get lendLinkATransaction => 'Link a transaction';

  @override
  String get lendNoneRecordedYet => 'None recorded yet.';

  @override
  String get lendSuggestedRepayments => 'Suggested repayments';

  @override
  String get lendRecordAPayment => 'Record a payment';

  @override
  String get lendConfirm => 'Confirm';

  @override
  String get lendExportPrintablePlan => 'Printable plan (PDF)';

  @override
  String get lendExportDownloadCsv => 'Download CSV (Google Sheets / Excel)';

  @override
  String get lendActionEdit => 'Edit';

  @override
  String get lendActionAgreement => 'Agreement';

  @override
  String get lendActionPayOffInFull => 'Pay off in full';

  @override
  String get lendActionMarkDefaulted => 'Mark defaulted';

  @override
  String get lendActionWriteOff => 'Write off';

  @override
  String get lendActionReactivate => 'Reactivate';

  @override
  String get lendPayoffConfirmTitle => 'Pay off in full?';

  @override
  String get lendPayoffConfirmButton => 'Pay off';

  @override
  String get lendDeleteLoan => 'Delete loan';

  @override
  String get lendDeleteLoanTitle => 'Delete loan?';

  @override
  String get lendTooltipClearDate => 'Clear date';

  @override
  String get lendTooltipUnlink => 'Unlink';

  @override
  String get lendTooltipExportPaymentPlan => 'Export payment plan';

  @override
  String get lendToastEnterBorrowerName => 'Enter a borrower name';

  @override
  String get lendToastEnterValidAmount => 'Enter a valid amount';

  @override
  String get lendToastFailedToAddLoan => 'Failed to add loan';

  @override
  String get lendToastCouldntSaveChanges => 'Couldn\'t save changes';

  @override
  String get lendToastScheduleGenerated => 'Schedule generated';

  @override
  String get lendToastLoanUpdated => 'Loan updated';

  @override
  String get lendToastCouldntUpdateStatus => 'Couldn\'t update status';

  @override
  String get lendToastLoanPaidOff => 'Loan paid off';

  @override
  String get lendToastCouldntLinkTx => 'Couldn\'t link that transaction';

  @override
  String get lendToastCouldntRecordRepayment =>
      'Couldn\'t record that repayment';

  @override
  String get lendToastCouldntUnlink => 'Couldn\'t unlink';

  @override
  String get lendToastCouldntDeleteLoan => 'Couldn\'t delete loan';

  @override
  String get lendToastRecordCashPayment => 'Record cash payment';

  @override
  String get lendToastCouldntRecordCashPayment =>
      'Couldn\'t record cash payment';

  @override
  String get lendSectionBorrowerAmount => 'Borrower & amount';

  @override
  String get lendSectionHowLoanWorks => 'How the loan works';

  @override
  String get lendSectionExpectedRepayment => 'Expected repayment';

  @override
  String get lendSectionNotes => 'Notes';

  @override
  String get lendSectionInterestTerms => 'Interest terms';

  @override
  String get lendSectionDisbursement => 'Disbursement';

  @override
  String get lendSectionRepayments => 'Repayments';

  @override
  String get lendSectionPaymentSchedule => 'Payment schedule';

  @override
  String get lendStyleNoInterestDesc =>
      'They pay back exactly what they borrowed.';

  @override
  String get lendStyleStandardLabel => 'Standard loan';

  @override
  String get lendStyleStandardDesc =>
      'Equal payments over time; each covers interest plus a bit of principal.';

  @override
  String get lendStyleFlatLabel => 'Flat interest';

  @override
  String get lendStyleFlatDesc =>
      'Interest figured once on the full amount, split evenly across payments.';

  @override
  String get lendStyleInterestOnlyLabel => 'Interest-only + balloon';

  @override
  String get lendStyleInterestOnlyDesc =>
      'They pay just interest each period, then the whole amount at the end.';

  @override
  String get lendStylePayAtEndLabel => 'Pay all at the end';

  @override
  String get lendStylePayAtEndDesc =>
      'Nothing\'s due until the end; interest builds up until then.';

  @override
  String get lendPreviewSinglePayment => 'Single payment';

  @override
  String get lendPreviewPayment => 'Payment';

  @override
  String lendPreviewPerPaymentInterest(
    String amount,
    String cadence,
    int count,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count payments',
      one: '1 payment',
    );
    return '$amount$cadence interest  ·  $_temp0';
  }

  @override
  String lendPreviewPerPaymentCount(String amount, String cadence, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count payments',
      one: '1 payment',
    );
    return '$amount$cadence  ·  $_temp0';
  }

  @override
  String get lendPreviewPrincipalAtMaturity => 'Principal at maturity';

  @override
  String lendPreviewDueWithFinalPayment(String amount) {
    return '$amount  ·  due with final payment';
  }

  @override
  String get lendPreviewEnterPaymentSolve =>
      'Enter a payment to see how long it takes';

  @override
  String get lendToastEnterPaymentCompute =>
      'Enter a payment to compute the term';

  @override
  String lendEditRatePerPeriod(String period) {
    String _temp0 = intl.Intl.selectLogic(period, {
      'monthly': 'Rate % per month',
      'other': 'Rate % per year',
    });
    return '$_temp0';
  }

  @override
  String lendTermsSummaryTermMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count-month term',
      one: '1-month term',
    );
    return '$_temp0';
  }

  @override
  String get lendTermsSummaryMonthlyPayments => 'monthly payments';

  @override
  String get lendTermsSummaryWeeklyPayments => 'weekly payments';

  @override
  String get lendTermsSummaryLumpSumPayment => 'single lump-sum payment';

  @override
  String lendTermsSummaryFixed(String parts) {
    return 'Term & schedule ($parts) are fixed — delete and re-add to change them.';
  }

  @override
  String get lendNoMatchingOutflow =>
      'No matching outflow found near the loan date — pick one manually below.';

  @override
  String get lendScheduleGenerate => 'Generate';

  @override
  String get lendScheduleRegenerate => 'Regenerate';

  @override
  String get lendScheduleEmptyHasTerms =>
      'No schedule yet. Generate one to see the amortization plan (principal + interest per installment).';

  @override
  String get lendScheduleEmptyNoTerms =>
      'This loan has no term / payment frequency, so there\'s no fixed schedule — record repayments as they come in.';

  @override
  String lendPayBackByWhen(String date, String when) {
    return 'Pay back by $date · $when';
  }

  @override
  String get lendToastUnreconcileFirst =>
      'Unreconcile payments first to regenerate';

  @override
  String get lendToastCouldntGenerateSchedule => 'Couldn\'t generate schedule';

  @override
  String get lendPayoffConfirmBody =>
      'Marks the loan as paid off and clears any remaining scheduled installments. This does not create a repayment — link the actual final transaction from the Repayments list so interest income stays accurate.';

  @override
  String get lendToastLoanNoLongerActive => 'Loan is no longer active';

  @override
  String get lendToastCouldntPayOff => 'Couldn\'t pay off loan';

  @override
  String get lendDeleteLoanBody =>
      'This removes the loan and its repayment records. The bank transactions themselves are not deleted.';

  @override
  String get lendSheetRecordPayment => 'Record a payment';

  @override
  String get lendSheetLinkDisbursement => 'Link the disbursement';

  @override
  String get lendSearchInflows => 'Search inflows (money received)';

  @override
  String get lendSearchOutflows => 'Search outflows (money sent)';

  @override
  String get lendNoIncomingTx =>
      'No incoming transactions found. Try the Cash tab to record an off-bank repayment.';

  @override
  String get lendNoOutgoingTx => 'No outgoing transactions found.';

  @override
  String get lendCashFormHint =>
      'Record a repayment that didn\'t come through a linked bank account (e.g. cash). It reduces the outstanding balance but isn\'t tied to a transaction.';

  @override
  String get lendToastTxAlreadyLinked => 'That transaction is already linked';

  @override
  String get lendToastCouldntRecordThat => 'Couldn\'t record that';

  @override
  String get lendLinkBankTx => 'Link bank transaction';

  @override
  String get lendLinkBankTxTitle => 'Link a bank transaction';

  @override
  String get lendLinkBankTxNone =>
      'No matching bank transactions found yet — upload your bank statement first.';

  @override
  String get lendLinkBankTxError => 'Couldn\'t link that bank transaction';

  @override
  String pfFilterNoMatches(Object filter) {
    return 'No holdings match \"$filter\"';
  }

  @override
  String get pfFilterClear => 'Clear filter';

  @override
  String pfFilterShownOfTotal(int shown, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$total holdings',
      one: '1 holding',
    );
    return '$shown of $_temp0';
  }

  @override
  String get pfFilterAssetEquity => 'Stocks & funds';

  @override
  String get pfFilterAssetBonds => 'Bonds';

  @override
  String get pfFilterAssetCash => 'Cash';

  @override
  String get pfFilterAssetCrypto => 'Crypto';

  @override
  String get pfFilterAssetRealEstate => 'Real estate';

  @override
  String get pfFilterAssetCommodities => 'Commodities';

  @override
  String get pfFilterAssetOther => 'Other';

  @override
  String pfDivShowAllPayers(int count) {
    return 'Show all ($count)';
  }

  @override
  String get pfDivShowFewerPayers => 'Show fewer';

  @override
  String get pfDivLoadError => 'Couldn\'t load dividend income';

  @override
  String get pfDivRetry => 'Retry';

  @override
  String get pfDivDetailFreqMonthly => 'Monthly';

  @override
  String get pfDivDetailFreqQuarterly => 'Quarterly';

  @override
  String get pfDivDetailFreqSemiAnnual => 'Semi-annual';

  @override
  String get pfDivDetailFreqAnnual => 'Annual';

  @override
  String get pfDivDetailSubtitle =>
      'Estimated from the recent payment history — actual dates and amounts may vary.';

  @override
  String get pfDivDetailShares => 'Shares';

  @override
  String get pfDivDetailMarketValue => 'Market value';

  @override
  String get pfDivDetailRatePerShare => 'Rate / share (annual)';

  @override
  String get pfDivDetailPerPayment => 'Per payment';

  @override
  String get pfDivDetailAnnualIncome => 'Annual income';

  @override
  String get pfDivDetailYield => 'Yield';

  @override
  String get pfDivDetailYieldOnCost => 'Yield on cost';

  @override
  String get pfDivDetailLastExDate => 'Last ex-date';

  @override
  String get pfDivDetailNextExDate => 'Est. next ex-date';

  @override
  String get pfDivDetailSchedule => 'Next 12 months';

  @override
  String get pfDivDetailHistory => 'Payment history';

  @override
  String get pfDivDetailPerShare => 'per share';

  @override
  String get pfDivDetailAccounts => 'Held in';

  @override
  String get pfDivDetailTaxAdvantaged => 'Tax-advantaged';

  @override
  String get pfDivDetailNoHistory => 'No dividend history for this symbol yet.';

  @override
  String get pfDivDetailLoadError => 'Couldn\'t load dividend details';

  @override
  String rgShowAll(int count) {
    return 'Show all ($count)';
  }

  @override
  String get rgShowFewer => 'Show fewer';

  @override
  String rgYearTile(String year) {
    return '$year';
  }

  @override
  String get rgEmpty => 'No realized gains yet';

  @override
  String get rgLoadError => 'Couldn\'t load realized gains';

  @override
  String get rgRetry => 'Retry';

  @override
  String acctDeleteHoldingTitle(String symbol) {
    return 'Delete $symbol?';
  }

  @override
  String get acctDeleteHoldingBody =>
      'This permanently deletes the holding, all of its purchase lots, and its realized-gain (tax) records. This cannot be undone.';

  @override
  String get acctDeleteHoldingConfirm => 'Delete permanently';

  @override
  String get allocTapToFilterHint => 'Tap a band to filter the holdings table';

  @override
  String allocActiveFilter(String label) {
    return 'Filtered: $label';
  }

  @override
  String get allocClearFilter => 'Clear filter';

  @override
  String allocBandSemanticsHoldings(String label, String value, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count holdings',
      one: '$count holding',
    );
    return '$label, $value, $_temp0';
  }

  @override
  String allocBandSemanticsAccounts(String label, String value, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count accounts',
      one: '$count account',
    );
    return '$label, $value, $_temp0';
  }

  @override
  String allocBandSemanticsNoCount(String label, String value) {
    return '$label, $value';
  }

  @override
  String get allocBandFiltersTable => 'filters the holdings table';

  @override
  String get insLoadError => 'Couldn\'t load instrument details';

  @override
  String insAsOf(String date) {
    return 'as of $date';
  }

  @override
  String get insRange1m => '1M';

  @override
  String get insRange3m => '3M';

  @override
  String get insRange1y => '1Y';

  @override
  String get insRangeMax => 'Max';

  @override
  String get insNoPriceHistory => 'No price history for this holding';

  @override
  String get insStatMarketValue => 'Market value';

  @override
  String get insStatQuantity => 'Quantity';

  @override
  String get insStatCostBasis => 'Cost basis';

  @override
  String get insStatGain => 'Gain';

  @override
  String get insStatWeight => 'Portfolio weight';

  @override
  String get insStatAssetClass => 'Asset class';

  @override
  String get insLotsSection => 'Purchase lots';

  @override
  String insLotQtyAtPrice(String qty, String price) {
    return '$qty shares @ $price';
  }

  @override
  String get insLotsTotal => 'Total';

  @override
  String get insDividendsLink => 'Dividend details';

  @override
  String get insDivPaymentsSection => 'Payments received';

  @override
  String insDivShowAllPayments(int count) {
    return 'Show all ($count)';
  }

  @override
  String get insDivShowFewerPayments => 'Show fewer';

  @override
  String get rgxAllYears => 'All';

  @override
  String rgxNoSalesInYear(String year) {
    return 'No sales in $year';
  }

  @override
  String get rgxTaxAdvBadge => 'Tax-adv.';

  @override
  String get rgxTaxAdvTooltip => 'Roth/IRA/401k/HSA — not taxable';

  @override
  String get rgxTaxableCaptionPrefix => 'Taxable';

  @override
  String rgxTaxableCaptionSuffix(String total) {
    return 'of $total — the rest is inside tax-advantaged accounts';
  }

  @override
  String get rgxExportCsvTooltip => 'Export CSV';

  @override
  String get rgxPerfPortfolioValue => 'Portfolio value';

  @override
  String pfDayPillToday(String change) {
    return '$change today';
  }

  @override
  String pfDayPillTooltip(String date, String coverage) {
    return 'As of $date close · covers $coverage% of portfolio value';
  }

  @override
  String get pfDayColHeader => 'Day';

  @override
  String get pfDayUnavailable => 'No recent closing price for this holding';

  @override
  String pfDaySemPayerRow(String symbol, String income) {
    return '$symbol, $income per year, opens dividend details';
  }

  @override
  String pfDaySemExDateRow(String symbol, String date, String amount) {
    return '$symbol, estimated ex-date $date, expected $amount';
  }

  @override
  String pfDaySemPositionsSubtotal(int count, String amount) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count positions',
      one: '1 position',
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
    return '$symbol, $qty shares, $value, $ret return';
  }

  @override
  String get pfCsvExportTooltip => 'Export CSV';

  @override
  String get pfCsvHoldings => 'Holdings (CSV)';

  @override
  String get pfCsvLots => 'Purchase lots (CSV)';

  @override
  String get ovwOpensAccountDetails => 'Opens account details';

  @override
  String ovwEndingIn(String digits) {
    return 'ending in $digits';
  }

  @override
  String ovwAccountActionsFor(String name) {
    return 'Account actions for $name';
  }

  @override
  String get alloc2UnclassifiedBand => 'Unclassified (account balance)';

  @override
  String get alloc2UnclassifiedTooltip =>
      'Account balance without holdings detail — open the account to see it';
}
