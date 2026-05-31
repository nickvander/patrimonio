import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Patrimonio'**
  String get appTitle;

  /// No description provided for @navOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get navOverview;

  /// No description provided for @navPortfolio.
  ///
  /// In en, this message translates to:
  /// **'Portfolio'**
  String get navPortfolio;

  /// No description provided for @navTransactions.
  ///
  /// In en, this message translates to:
  /// **'Transactions'**
  String get navTransactions;

  /// No description provided for @navCashFlow.
  ///
  /// In en, this message translates to:
  /// **'Cash flow'**
  String get navCashFlow;

  /// No description provided for @navProjections.
  ///
  /// In en, this message translates to:
  /// **'Projections'**
  String get navProjections;

  /// No description provided for @navTaxPlanning.
  ///
  /// In en, this message translates to:
  /// **'Tax planning'**
  String get navTaxPlanning;

  /// No description provided for @navLending.
  ///
  /// In en, this message translates to:
  /// **'Lending'**
  String get navLending;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navShortOverview.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navShortOverview;

  /// No description provided for @navShortPortfolio.
  ///
  /// In en, this message translates to:
  /// **'Invest'**
  String get navShortPortfolio;

  /// No description provided for @navShortTransactions.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get navShortTransactions;

  /// No description provided for @navShortCashFlow.
  ///
  /// In en, this message translates to:
  /// **'Cash'**
  String get navShortCashFlow;

  /// No description provided for @navShortProjections.
  ///
  /// In en, this message translates to:
  /// **'Proj.'**
  String get navShortProjections;

  /// No description provided for @navShortTaxPlanning.
  ///
  /// In en, this message translates to:
  /// **'Tax'**
  String get navShortTaxPlanning;

  /// No description provided for @navShortLending.
  ///
  /// In en, this message translates to:
  /// **'Loans'**
  String get navShortLending;

  /// No description provided for @navShortSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navShortSettings;

  /// No description provided for @navMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get navMore;

  /// No description provided for @navMoreGroup.
  ///
  /// In en, this message translates to:
  /// **'MORE'**
  String get navMoreGroup;

  /// No description provided for @actionAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get actionAdd;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get actionApply;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @commonRequired.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get commonRequired;

  /// No description provided for @searchTransactionsHint.
  ///
  /// In en, this message translates to:
  /// **'Search transactions…'**
  String get searchTransactionsHint;

  /// No description provided for @languageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageLabel;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get languageSpanish;

  /// Tooltip on the reporting-currency toggle button
  ///
  /// In en, this message translates to:
  /// **'Reporting in {code} · tap to swap'**
  String currencyToggleTooltip(String code);

  /// No description provided for @authSignInToContinue.
  ///
  /// In en, this message translates to:
  /// **'Sign in to continue'**
  String get authSignInToContinue;

  /// No description provided for @authUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get authUsername;

  /// No description provided for @authPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPassword;

  /// No description provided for @authSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authSignIn;

  /// No description provided for @authSignInWithPasskey.
  ///
  /// In en, this message translates to:
  /// **'Sign in with passkey'**
  String get authSignInWithPasskey;

  /// No description provided for @authForgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get authForgotPassword;

  /// No description provided for @authEnterUsernameFirst.
  ///
  /// In en, this message translates to:
  /// **'Enter your username first.'**
  String get authEnterUsernameFirst;

  /// No description provided for @statNetWorth.
  ///
  /// In en, this message translates to:
  /// **'Net worth'**
  String get statNetWorth;

  /// No description provided for @statAssets.
  ///
  /// In en, this message translates to:
  /// **'Assets'**
  String get statAssets;

  /// No description provided for @statLiabilities.
  ///
  /// In en, this message translates to:
  /// **'Liabilities'**
  String get statLiabilities;

  /// No description provided for @statCash.
  ///
  /// In en, this message translates to:
  /// **'Cash'**
  String get statCash;

  /// No description provided for @statInvestments.
  ///
  /// In en, this message translates to:
  /// **'Investments'**
  String get statInvestments;

  /// No description provided for @lendingTitle.
  ///
  /// In en, this message translates to:
  /// **'Money I\'ve lent'**
  String get lendingTitle;

  /// No description provided for @lendingAddLoan.
  ///
  /// In en, this message translates to:
  /// **'Add loan'**
  String get lendingAddLoan;

  /// No description provided for @lendingOutstanding.
  ///
  /// In en, this message translates to:
  /// **'Outstanding'**
  String get lendingOutstanding;

  /// No description provided for @lendingTotalLent.
  ///
  /// In en, this message translates to:
  /// **'Total lent'**
  String get lendingTotalLent;

  /// No description provided for @lendingActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get lendingActive;

  /// No description provided for @lendingInterestEarned.
  ///
  /// In en, this message translates to:
  /// **'Interest earned'**
  String get lendingInterestEarned;

  /// No description provided for @lendingRepaid.
  ///
  /// In en, this message translates to:
  /// **'Repaid'**
  String get lendingRepaid;

  /// No description provided for @lendingNoLoans.
  ///
  /// In en, this message translates to:
  /// **'No loans yet'**
  String get lendingNoLoans;

  /// No description provided for @lendingEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Lent money to a friend? Add it here, then designate the bank transactions that funded it and paid it back.'**
  String get lendingEmptySubtitle;

  /// No description provided for @txOverrideCleared.
  ///
  /// In en, this message translates to:
  /// **'Override cleared'**
  String get txOverrideCleared;

  /// No description provided for @txRenamed.
  ///
  /// In en, this message translates to:
  /// **'Renamed'**
  String get txRenamed;

  /// No description provided for @txRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed: {error}'**
  String txRenameFailed(Object error);

  /// No description provided for @txRenameFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Rename failed'**
  String get txRenameFailedShort;

  /// No description provided for @txFlowExpense.
  ///
  /// In en, this message translates to:
  /// **'Expense'**
  String get txFlowExpense;

  /// No description provided for @txFlowIncome.
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get txFlowIncome;

  /// No description provided for @txFlowAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get txFlowAll;

  /// No description provided for @txFlow.
  ///
  /// In en, this message translates to:
  /// **'Flow'**
  String get txFlow;

  /// No description provided for @txStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get txStatusPending;

  /// No description provided for @txStatusSettled.
  ///
  /// In en, this message translates to:
  /// **'Settled'**
  String get txStatusSettled;

  /// No description provided for @txStatusAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get txStatusAll;

  /// No description provided for @txStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get txStatus;

  /// No description provided for @txClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get txClearAll;

  /// No description provided for @txEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No transactions yet'**
  String get txEmptyTitle;

  /// No description provided for @txEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Link a bank, import a statement, or add an account manually\nto start seeing activity here.'**
  String get txEmptyBody;

  /// No description provided for @txAddAccount.
  ///
  /// In en, this message translates to:
  /// **'Add an account'**
  String get txAddAccount;

  /// No description provided for @txShowingCount.
  ///
  /// In en, this message translates to:
  /// **'Showing {shown} of {total}'**
  String txShowingCount(Object shown, Object total);

  /// No description provided for @txLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get txLoadMore;

  /// No description provided for @txSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get txSelectAll;

  /// No description provided for @txDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get txDeselectAll;

  /// No description provided for @txSetCategory.
  ///
  /// In en, this message translates to:
  /// **'Set category'**
  String get txSetCategory;

  /// No description provided for @txMoveAccount.
  ///
  /// In en, this message translates to:
  /// **'Move account'**
  String get txMoveAccount;

  /// No description provided for @txRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get txRename;

  /// No description provided for @txClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get txClear;

  /// No description provided for @txSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String txSelectedCount(Object count);

  /// No description provided for @txCategoryHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Restaurants'**
  String get txCategoryHint;

  /// No description provided for @txRenameNTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename {count} transactions'**
  String txRenameNTitle(Object count);

  /// No description provided for @txNewDescription.
  ///
  /// In en, this message translates to:
  /// **'New description'**
  String get txNewDescription;

  /// No description provided for @txRenameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Rent — March'**
  String get txRenameHint;

  /// No description provided for @txDeleteNTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} transactions?'**
  String txDeleteNTitle(Object count);

  /// No description provided for @txBulkDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'They\'ll be removed from your lists and totals. A future sync may re-import bank-linked transactions.'**
  String get txBulkDeleteBody;

  /// No description provided for @txDeletingN.
  ///
  /// In en, this message translates to:
  /// **'Deleting {count} transactions…'**
  String txDeletingN(Object count);

  /// No description provided for @txDeletedN.
  ///
  /// In en, this message translates to:
  /// **'Deleted {count} transactions'**
  String txDeletedN(Object count);

  /// No description provided for @txDeleteSomeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete some transactions'**
  String get txDeleteSomeFailed;

  /// No description provided for @txMoveToAccount.
  ///
  /// In en, this message translates to:
  /// **'Move to account'**
  String get txMoveToAccount;

  /// No description provided for @txSplitIntoN.
  ///
  /// In en, this message translates to:
  /// **'Split into {count} parts'**
  String txSplitIntoN(Object count);

  /// No description provided for @txSplitFailed.
  ///
  /// In en, this message translates to:
  /// **'Split failed: {error}'**
  String txSplitFailed(Object error);

  /// No description provided for @txSplitChildrenNotFound.
  ///
  /// In en, this message translates to:
  /// **'Could not find split children to edit.'**
  String get txSplitChildrenNotFound;

  /// No description provided for @txSplitUpdatedN.
  ///
  /// In en, this message translates to:
  /// **'Split updated ({count} parts)'**
  String txSplitUpdatedN(Object count);

  /// No description provided for @txEditSplitFailed.
  ///
  /// In en, this message translates to:
  /// **'Edit split failed: {error}'**
  String txEditSplitFailed(Object error);

  /// No description provided for @txRenameTransaction.
  ///
  /// In en, this message translates to:
  /// **'Rename transaction'**
  String get txRenameTransaction;

  /// No description provided for @txRenameDisplayLabelHelp.
  ///
  /// In en, this message translates to:
  /// **'Display label only. The original bank description is preserved and remains visible in this row\'s detail panel under \"Raw bank text\".'**
  String get txRenameDisplayLabelHelp;

  /// No description provided for @txDisplayLabel.
  ///
  /// In en, this message translates to:
  /// **'Display label'**
  String get txDisplayLabel;

  /// No description provided for @txDisplayLabelHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Rent — John'**
  String get txDisplayLabelHint;

  /// No description provided for @txAlsoApplyToN.
  ///
  /// In en, this message translates to:
  /// **'Also apply to {count} matching transactions'**
  String txAlsoApplyToN(Object count);

  /// No description provided for @txAlsoApplySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Rows that share this raw bank description.'**
  String get txAlsoApplySubtitle;

  /// No description provided for @txClearOverride.
  ///
  /// In en, this message translates to:
  /// **'Clear override'**
  String get txClearOverride;

  /// No description provided for @txRenamedN.
  ///
  /// In en, this message translates to:
  /// **'Renamed {count} transactions'**
  String txRenamedN(Object count);

  /// No description provided for @txRenamedNFailed.
  ///
  /// In en, this message translates to:
  /// **'Renamed {ok} · {failed} failed'**
  String txRenamedNFailed(Object failed, Object ok);

  /// No description provided for @txUpdatingN.
  ///
  /// In en, this message translates to:
  /// **'Updating {count} transactions…'**
  String txUpdatingN(Object count);

  /// No description provided for @txUpdatedN.
  ///
  /// In en, this message translates to:
  /// **'Updated {count} transactions'**
  String txUpdatedN(Object count);

  /// No description provided for @txUpdatedNFailed.
  ///
  /// In en, this message translates to:
  /// **'Updated {ok} · {failed} failed'**
  String txUpdatedNFailed(Object failed, Object ok);

  /// No description provided for @txCloseSearch.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get txCloseSearch;

  /// No description provided for @txRecentTransactions.
  ///
  /// In en, this message translates to:
  /// **'Recent transactions'**
  String get txRecentTransactions;

  /// No description provided for @txFilterTransactions.
  ///
  /// In en, this message translates to:
  /// **'Filter transactions'**
  String get txFilterTransactions;

  /// No description provided for @txExitSelectionMode.
  ///
  /// In en, this message translates to:
  /// **'Exit selection mode'**
  String get txExitSelectionMode;

  /// No description provided for @txSelectMultiple.
  ///
  /// In en, this message translates to:
  /// **'Select multiple'**
  String get txSelectMultiple;

  /// No description provided for @txAddTransaction.
  ///
  /// In en, this message translates to:
  /// **'Add transaction'**
  String get txAddTransaction;

  /// No description provided for @txExportCsv.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get txExportCsv;

  /// No description provided for @txScanTransfers.
  ///
  /// In en, this message translates to:
  /// **'Scan for cross-currency transfers (Wise / Remitly / etc.)'**
  String get txScanTransfers;

  /// No description provided for @txSearchTransactions.
  ///
  /// In en, this message translates to:
  /// **'Search transactions'**
  String get txSearchTransactions;

  /// No description provided for @txDateToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get txDateToday;

  /// No description provided for @txDateYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get txDateYesterday;

  /// No description provided for @txInlineEditHint.
  ///
  /// In en, this message translates to:
  /// **'New label · Enter to save'**
  String get txInlineEditHint;

  /// No description provided for @txSplitPill.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get txSplitPill;

  /// No description provided for @txDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get txDismiss;

  /// No description provided for @txRenamePlusMatching.
  ///
  /// In en, this message translates to:
  /// **'Rename (+{count} matching)'**
  String txRenamePlusMatching(Object count);

  /// No description provided for @txOutflow.
  ///
  /// In en, this message translates to:
  /// **'OUTFLOW'**
  String get txOutflow;

  /// No description provided for @txInflow.
  ///
  /// In en, this message translates to:
  /// **'INFLOW'**
  String get txInflow;

  /// No description provided for @txApproxEstimated.
  ///
  /// In en, this message translates to:
  /// **'≈ {amount} (estimated)'**
  String txApproxEstimated(Object amount);

  /// No description provided for @txRawBankText.
  ///
  /// In en, this message translates to:
  /// **'Raw bank text'**
  String get txRawBankText;

  /// No description provided for @txCategoryAndNotes.
  ///
  /// In en, this message translates to:
  /// **'Category & notes'**
  String get txCategoryAndNotes;

  /// No description provided for @txCategory.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get txCategory;

  /// No description provided for @txCategoryExample.
  ///
  /// In en, this message translates to:
  /// **'e.g. {category}'**
  String txCategoryExample(Object category);

  /// No description provided for @txNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get txNotes;

  /// No description provided for @txNotesHint.
  ///
  /// In en, this message translates to:
  /// **'Why does this transaction matter?'**
  String get txNotesHint;

  /// No description provided for @txRecentAtMerchant.
  ///
  /// In en, this message translates to:
  /// **'Recent at this merchant'**
  String get txRecentAtMerchant;

  /// No description provided for @txMerchantTotal.
  ///
  /// In en, this message translates to:
  /// **'Total: {amount} across {count} transactions'**
  String txMerchantTotal(Object amount, Object count);

  /// No description provided for @txMoveToDifferentAccount.
  ///
  /// In en, this message translates to:
  /// **'Move to a different account'**
  String get txMoveToDifferentAccount;

  /// No description provided for @txMoveFailed.
  ///
  /// In en, this message translates to:
  /// **'Move failed: {error}'**
  String txMoveFailed(Object error);

  /// No description provided for @txSplitThisTransaction.
  ///
  /// In en, this message translates to:
  /// **'Split this transaction'**
  String get txSplitThisTransaction;

  /// No description provided for @txEditSplit.
  ///
  /// In en, this message translates to:
  /// **'Edit split'**
  String get txEditSplit;

  /// No description provided for @txSplitRemoved.
  ///
  /// In en, this message translates to:
  /// **'Split removed'**
  String get txSplitRemoved;

  /// No description provided for @txUnsplitFailed.
  ///
  /// In en, this message translates to:
  /// **'Unsplit failed: {error}'**
  String txUnsplitFailed(Object error);

  /// No description provided for @txUnsplitRestore.
  ///
  /// In en, this message translates to:
  /// **'Unsplit (restore original)'**
  String get txUnsplitRestore;

  /// No description provided for @txDeleteOneTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete transaction?'**
  String get txDeleteOneTitle;

  /// No description provided for @txDeleteOneBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently removes the transaction. To re-import from CSV/PDF you will need to upload the file again.'**
  String get txDeleteOneBody;

  /// No description provided for @txDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String txDeleteFailed(Object error);

  /// No description provided for @txLinkedTransfer.
  ///
  /// In en, this message translates to:
  /// **'Linked cross-currency transfer'**
  String get txLinkedTransfer;

  /// No description provided for @txConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Confirmed'**
  String get txConfirmed;

  /// No description provided for @txAutoConfidence.
  ///
  /// In en, this message translates to:
  /// **'Auto · {confidence}%'**
  String txAutoConfidence(Object confidence);

  /// No description provided for @txAutoConfidenceKeyword.
  ///
  /// In en, this message translates to:
  /// **'Auto · {confidence}% · {keyword}'**
  String txAutoConfidenceKeyword(Object confidence, Object keyword);

  /// No description provided for @txTransferImpliedRate.
  ///
  /// In en, this message translates to:
  /// **'{srcAmount} → {dstAmount} · implied {rate} {dstCurrency}/{srcCurrency}'**
  String txTransferImpliedRate(
    Object dstAmount,
    Object dstCurrency,
    Object rate,
    Object srcAmount,
    Object srcCurrency,
  );

  /// No description provided for @txConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get txConfirm;

  /// No description provided for @txUnlink.
  ///
  /// In en, this message translates to:
  /// **'Unlink'**
  String get txUnlink;

  /// No description provided for @txSourcePlaid.
  ///
  /// In en, this message translates to:
  /// **'Synced via Plaid'**
  String get txSourcePlaid;

  /// No description provided for @txSourceCsv.
  ///
  /// In en, this message translates to:
  /// **'Imported (CSV)'**
  String get txSourceCsv;

  /// No description provided for @txSourceManual.
  ///
  /// In en, this message translates to:
  /// **'Manual entry'**
  String get txSourceManual;

  /// No description provided for @txSourceUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown source'**
  String get txSourceUnknown;

  /// No description provided for @txReassignTo.
  ///
  /// In en, this message translates to:
  /// **'Reassign to…'**
  String get txReassignTo;

  /// No description provided for @txMove.
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get txMove;

  /// No description provided for @txDateAllTime.
  ///
  /// In en, this message translates to:
  /// **'All time'**
  String get txDateAllTime;

  /// No description provided for @txDateLast7Days.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get txDateLast7Days;

  /// No description provided for @txDateLast30Days.
  ///
  /// In en, this message translates to:
  /// **'Last 30 days'**
  String get txDateLast30Days;

  /// No description provided for @txDateLast90Days.
  ///
  /// In en, this message translates to:
  /// **'Last 90 days'**
  String get txDateLast90Days;

  /// No description provided for @txDateYtd.
  ///
  /// In en, this message translates to:
  /// **'Year to date'**
  String get txDateYtd;

  /// No description provided for @txDateLastYear.
  ///
  /// In en, this message translates to:
  /// **'Last year'**
  String get txDateLastYear;

  /// No description provided for @txDateCustomRange.
  ///
  /// In en, this message translates to:
  /// **'Custom range'**
  String get txDateCustomRange;

  /// No description provided for @txReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get txReset;

  /// No description provided for @txDateRange.
  ///
  /// In en, this message translates to:
  /// **'Date range'**
  String get txDateRange;

  /// No description provided for @txAccounts.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get txAccounts;

  /// No description provided for @txCategories.
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get txCategories;

  /// No description provided for @txSplitSameAsParentUncategorised.
  ///
  /// In en, this message translates to:
  /// **'Same as parent (uncategorised)'**
  String get txSplitSameAsParentUncategorised;

  /// No description provided for @txSplitSameAsParent.
  ///
  /// In en, this message translates to:
  /// **'Same as parent ({category})'**
  String txSplitSameAsParent(Object category);

  /// No description provided for @txSplitExistingCategory.
  ///
  /// In en, this message translates to:
  /// **'{category}  (existing)'**
  String txSplitExistingCategory(Object category);

  /// No description provided for @txSplitTransactionTitle.
  ///
  /// In en, this message translates to:
  /// **'Split transaction'**
  String get txSplitTransactionTitle;

  /// No description provided for @txQuickSplit.
  ///
  /// In en, this message translates to:
  /// **'Quick split'**
  String get txQuickSplit;

  /// No description provided for @txSplitEven.
  ///
  /// In en, this message translates to:
  /// **'Even split…'**
  String get txSplitEven;

  /// No description provided for @txSplitTotal.
  ///
  /// In en, this message translates to:
  /// **'Total: {amount} {kind}'**
  String txSplitTotal(Object amount, Object kind);

  /// No description provided for @txSplitExpenseTag.
  ///
  /// In en, this message translates to:
  /// **'(expense)'**
  String get txSplitExpenseTag;

  /// No description provided for @txSplitIncomeTag.
  ///
  /// In en, this message translates to:
  /// **'(income)'**
  String get txSplitIncomeTag;

  /// No description provided for @txSplitDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get txSplitDescription;

  /// No description provided for @txSplitAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get txSplitAmount;

  /// No description provided for @txSplitRemoveRow.
  ///
  /// In en, this message translates to:
  /// **'Remove row'**
  String get txSplitRemoveRow;

  /// No description provided for @txSplitAddRow.
  ///
  /// In en, this message translates to:
  /// **'Add row'**
  String get txSplitAddRow;

  /// No description provided for @txSplitMatches.
  ///
  /// In en, this message translates to:
  /// **'Splits match the parent total.'**
  String get txSplitMatches;

  /// No description provided for @txSplitOffBy.
  ///
  /// In en, this message translates to:
  /// **'Off by {amount}.'**
  String txSplitOffBy(Object amount);

  /// No description provided for @txSplitApproxIn.
  ///
  /// In en, this message translates to:
  /// **'≈ {amount} in {currency}'**
  String txSplitApproxIn(Object amount, Object currency);

  /// No description provided for @txSplitSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get txSplitSaveChanges;

  /// No description provided for @txSplitSave.
  ///
  /// In en, this message translates to:
  /// **'Save split'**
  String get txSplitSave;

  /// No description provided for @txSplitEvenlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Split evenly'**
  String get txSplitEvenlyTitle;

  /// No description provided for @txSplitEvenlyBody.
  ///
  /// In en, this message translates to:
  /// **'Divide the parent amount into {count} equal parts.'**
  String txSplitEvenlyBody(Object count);

  /// No description provided for @secTitle.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get secTitle;

  /// No description provided for @secPasswordSection.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get secPasswordSection;

  /// No description provided for @secChangePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get secChangePassword;

  /// No description provided for @secChangePasswordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out of every other session.'**
  String get secChangePasswordSubtitle;

  /// No description provided for @secTwoFactorSection.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication'**
  String get secTwoFactorSection;

  /// No description provided for @secTotpEnabled.
  ///
  /// In en, this message translates to:
  /// **'TOTP enabled'**
  String get secTotpEnabled;

  /// No description provided for @secAddAuthenticatorApp.
  ///
  /// In en, this message translates to:
  /// **'Add an authenticator app'**
  String get secAddAuthenticatorApp;

  /// No description provided for @secTotpEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You will be asked for a 6-digit code at each sign-in.'**
  String get secTotpEnabledSubtitle;

  /// No description provided for @secAddAuthenticatorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Scan a QR code with Authy / Google Authenticator / 1Password.'**
  String get secAddAuthenticatorSubtitle;

  /// No description provided for @secRecoveryCodesSection.
  ///
  /// In en, this message translates to:
  /// **'Recovery codes'**
  String get secRecoveryCodesSection;

  /// No description provided for @secNoCodesLeft.
  ///
  /// In en, this message translates to:
  /// **'No recovery codes left'**
  String get secNoCodesLeft;

  /// No description provided for @secFewCodesLeft.
  ///
  /// In en, this message translates to:
  /// **'Only {count} recovery code{count, plural, =1{} other{s}} left'**
  String secFewCodesLeft(int count);

  /// No description provided for @secLowCodesWarningBody.
  ///
  /// In en, this message translates to:
  /// **'If you lose your authenticator and run out of codes you can be locked out. Regenerate now to restore a full set of 10.'**
  String get secLowCodesWarningBody;

  /// No description provided for @secRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get secRegenerate;

  /// No description provided for @secUnusedCodes.
  ///
  /// In en, this message translates to:
  /// **'{count} unused codes'**
  String secUnusedCodes(Object count);

  /// No description provided for @secUnusedCodesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Regenerate if you lose your saved codes — all old codes stop working.'**
  String get secUnusedCodesSubtitle;

  /// No description provided for @secRegenerateCodesTitle.
  ///
  /// In en, this message translates to:
  /// **'Regenerate recovery codes?'**
  String get secRegenerateCodesTitle;

  /// No description provided for @secRegenerateCodesBody.
  ///
  /// In en, this message translates to:
  /// **'Your old codes will stop working immediately. Make sure you save the new ones before closing the dialog.'**
  String get secRegenerateCodesBody;

  /// No description provided for @secGenerateNew.
  ///
  /// In en, this message translates to:
  /// **'Generate new'**
  String get secGenerateNew;

  /// No description provided for @secPasswordChangedSnack.
  ///
  /// In en, this message translates to:
  /// **'Password changed. Other sessions signed out.'**
  String get secPasswordChangedSnack;

  /// No description provided for @secTwoFactorEnabledSnack.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication enabled.'**
  String get secTwoFactorEnabledSnack;

  /// No description provided for @secTwoFactorDisabledSnack.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication disabled.'**
  String get secTwoFactorDisabledSnack;

  /// No description provided for @secDisableTwoFactorTitle.
  ///
  /// In en, this message translates to:
  /// **'Disable two-factor authentication?'**
  String get secDisableTwoFactorTitle;

  /// No description provided for @secDisableTwoFactorBody.
  ///
  /// In en, this message translates to:
  /// **'Enter your password to confirm. Disabling TOTP makes your account less secure.'**
  String get secDisableTwoFactorBody;

  /// No description provided for @secFailedWithReason.
  ///
  /// In en, this message translates to:
  /// **'Failed: {reason}'**
  String secFailedWithReason(Object reason);

  /// No description provided for @secSignOutSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out this session?'**
  String get secSignOutSessionTitle;

  /// No description provided for @secSignOutSessionBody.
  ///
  /// In en, this message translates to:
  /// **'This will sign out the device \"{device}\" immediately. They will have to enter the password (and TOTP) to sign in again.'**
  String secSignOutSessionBody(Object device);

  /// No description provided for @secSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get secSignOut;

  /// No description provided for @secSessionSignedOutSnack.
  ///
  /// In en, this message translates to:
  /// **'Session signed out.'**
  String get secSessionSignedOutSnack;

  /// No description provided for @secSignOutThisDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out of this device?'**
  String get secSignOutThisDeviceTitle;

  /// No description provided for @secSignOutThisDeviceBody.
  ///
  /// In en, this message translates to:
  /// **'You will need to enter your password again (and TOTP, if enabled) to sign back in.'**
  String get secSignOutThisDeviceBody;

  /// No description provided for @secSignOutEverywhereTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out everywhere else?'**
  String get secSignOutEverywhereTitle;

  /// No description provided for @secSignOutEverywhereBody.
  ///
  /// In en, this message translates to:
  /// **'This will end {count} other session{count, plural, =1{} other{s}} immediately. This device will stay signed in.'**
  String secSignOutEverywhereBody(int count);

  /// No description provided for @secSignOutOthers.
  ///
  /// In en, this message translates to:
  /// **'Sign out others'**
  String get secSignOutOthers;

  /// No description provided for @secOtherSessionsSignedOutSnack.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 other session signed out.} other{{count} other sessions signed out.}}'**
  String secOtherSessionsSignedOutSnack(int count);

  /// No description provided for @secOnOs.
  ///
  /// In en, this message translates to:
  /// **'on {os}'**
  String secOnOs(Object os);

  /// No description provided for @secUnknownDevice.
  ///
  /// In en, this message translates to:
  /// **'Unknown device'**
  String get secUnknownDevice;

  /// No description provided for @secActiveJustNow.
  ///
  /// In en, this message translates to:
  /// **'Active just now'**
  String get secActiveJustNow;

  /// No description provided for @secActiveMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'Active {minutes}m ago'**
  String secActiveMinutesAgo(Object minutes);

  /// No description provided for @secActiveHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'Active {hours}h ago'**
  String secActiveHoursAgo(Object hours);

  /// No description provided for @secActiveDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'Active {days}d ago'**
  String secActiveDaysAgo(Object days);

  /// No description provided for @secActiveOnDate.
  ///
  /// In en, this message translates to:
  /// **'Active on {date}'**
  String secActiveOnDate(Object date);

  /// No description provided for @secInviteUsersSection.
  ///
  /// In en, this message translates to:
  /// **'Invite users'**
  String get secInviteUsersSection;

  /// No description provided for @secNewInviteLink.
  ///
  /// In en, this message translates to:
  /// **'New invite link'**
  String get secNewInviteLink;

  /// No description provided for @secNoInvites.
  ///
  /// In en, this message translates to:
  /// **'No invites'**
  String get secNoInvites;

  /// No description provided for @secNoInvitesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Generate a one-time link to let another person sign up for their own Patrimonio account.'**
  String get secNoInvitesSubtitle;

  /// No description provided for @secInviteRedeemed.
  ///
  /// In en, this message translates to:
  /// **'Redeemed'**
  String get secInviteRedeemed;

  /// No description provided for @secInviteExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get secInviteExpired;

  /// No description provided for @secInviteActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get secInviteActive;

  /// No description provided for @secReadOnlyChip.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get secReadOnlyChip;

  /// No description provided for @secInviteUsedOn.
  ///
  /// In en, this message translates to:
  /// **'Used {date}'**
  String secInviteUsedOn(Object date);

  /// No description provided for @secInviteExpiresOn.
  ///
  /// In en, this message translates to:
  /// **'Expires {date}'**
  String secInviteExpiresOn(Object date);

  /// No description provided for @secRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get secRevoke;

  /// No description provided for @secManyActiveInvitesHint.
  ///
  /// In en, this message translates to:
  /// **'You have {count} active invites — consider revoking unused links.'**
  String secManyActiveInvitesHint(Object count);

  /// No description provided for @secReadOnlyInviteReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'Read-only invite link ready'**
  String get secReadOnlyInviteReadyTitle;

  /// No description provided for @secInviteReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'Invite link ready'**
  String get secInviteReadyTitle;

  /// No description provided for @secReadOnlyInviteReadyBody.
  ///
  /// In en, this message translates to:
  /// **'Share this URL with the new user. They will be able to view your data but not change anything. It works for one account creation and expires on:'**
  String get secReadOnlyInviteReadyBody;

  /// No description provided for @secInviteReadyBody.
  ///
  /// In en, this message translates to:
  /// **'Share this URL with the new user. It works for one account creation and expires on:'**
  String get secInviteReadyBody;

  /// No description provided for @secCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard.'**
  String get secCopiedToClipboard;

  /// No description provided for @secCopyAgain.
  ///
  /// In en, this message translates to:
  /// **'Copy again'**
  String get secCopyAgain;

  /// No description provided for @secDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get secDone;

  /// No description provided for @secRevokeInviteTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke invite?'**
  String get secRevokeInviteTitle;

  /// No description provided for @secRevokeInviteBody.
  ///
  /// In en, this message translates to:
  /// **'The link will stop working immediately. You can mint a new one if you change your mind.'**
  String get secRevokeInviteBody;

  /// No description provided for @secRevokeFailedWithReason.
  ///
  /// In en, this message translates to:
  /// **'Revoke failed: {reason}'**
  String secRevokeFailedWithReason(Object reason);

  /// No description provided for @secPasskeysSection.
  ///
  /// In en, this message translates to:
  /// **'Passkeys'**
  String get secPasskeysSection;

  /// No description provided for @secAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get secAdd;

  /// No description provided for @secThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get secThisDevice;

  /// No description provided for @secThisDeviceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Face ID / Touch ID / Windows Hello'**
  String get secThisDeviceSubtitle;

  /// No description provided for @secSecurityKey.
  ///
  /// In en, this message translates to:
  /// **'Security key'**
  String get secSecurityKey;

  /// No description provided for @secSecurityKeySubtitle.
  ///
  /// In en, this message translates to:
  /// **'USB / NFC key — YubiKey, Titan'**
  String get secSecurityKeySubtitle;

  /// No description provided for @secPasskeysUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Passkeys not available'**
  String get secPasskeysUnavailable;

  /// No description provided for @secPasskeysUnavailableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This browser does not expose the WebAuthn API. Try Chrome, Safari, or Edge on a recent OS to register a passkey.'**
  String get secPasskeysUnavailableSubtitle;

  /// No description provided for @secNoPasskeys.
  ///
  /// In en, this message translates to:
  /// **'No passkeys registered'**
  String get secNoPasskeys;

  /// No description provided for @secNoPasskeysSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add this device, your phone, or a hardware security key (YubiKey, Titan, etc.) so you can sign in with biometrics or a tap instead of a password.'**
  String get secNoPasskeysSubtitle;

  /// No description provided for @secInsertSecurityKeyPrompt.
  ///
  /// In en, this message translates to:
  /// **'Insert your security key and tap it (choose the USB/security-key option if your browser offers a saved passkey)…'**
  String get secInsertSecurityKeyPrompt;

  /// No description provided for @secConfirmBiometricPrompt.
  ///
  /// In en, this message translates to:
  /// **'Confirm with your device biometric…'**
  String get secConfirmBiometricPrompt;

  /// No description provided for @secPasskeyAddedSnack.
  ///
  /// In en, this message translates to:
  /// **'Passkey added.'**
  String get secPasskeyAddedSnack;

  /// No description provided for @secRemovePasskeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this passkey?'**
  String get secRemovePasskeyTitle;

  /// No description provided for @secRemovePasskeyBody.
  ///
  /// In en, this message translates to:
  /// **'You will no longer be able to sign in with \"{name}\". This cannot be undone.'**
  String secRemovePasskeyBody(Object name);

  /// No description provided for @secThisDeviceFallback.
  ///
  /// In en, this message translates to:
  /// **'this device'**
  String get secThisDeviceFallback;

  /// No description provided for @secRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get secRemove;

  /// No description provided for @secPasskeyRemovedSnack.
  ///
  /// In en, this message translates to:
  /// **'Passkey removed.'**
  String get secPasskeyRemovedSnack;

  /// No description provided for @secActiveSessionsSection.
  ///
  /// In en, this message translates to:
  /// **'Active sessions'**
  String get secActiveSessionsSection;

  /// No description provided for @secSignOutNOthers.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Sign out 1 other} other{Sign out {count} others}}'**
  String secSignOutNOthers(int count);

  /// No description provided for @secNoActiveSessions.
  ///
  /// In en, this message translates to:
  /// **'No active sessions'**
  String get secNoActiveSessions;

  /// No description provided for @secNoActiveSessionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You should at least see this device. Refresh to retry.'**
  String get secNoActiveSessionsSubtitle;

  /// No description provided for @secThisDeviceBadge.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get secThisDeviceBadge;

  /// No description provided for @secNewSinceLastVisit.
  ///
  /// In en, this message translates to:
  /// **'New since last visit'**
  String get secNewSinceLastVisit;

  /// No description provided for @secSignOutSessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sign out this session'**
  String get secSignOutSessionTooltip;

  /// No description provided for @secChangePasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get secChangePasswordTitle;

  /// No description provided for @secCurrentPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get secCurrentPasswordLabel;

  /// No description provided for @secNewPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'New password (12+ characters)'**
  String get secNewPasswordLabel;

  /// No description provided for @secPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters'**
  String get secPasswordTooShort;

  /// No description provided for @secConfirmPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get secConfirmPasswordLabel;

  /// No description provided for @secPasswordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get secPasswordsDoNotMatch;

  /// No description provided for @secChangeButton.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get secChangeButton;

  /// No description provided for @secEnterSixDigitCode.
  ///
  /// In en, this message translates to:
  /// **'Enter the 6-digit code from your app.'**
  String get secEnterSixDigitCode;

  /// No description provided for @secEnrollTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up two-factor authentication'**
  String get secEnrollTitle;

  /// No description provided for @secEnrollSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Open your authenticator app (Authy, Google Authenticator, 1Password, etc.).\n2. Scan the QR code below — or choose \"Enter a setup key\" and paste the secret.\n3. Enter the 6-digit code your app shows.'**
  String get secEnrollSteps;

  /// No description provided for @secSetupLinkSecret.
  ///
  /// In en, this message translates to:
  /// **'Setup link / secret'**
  String get secSetupLinkSecret;

  /// No description provided for @secHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get secHide;

  /// No description provided for @secShow.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get secShow;

  /// No description provided for @secCopyOtpauthUri.
  ///
  /// In en, this message translates to:
  /// **'Copy otpauth:// URI'**
  String get secCopyOtpauthUri;

  /// No description provided for @secSixDigitCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'6-digit code from your app'**
  String get secSixDigitCodeLabel;

  /// No description provided for @secEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get secEnable;

  /// No description provided for @secConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get secConfirm;

  /// No description provided for @secPasskeyRegisteredOn.
  ///
  /// In en, this message translates to:
  /// **'Registered {date}'**
  String secPasskeyRegisteredOn(Object date);

  /// No description provided for @secLastUsedJustNow.
  ///
  /// In en, this message translates to:
  /// **'Last used just now'**
  String get secLastUsedJustNow;

  /// No description provided for @secLastUsedMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'Last used {minutes}m ago'**
  String secLastUsedMinutesAgo(Object minutes);

  /// No description provided for @secLastUsedHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'Last used {hours}h ago'**
  String secLastUsedHoursAgo(Object hours);

  /// No description provided for @secLastUsedDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'Last used {days}d ago'**
  String secLastUsedDaysAgo(Object days);

  /// No description provided for @secLastUsedOn.
  ///
  /// In en, this message translates to:
  /// **'Last used {date}'**
  String secLastUsedOn(Object date);

  /// No description provided for @secHardwareKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Hardware security key'**
  String get secHardwareKeyTitle;

  /// No description provided for @secDevicePasskeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Device passkey'**
  String get secDevicePasskeyTitle;

  /// No description provided for @secHardwareKeyKind.
  ///
  /// In en, this message translates to:
  /// **'Hardware security key'**
  String get secHardwareKeyKind;

  /// No description provided for @secPlatformPasskeyKind.
  ///
  /// In en, this message translates to:
  /// **'Platform passkey'**
  String get secPlatformPasskeyKind;

  /// No description provided for @secRemovePasskeyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove passkey'**
  String get secRemovePasskeyTooltip;

  /// No description provided for @secInviteAccessQuestion.
  ///
  /// In en, this message translates to:
  /// **'What level of access should this invite grant?'**
  String get secInviteAccessQuestion;

  /// No description provided for @secFullAccess.
  ///
  /// In en, this message translates to:
  /// **'Full access'**
  String get secFullAccess;

  /// No description provided for @secFullAccessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Can view and change everything — link accounts, edit transactions, run syncs.'**
  String get secFullAccessSubtitle;

  /// No description provided for @secReadOnlyAccess.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get secReadOnlyAccess;

  /// No description provided for @secReadOnlyAccessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Can view everything but cannot make changes. Good for a spouse, advisor, or accountant.'**
  String get secReadOnlyAccessSubtitle;

  /// No description provided for @secCreateLink.
  ///
  /// In en, this message translates to:
  /// **'Create link'**
  String get secCreateLink;

  /// No description provided for @secNamePasskeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Name this passkey'**
  String get secNamePasskeyTitle;

  /// No description provided for @secNamePasskeyBody.
  ///
  /// In en, this message translates to:
  /// **'Optional label so you can tell this passkey apart later. Examples: \"iPhone 15\", \"Work MacBook\", \"YubiKey on keychain\".'**
  String get secNamePasskeyBody;

  /// No description provided for @secDeviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get secDeviceNameLabel;

  /// No description provided for @secDeviceNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. iPhone 15'**
  String get secDeviceNameHint;

  /// No description provided for @secContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get secContinue;

  /// No description provided for @cfMonthlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Cash flow this month'**
  String get cfMonthlyTitle;

  /// No description provided for @cfMonthlyExcludesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Excludes internal transfers between your accounts and credit-card payments — those move money around your own balance sheet without changing your spending.'**
  String get cfMonthlyExcludesTooltip;

  /// No description provided for @cfIncome.
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get cfIncome;

  /// No description provided for @cfExpense.
  ///
  /// In en, this message translates to:
  /// **'Expense'**
  String get cfExpense;

  /// No description provided for @cfMonthlyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Cash flow will appear here once a few weeks of transactions are synced.'**
  String get cfMonthlyEmpty;

  /// No description provided for @cfVsLastMonth.
  ///
  /// In en, this message translates to:
  /// **'{delta} vs last month'**
  String cfVsLastMonth(Object delta);

  /// No description provided for @cfNotEnoughHistory.
  ///
  /// In en, this message translates to:
  /// **'Not enough history yet'**
  String get cfNotEnoughHistory;

  /// No description provided for @cfSubscriptionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Recurring charges'**
  String get cfSubscriptionsTitle;

  /// No description provided for @cfSubscriptionsActiveCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 active} other{{count} active}}'**
  String cfSubscriptionsActiveCount(int count);

  /// No description provided for @cfSubscriptionsStoppedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 stopped} other{{count} stopped}}'**
  String cfSubscriptionsStoppedCount(int count);

  /// No description provided for @cfPerMonthApprox.
  ///
  /// In en, this message translates to:
  /// **'≈ {amount} / mo'**
  String cfPerMonthApprox(Object amount);

  /// No description provided for @cfSubscriptionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Charges that repeat every 5–62 days. Tap a row to filter the transactions list.'**
  String get cfSubscriptionsSubtitle;

  /// No description provided for @cfSubscriptionsNoneActive.
  ///
  /// In en, this message translates to:
  /// **'No active subscriptions detected.'**
  String get cfSubscriptionsNoneActive;

  /// No description provided for @cfSubscriptionsStoppedHeader.
  ///
  /// In en, this message translates to:
  /// **'Stopped ({count})'**
  String cfSubscriptionsStoppedHeader(Object count);

  /// No description provided for @cfSubscriptionsStoppedHint.
  ///
  /// In en, this message translates to:
  /// **'Last charged > 90 days ago'**
  String get cfSubscriptionsStoppedHint;

  /// No description provided for @cfCadenceWeekly.
  ///
  /// In en, this message translates to:
  /// **'Weekly'**
  String get cfCadenceWeekly;

  /// No description provided for @cfCadenceBiweekly.
  ///
  /// In en, this message translates to:
  /// **'Bi-weekly'**
  String get cfCadenceBiweekly;

  /// No description provided for @cfCadenceMonthly.
  ///
  /// In en, this message translates to:
  /// **'Monthly'**
  String get cfCadenceMonthly;

  /// No description provided for @cfCadenceEveryNDays.
  ///
  /// In en, this message translates to:
  /// **'Every {days}d'**
  String cfCadenceEveryNDays(Object days);

  /// No description provided for @cfChargesCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 charge} other{{count} charges}}'**
  String cfChargesCount(int count);

  /// No description provided for @cfLastCharged.
  ///
  /// In en, this message translates to:
  /// **'last {date}'**
  String cfLastCharged(Object date);

  /// No description provided for @cfPerMonth.
  ///
  /// In en, this message translates to:
  /// **'{amount} / mo'**
  String cfPerMonth(Object amount);

  /// No description provided for @cfWasPerMonth.
  ///
  /// In en, this message translates to:
  /// **'was {amount} / mo'**
  String cfWasPerMonth(Object amount);

  /// No description provided for @cfNotASubscription.
  ///
  /// In en, this message translates to:
  /// **'Not a subscription — hide this row'**
  String get cfNotASubscription;

  /// No description provided for @cfPlusNMore.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String cfPlusNMore(Object count);

  /// No description provided for @cfBudgetsTitle.
  ///
  /// In en, this message translates to:
  /// **'Budgets this month'**
  String get cfBudgetsTitle;

  /// No description provided for @cfBudgetsEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get cfBudgetsEdit;

  /// No description provided for @cfBudgetsEmpty.
  ///
  /// In en, this message translates to:
  /// **'Set a monthly budget for any category to track spending against it here.'**
  String get cfBudgetsEmpty;

  /// No description provided for @cfBudgetsDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit monthly budgets'**
  String get cfBudgetsDialogTitle;

  /// No description provided for @cfTransfersTitle.
  ///
  /// In en, this message translates to:
  /// **'Cross-currency transfers'**
  String get cfTransfersTitle;

  /// No description provided for @cfTransfersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Linked Wise / Remitly / wire pairs. Implied rate is the effective FX the service used; spot is the market rate on the source date.'**
  String get cfTransfersSubtitle;

  /// No description provided for @cfTransfersSpot.
  ///
  /// In en, this message translates to:
  /// **'spot {rate}'**
  String cfTransfersSpot(Object rate);

  /// No description provided for @cfTransfersConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get cfTransfersConfirm;

  /// No description provided for @cfTransfersConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Confirmed'**
  String get cfTransfersConfirmed;

  /// No description provided for @cfTransfersUnlink.
  ///
  /// In en, this message translates to:
  /// **'Unlink'**
  String get cfTransfersUnlink;

  /// No description provided for @cfCreditNoAccounts.
  ///
  /// In en, this message translates to:
  /// **'No credit accounts found.'**
  String get cfCreditNoAccounts;

  /// No description provided for @cfCreditUtilizationHeader.
  ///
  /// In en, this message translates to:
  /// **'CREDIT UTILIZATION'**
  String get cfCreditUtilizationHeader;

  /// No description provided for @cfCreditAccountFallback.
  ///
  /// In en, this message translates to:
  /// **'Credit account'**
  String get cfCreditAccountFallback;

  /// No description provided for @cfCreditShowFewer.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get cfCreditShowFewer;

  /// No description provided for @cfCreditShowMore.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Show 1 more card} other{Show {count} more cards}}'**
  String cfCreditShowMore(int count);

  /// No description provided for @authCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get authCreateAccount;

  /// No description provided for @authInviteIntro.
  ///
  /// In en, this message translates to:
  /// **'You were invited. Pick a username and password to finish setting up your account.'**
  String get authInviteIntro;

  /// No description provided for @authUsernameMaxLength.
  ///
  /// In en, this message translates to:
  /// **'Max 64 characters'**
  String get authUsernameMaxLength;

  /// No description provided for @authEmailOptional.
  ///
  /// In en, this message translates to:
  /// **'Email (optional)'**
  String get authEmailOptional;

  /// No description provided for @authPasswordMinHelper.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters'**
  String get authPasswordMinHelper;

  /// No description provided for @authConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get authConfirmPassword;

  /// No description provided for @authPasswordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get authPasswordsDoNotMatch;

  /// No description provided for @authResetPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get authResetPasswordTitle;

  /// No description provided for @authPasswordResetDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Password reset'**
  String get authPasswordResetDoneTitle;

  /// No description provided for @authPasswordResetDoneBody.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your new password. The code you used has been consumed.'**
  String get authPasswordResetDoneBody;

  /// No description provided for @authBackToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to sign in'**
  String get authBackToSignIn;

  /// No description provided for @authUseRecoveryCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Use a recovery code'**
  String get authUseRecoveryCodeTitle;

  /// No description provided for @authUseRecoveryCodeBody.
  ///
  /// In en, this message translates to:
  /// **'Enter one of the recovery codes you saved at setup. Each code is single-use — once redeemed it cannot be reused.'**
  String get authUseRecoveryCodeBody;

  /// No description provided for @authRecoveryCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Recovery code (e.g. XK4T-9PMQ-7HZL)'**
  String get authRecoveryCodeLabel;

  /// No description provided for @authRecoveryCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Hyphens and case are optional'**
  String get authRecoveryCodeHint;

  /// No description provided for @authRecoveryCodeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Codes are 12 letters/digits (hyphens optional)'**
  String get authRecoveryCodeInvalid;

  /// No description provided for @authNewPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'New password (12+ characters)'**
  String get authNewPasswordLabel;

  /// No description provided for @authConfirmNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm new password'**
  String get authConfirmNewPassword;

  /// No description provided for @authWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Patrimonio'**
  String get authWelcomeTitle;

  /// No description provided for @authBootstrapSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create the owner account. This is a one-time setup.'**
  String get authBootstrapSubtitle;

  /// No description provided for @authPasswordWithMin.
  ///
  /// In en, this message translates to:
  /// **'Password (12+ characters)'**
  String get authPasswordWithMin;

  /// No description provided for @authTotpEnterCode.
  ///
  /// In en, this message translates to:
  /// **'Enter the 6-digit code from your app.'**
  String get authTotpEnterCode;

  /// No description provided for @authTotpTitle.
  ///
  /// In en, this message translates to:
  /// **'Two-factor required'**
  String get authTotpTitle;

  /// No description provided for @authTotpSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open your authenticator app and enter the 6-digit code for Patrimonio.'**
  String get authTotpSubtitle;

  /// No description provided for @authTotpVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get authTotpVerify;

  /// No description provided for @impTitle.
  ///
  /// In en, this message translates to:
  /// **'Import statement'**
  String get impTitle;

  /// No description provided for @impUploadHeading.
  ///
  /// In en, this message translates to:
  /// **'Upload account statement'**
  String get impUploadHeading;

  /// No description provided for @impUploadSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Upload CSV or PDF statements from {banks}. We will automatically detect the format.'**
  String impUploadSubtitle(Object banks);

  /// No description provided for @impWaitForUpload.
  ///
  /// In en, this message translates to:
  /// **'Wait for the current import to finish before adding more files.'**
  String get impWaitForUpload;

  /// No description provided for @impAddedFileFromDrop.
  ///
  /// In en, this message translates to:
  /// **'Added 1 file from drop'**
  String get impAddedFileFromDrop;

  /// No description provided for @impAddedFilesFromDrop.
  ///
  /// In en, this message translates to:
  /// **'Added {count} files from drop'**
  String impAddedFilesFromDrop(Object count);

  /// No description provided for @impUploadTooLarge.
  ///
  /// In en, this message translates to:
  /// **'These {count} files total {totalMb} MB, over the 100 MB upload limit. Remove some files and import them in separate batches.'**
  String impUploadTooLarge(Object count, Object totalMb);

  /// No description provided for @impLargeUploadTitle.
  ///
  /// In en, this message translates to:
  /// **'Large upload'**
  String get impLargeUploadTitle;

  /// No description provided for @impLargeUploadBody.
  ///
  /// In en, this message translates to:
  /// **'This batch is {totalMb} MB — close to the 100 MB limit. Large uploads can be slow and may be rejected. Import anyway?'**
  String impLargeUploadBody(Object totalMb);

  /// No description provided for @impImportAnyway.
  ///
  /// In en, this message translates to:
  /// **'Import anyway'**
  String get impImportAnyway;

  /// No description provided for @impFoundTransactions.
  ///
  /// In en, this message translates to:
  /// **'Found {count} transactions.'**
  String impFoundTransactions(Object count);

  /// No description provided for @impFoundWithAutoDeselected.
  ///
  /// In en, this message translates to:
  /// **'{message} ({count} auto-deselected as informational)'**
  String impFoundWithAutoDeselected(Object count, Object message);

  /// No description provided for @impUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed: {error}'**
  String impUploadFailed(Object error);

  /// No description provided for @impSelectAccountFirst.
  ///
  /// In en, this message translates to:
  /// **'Please select a destination account first.'**
  String get impSelectAccountFirst;

  /// No description provided for @impNoTransactionsSelected.
  ///
  /// In en, this message translates to:
  /// **'No transactions selected. Please check at least one.'**
  String get impNoTransactionsSelected;

  /// No description provided for @impImportSuccessful.
  ///
  /// In en, this message translates to:
  /// **'Import successful'**
  String get impImportSuccessful;

  /// No description provided for @impConfirmationFailed.
  ///
  /// In en, this message translates to:
  /// **'Confirmation failed: {error}'**
  String impConfirmationFailed(Object error);

  /// No description provided for @impReadingFiles.
  ///
  /// In en, this message translates to:
  /// **'Reading files…'**
  String get impReadingFiles;

  /// No description provided for @impReadingOneFile.
  ///
  /// In en, this message translates to:
  /// **'Reading 1 file…'**
  String get impReadingOneFile;

  /// No description provided for @impReadingNFiles.
  ///
  /// In en, this message translates to:
  /// **'Reading {count} files…'**
  String impReadingNFiles(Object count);

  /// No description provided for @impReadingHint.
  ///
  /// In en, this message translates to:
  /// **'Loading file contents into the browser before sending. This step is local — no upload yet.'**
  String get impReadingHint;

  /// No description provided for @impProcessingOneFile.
  ///
  /// In en, this message translates to:
  /// **'Processing 1 file…'**
  String get impProcessingOneFile;

  /// No description provided for @impProcessingProgress.
  ///
  /// In en, this message translates to:
  /// **'Processing {done} of {total} files…'**
  String impProcessingProgress(Object done, Object total);

  /// No description provided for @impProcessingNFiles.
  ///
  /// In en, this message translates to:
  /// **'Processing {count} files…'**
  String impProcessingNFiles(Object count);

  /// No description provided for @impLastFile.
  ///
  /// In en, this message translates to:
  /// **'Last: {file}'**
  String impLastFile(Object file);

  /// No description provided for @impLastFileSkipped.
  ///
  /// In en, this message translates to:
  /// **'Last: {file} (skipped)'**
  String impLastFileSkipped(Object file);

  /// No description provided for @impLargeBatchHint.
  ///
  /// In en, this message translates to:
  /// **'Large batches can take 30-120 seconds — each PDF is parsed individually on the server.'**
  String get impLargeBatchHint;

  /// No description provided for @impDropToImport.
  ///
  /// In en, this message translates to:
  /// **'Drop to import'**
  String get impDropToImport;

  /// No description provided for @impDropHint.
  ///
  /// In en, this message translates to:
  /// **'Drop CSV or PDF files anywhere on this page, or select them manually below.'**
  String get impDropHint;

  /// No description provided for @impNoFilesSelected.
  ///
  /// In en, this message translates to:
  /// **'No files selected'**
  String get impNoFilesSelected;

  /// No description provided for @impOneFileSelected.
  ///
  /// In en, this message translates to:
  /// **'1 file selected'**
  String get impOneFileSelected;

  /// No description provided for @impNFilesSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} files selected'**
  String impNFilesSelected(Object count);

  /// No description provided for @impRemoveFile.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get impRemoveFile;

  /// No description provided for @impSelectFiles.
  ///
  /// In en, this message translates to:
  /// **'Select files'**
  String get impSelectFiles;

  /// No description provided for @impAddMoreFiles.
  ///
  /// In en, this message translates to:
  /// **'Add more files'**
  String get impAddMoreFiles;

  /// No description provided for @impAssignToAccount.
  ///
  /// In en, this message translates to:
  /// **'Assign to account'**
  String get impAssignToAccount;

  /// No description provided for @impPreviewSelected.
  ///
  /// In en, this message translates to:
  /// **'Preview ({selected}/{total} selected)'**
  String impPreviewSelected(Object selected, Object total);

  /// No description provided for @impSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get impSelectAll;

  /// No description provided for @impDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get impDeselectAll;

  /// No description provided for @impAutoDeselectedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Auto-deselected: informational entry'**
  String get impAutoDeselectedTooltip;

  /// No description provided for @impImportOneTransaction.
  ///
  /// In en, this message translates to:
  /// **'Import 1 Transaction'**
  String get impImportOneTransaction;

  /// No description provided for @impImportNTransactions.
  ///
  /// In en, this message translates to:
  /// **'Import {count} Transactions'**
  String impImportNTransactions(Object count);

  /// No description provided for @impPdfPassword.
  ///
  /// In en, this message translates to:
  /// **'PDF password (e.g. RFC)'**
  String get impPdfPassword;

  /// No description provided for @impProcessStatement.
  ///
  /// In en, this message translates to:
  /// **'Process statement'**
  String get impProcessStatement;

  /// No description provided for @dashConnectViaOauth.
  ///
  /// In en, this message translates to:
  /// **'Connect via OAuth'**
  String get dashConnectViaOauth;

  /// No description provided for @dashConnectWithApiKey.
  ///
  /// In en, this message translates to:
  /// **'Connect with an API key'**
  String get dashConnectWithApiKey;

  /// No description provided for @dashPaletteJumpTo.
  ///
  /// In en, this message translates to:
  /// **'Jump to {name}'**
  String dashPaletteJumpTo(Object name);

  /// No description provided for @dashPaletteSection.
  ///
  /// In en, this message translates to:
  /// **'Section'**
  String get dashPaletteSection;

  /// No description provided for @dashPaletteSectionLending.
  ///
  /// In en, this message translates to:
  /// **'Section · money you\'ve lent'**
  String get dashPaletteSectionLending;

  /// No description provided for @dashPaletteAccount.
  ///
  /// In en, this message translates to:
  /// **'Account · {institution}'**
  String dashPaletteAccount(Object institution);

  /// No description provided for @dashPaletteHolding.
  ///
  /// In en, this message translates to:
  /// **'Holding'**
  String get dashPaletteHolding;

  /// No description provided for @dashPaletteTransaction.
  ///
  /// In en, this message translates to:
  /// **'Transaction · {account} · {date}'**
  String dashPaletteTransaction(Object account, Object date);

  /// No description provided for @dashHiddenFromSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Hidden from subscriptions'**
  String get dashHiddenFromSubscriptions;

  /// No description provided for @dashHiddenFromSubscriptionsHint.
  ///
  /// In en, this message translates to:
  /// **'You dismissed these as \"not a subscription.\" Unhide a row to let the detector reconsider it.'**
  String get dashHiddenFromSubscriptionsHint;

  /// No description provided for @dashUnhide.
  ///
  /// In en, this message translates to:
  /// **'Unhide'**
  String get dashUnhide;

  /// No description provided for @dashSubscriptionRestored.
  ///
  /// In en, this message translates to:
  /// **'\"{merchant}\" is back in the subscription detector'**
  String dashSubscriptionRestored(Object merchant);

  /// No description provided for @dashUnhideFailed.
  ///
  /// In en, this message translates to:
  /// **'Unhide failed: {error}'**
  String dashUnhideFailed(Object error);

  /// No description provided for @dashModuleLendingTitle.
  ///
  /// In en, this message translates to:
  /// **'Personal lending'**
  String get dashModuleLendingTitle;

  /// No description provided for @dashModuleLendingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Track money you lend to friends — designate the bank transactions that fund and repay each loan. Adds a Lending section.'**
  String get dashModuleLendingSubtitle;

  /// No description provided for @dashRemindBeforeRepayment.
  ///
  /// In en, this message translates to:
  /// **'Remind me before a repayment is due'**
  String get dashRemindBeforeRepayment;

  /// No description provided for @dashFewerDays.
  ///
  /// In en, this message translates to:
  /// **'Fewer days'**
  String get dashFewerDays;

  /// No description provided for @dashMoreDays.
  ///
  /// In en, this message translates to:
  /// **'More days'**
  String get dashMoreDays;

  /// No description provided for @dashDaysShort.
  ///
  /// In en, this message translates to:
  /// **'{count} d'**
  String dashDaysShort(Object count);

  /// No description provided for @dashReminderSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save reminder setting'**
  String get dashReminderSaveFailed;

  /// No description provided for @dashSettingSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save that setting'**
  String get dashSettingSaveFailed;

  /// No description provided for @dashEnvSandbox.
  ///
  /// In en, this message translates to:
  /// **'Sandbox'**
  String get dashEnvSandbox;

  /// No description provided for @dashEnvDev.
  ///
  /// In en, this message translates to:
  /// **'Dev'**
  String get dashEnvDev;

  /// No description provided for @dashEnvTooltip.
  ///
  /// In en, this message translates to:
  /// **'Plaid is in {env} mode. Linked accounts will not access real bank data.'**
  String dashEnvTooltip(Object env);

  /// No description provided for @dashFxLoading.
  ///
  /// In en, this message translates to:
  /// **'Exchange rate loading…'**
  String get dashFxLoading;

  /// No description provided for @dashFxLive.
  ///
  /// In en, this message translates to:
  /// **'Live USD/MXN exchange rate'**
  String get dashFxLive;

  /// No description provided for @dashFxStaleAt.
  ///
  /// In en, this message translates to:
  /// **'Stale rate — {timestamp}'**
  String dashFxStaleAt(Object timestamp);

  /// No description provided for @dashFxUpdatedAt.
  ///
  /// In en, this message translates to:
  /// **'Updated {timestamp}'**
  String dashFxUpdatedAt(Object timestamp);

  /// No description provided for @dashLinkUsBank.
  ///
  /// In en, this message translates to:
  /// **'Link a US bank'**
  String get dashLinkUsBank;

  /// No description provided for @dashLinkUsBankSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Securely connect via Plaid — balances and transactions sync automatically.'**
  String get dashLinkUsBankSubtitle;

  /// No description provided for @dashLinkUsBankDisabledHint.
  ///
  /// In en, this message translates to:
  /// **'Plaid credentials not configured yet — use CSV or manual for now.'**
  String get dashLinkUsBankDisabledHint;

  /// No description provided for @dashImportMxCsvPdf.
  ///
  /// In en, this message translates to:
  /// **'Import Mexico CSV or PDF'**
  String get dashImportMxCsvPdf;

  /// No description provided for @dashImportMxCsvPdfSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Drop a statement from {banks}.'**
  String dashImportMxCsvPdfSubtitle(Object banks);

  /// No description provided for @dashAddManualAccount.
  ///
  /// In en, this message translates to:
  /// **'Add a manual account'**
  String get dashAddManualAccount;

  /// No description provided for @dashAddManualAccountSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Track a cash balance, brokerage, or anything else by hand.'**
  String get dashAddManualAccountSubtitle;

  /// No description provided for @dashTrackMoneyLent.
  ///
  /// In en, this message translates to:
  /// **'Track money you\'ve lent'**
  String get dashTrackMoneyLent;

  /// No description provided for @dashTrackMoneyLentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Lend to friends or family? Record loans, reconcile repayments, and track interest.'**
  String get dashTrackMoneyLentSubtitle;

  /// No description provided for @dashConnectCryptoExchangeTile.
  ///
  /// In en, this message translates to:
  /// **'Connect a crypto exchange'**
  String get dashConnectCryptoExchangeTile;

  /// No description provided for @dashConnectCryptoExchangeTileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Link Coinbase or Bitso to track crypto alongside your accounts.'**
  String get dashConnectCryptoExchangeTileSubtitle;

  /// No description provided for @dashOnboardingWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Patrimonio'**
  String get dashOnboardingWelcome;

  /// No description provided for @dashOnboardingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Connect your first account to see your net worth, transactions, and projections in one place.'**
  String get dashOnboardingSubtitle;

  /// No description provided for @dashOnboardingAlreadyLinked.
  ///
  /// In en, this message translates to:
  /// **'Already linked accounts elsewhere? They will appear here as soon as the first sync completes.'**
  String get dashOnboardingAlreadyLinked;

  /// No description provided for @dashAccountLinkedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Account linked successfully!'**
  String get dashAccountLinkedSuccess;

  /// No description provided for @dashAccountLinkFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to link account. Please try again.'**
  String get dashAccountLinkFailed;

  /// No description provided for @dashReconnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Reconnect failed: {error}'**
  String dashReconnectFailed(Object error);

  /// No description provided for @dashWebhookPushed.
  ///
  /// In en, this message translates to:
  /// **'Webhook URL pushed to {count} institution(s)'**
  String dashWebhookPushed(Object count);

  /// No description provided for @dashWebhookPartial.
  ///
  /// In en, this message translates to:
  /// **'{updated} updated, {failed} failed'**
  String dashWebhookPartial(Object failed, Object updated);

  /// No description provided for @dashUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get dashUnknown;

  /// No description provided for @dashPushFailed.
  ///
  /// In en, this message translates to:
  /// **'Push failed: {error}'**
  String dashPushFailed(Object error);

  /// No description provided for @dashErrorLoading.
  ///
  /// In en, this message translates to:
  /// **'Error loading dashboard: {error}'**
  String dashErrorLoading(Object error);

  /// No description provided for @dashRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get dashRetry;

  /// No description provided for @dashUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {error}'**
  String dashUpdateFailed(Object error);

  /// No description provided for @dashAccountDeleted.
  ///
  /// In en, this message translates to:
  /// **'Account deleted'**
  String get dashAccountDeleted;

  /// No description provided for @dashDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String dashDeleteFailed(Object error);

  /// No description provided for @dashNicknameCleared.
  ///
  /// In en, this message translates to:
  /// **'Nickname cleared'**
  String get dashNicknameCleared;

  /// No description provided for @dashRenamedTo.
  ///
  /// In en, this message translates to:
  /// **'Renamed to \"{nickname}\"'**
  String dashRenamedTo(Object nickname);

  /// No description provided for @dashRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed: {error}'**
  String dashRenameFailed(Object error);

  /// No description provided for @dashRevalued.
  ///
  /// In en, this message translates to:
  /// **'Revalued'**
  String get dashRevalued;

  /// No description provided for @dashRevaluedNoteSaved.
  ///
  /// In en, this message translates to:
  /// **'Revalued · note saved'**
  String get dashRevaluedNoteSaved;

  /// No description provided for @dashRevalueFailed.
  ///
  /// In en, this message translates to:
  /// **'Revalue failed: {error}'**
  String dashRevalueFailed(Object error);

  /// No description provided for @dashNetWorthHistory.
  ///
  /// In en, this message translates to:
  /// **'Net worth history'**
  String get dashNetWorthHistory;

  /// No description provided for @dashSyncingAll.
  ///
  /// In en, this message translates to:
  /// **'Syncing all institutions…'**
  String get dashSyncingAll;

  /// No description provided for @dashSyncComplete.
  ///
  /// In en, this message translates to:
  /// **'Sync complete'**
  String get dashSyncComplete;

  /// No description provided for @dashSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync failed: {error}'**
  String dashSyncFailed(Object error);

  /// No description provided for @dashLaunchSetup.
  ///
  /// In en, this message translates to:
  /// **'Launch setup'**
  String get dashLaunchSetup;

  /// No description provided for @dashLaunchSetupReady.
  ///
  /// In en, this message translates to:
  /// **'Plaid linking can start. Optional services may still improve data quality.'**
  String get dashLaunchSetupReady;

  /// No description provided for @dashLaunchSetupBlocked.
  ///
  /// In en, this message translates to:
  /// **'Complete required setup before real users can link Plaid accounts.'**
  String get dashLaunchSetupBlocked;

  /// No description provided for @dashPushToInstitutions.
  ///
  /// In en, this message translates to:
  /// **'Push to {count} institution(s)'**
  String dashPushToInstitutions(Object count);

  /// No description provided for @dashRecommendedBeforeProduction.
  ///
  /// In en, this message translates to:
  /// **'Recommended before production: {labels}.'**
  String dashRecommendedBeforeProduction(Object labels);

  /// No description provided for @dashConfirmFailed.
  ///
  /// In en, this message translates to:
  /// **'Confirm failed: {error}'**
  String dashConfirmFailed(Object error);

  /// No description provided for @dashUnlinkFailed.
  ///
  /// In en, this message translates to:
  /// **'Unlink failed: {error}'**
  String dashUnlinkFailed(Object error);

  /// No description provided for @dashScanningTransfers.
  ///
  /// In en, this message translates to:
  /// **'Scanning for cross-currency transfers…'**
  String get dashScanningTransfers;

  /// No description provided for @dashTransfersLinked.
  ///
  /// In en, this message translates to:
  /// **'Linked {inserted} transfer pair(s) (checked {checked} candidates)'**
  String dashTransfersLinked(Object checked, Object inserted);

  /// No description provided for @dashNoNewTransfers.
  ///
  /// In en, this message translates to:
  /// **'No new transfers found'**
  String get dashNoNewTransfers;

  /// No description provided for @dashDetectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Detection failed: {error}'**
  String dashDetectionFailed(Object error);

  /// No description provided for @dashUpdateTransactionFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update transaction: {error}'**
  String dashUpdateTransactionFailed(Object error);

  /// No description provided for @dashTransactionDeleted.
  ///
  /// In en, this message translates to:
  /// **'Transaction deleted'**
  String get dashTransactionDeleted;

  /// No description provided for @dashLinkConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Link confirmed'**
  String get dashLinkConfirmed;

  /// No description provided for @dashPairUnlinked.
  ///
  /// In en, this message translates to:
  /// **'Pair unlinked'**
  String get dashPairUnlinked;

  /// No description provided for @dashMerchantHidden.
  ///
  /// In en, this message translates to:
  /// **'\"{merchant}\" hidden from subscriptions'**
  String dashMerchantHidden(Object merchant);

  /// No description provided for @dashFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String dashFailedGeneric(Object error);

  /// No description provided for @dashDataSources.
  ///
  /// In en, this message translates to:
  /// **'Data sources & sync'**
  String get dashDataSources;

  /// No description provided for @dashRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry failed: {error}'**
  String dashRetryFailed(Object error);

  /// No description provided for @dashDeleteInstitutionTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete institution'**
  String get dashDeleteInstitutionTitle;

  /// No description provided for @dashDeleteInstitutionBody.
  ///
  /// In en, this message translates to:
  /// **'Are you sure? This will remove ALL accounts and history for this institution.'**
  String get dashDeleteInstitutionBody;

  /// No description provided for @dashDeleteEverything.
  ///
  /// In en, this message translates to:
  /// **'Delete everything'**
  String get dashDeleteEverything;

  /// No description provided for @dashFxRateRefreshed.
  ///
  /// In en, this message translates to:
  /// **'FX rate refreshed'**
  String get dashFxRateRefreshed;

  /// No description provided for @dashRefreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Refresh failed: {error}'**
  String dashRefreshFailed(Object error);

  /// No description provided for @dashConnectStandardAccounts.
  ///
  /// In en, this message translates to:
  /// **'Connect standard accounts'**
  String get dashConnectStandardAccounts;

  /// No description provided for @dashSyncAllAccounts.
  ///
  /// In en, this message translates to:
  /// **'Sync all accounts'**
  String get dashSyncAllAccounts;

  /// No description provided for @dashLinkPlaidUsBanks.
  ///
  /// In en, this message translates to:
  /// **'Link Plaid (US Banks)'**
  String get dashLinkPlaidUsBanks;

  /// No description provided for @dashImportMxShort.
  ///
  /// In en, this message translates to:
  /// **'Import Mexico (CSV/PDF)'**
  String get dashImportMxShort;

  /// No description provided for @dashAddManualAccountShort.
  ///
  /// In en, this message translates to:
  /// **'Add manual account'**
  String get dashAddManualAccountShort;

  /// No description provided for @dashConnectCryptoExchanges.
  ///
  /// In en, this message translates to:
  /// **'Connect crypto exchanges'**
  String get dashConnectCryptoExchanges;

  /// No description provided for @dashLinkCoinbase.
  ///
  /// In en, this message translates to:
  /// **'Link Coinbase'**
  String get dashLinkCoinbase;

  /// No description provided for @dashConnectBitso.
  ///
  /// In en, this message translates to:
  /// **'Connect Bitso'**
  String get dashConnectBitso;

  /// No description provided for @dashHiddenItems.
  ///
  /// In en, this message translates to:
  /// **'Hidden items'**
  String get dashHiddenItems;

  /// No description provided for @dashSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get dashSecurity;

  /// No description provided for @dashSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get dashSignOut;

  /// No description provided for @dashThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System theme'**
  String get dashThemeSystem;

  /// No description provided for @dashThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light theme'**
  String get dashThemeLight;

  /// No description provided for @dashThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark theme'**
  String get dashThemeDark;

  /// No description provided for @dashThemeSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get dashThemeSystemDefault;

  /// No description provided for @dashThemeLightShort.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get dashThemeLightShort;

  /// No description provided for @dashThemeDarkShort.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dashThemeDarkShort;

  /// No description provided for @dashThemeTooltip.
  ///
  /// In en, this message translates to:
  /// **'{label} · tap to cycle, long-press to pick'**
  String dashThemeTooltip(Object label);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
