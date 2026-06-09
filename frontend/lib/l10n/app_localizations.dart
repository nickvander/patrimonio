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

  /// No description provided for @bmTitle.
  ///
  /// In en, this message translates to:
  /// **'Investments vs S&P 500'**
  String get bmTitle;

  /// No description provided for @bmSubtitle.
  ///
  /// In en, this message translates to:
  /// **'If your contributions had bought the index, by purchase date'**
  String get bmSubtitle;

  /// No description provided for @bmAheadPts.
  ///
  /// In en, this message translates to:
  /// **'You\'re ahead of the index by {pts} pts'**
  String bmAheadPts(Object pts);

  /// No description provided for @bmBehindPts.
  ///
  /// In en, this message translates to:
  /// **'The index is ahead by {pts} pts'**
  String bmBehindPts(Object pts);

  /// No description provided for @bmYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get bmYou;

  /// No description provided for @bmSp500.
  ///
  /// In en, this message translates to:
  /// **'S&P 500'**
  String get bmSp500;

  /// No description provided for @bmAhead.
  ///
  /// In en, this message translates to:
  /// **'You\'re ahead of the market by {pct}'**
  String bmAhead(Object pct);

  /// No description provided for @bmBehind.
  ///
  /// In en, this message translates to:
  /// **'The market is ahead by {pct}'**
  String bmBehind(Object pct);

  /// No description provided for @bmContribTitle.
  ///
  /// In en, this message translates to:
  /// **'By contribution date'**
  String get bmContribTitle;

  /// No description provided for @bmContribYou.
  ///
  /// In en, this message translates to:
  /// **'Your tracked lots'**
  String get bmContribYou;

  /// No description provided for @bmContribIndex.
  ///
  /// In en, this message translates to:
  /// **'Same money in S&P 500'**
  String get bmContribIndex;

  /// No description provided for @bmContribNote.
  ///
  /// In en, this message translates to:
  /// **'{count} purchases · {invested} invested'**
  String bmContribNote(Object count, Object invested);

  /// No description provided for @dpTitle.
  ///
  /// In en, this message translates to:
  /// **'Debt payoff'**
  String get dpTitle;

  /// No description provided for @dpMonthlyPayment.
  ///
  /// In en, this message translates to:
  /// **'Monthly payment'**
  String get dpMonthlyPayment;

  /// No description provided for @dpAvalanche.
  ///
  /// In en, this message translates to:
  /// **'Avalanche'**
  String get dpAvalanche;

  /// No description provided for @dpSnowball.
  ///
  /// In en, this message translates to:
  /// **'Snowball'**
  String get dpSnowball;

  /// No description provided for @dpAvalancheSub.
  ///
  /// In en, this message translates to:
  /// **'Highest rate first'**
  String get dpAvalancheSub;

  /// No description provided for @dpSnowballSub.
  ///
  /// In en, this message translates to:
  /// **'Smallest balance first'**
  String get dpSnowballSub;

  /// No description provided for @dpDebtFree.
  ///
  /// In en, this message translates to:
  /// **'{months} mo to debt-free'**
  String dpDebtFree(Object months);

  /// No description provided for @dpInterest.
  ///
  /// In en, this message translates to:
  /// **'{amount} interest'**
  String dpInterest(Object amount);

  /// No description provided for @dpRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get dpRecommended;

  /// No description provided for @dpSaves.
  ///
  /// In en, this message translates to:
  /// **'Saves {amount} vs snowball'**
  String dpSaves(Object amount);

  /// No description provided for @dpInfeasible.
  ///
  /// In en, this message translates to:
  /// **'Increase the monthly payment to cover minimums.'**
  String get dpInfeasible;

  /// No description provided for @dpSetApr.
  ///
  /// In en, this message translates to:
  /// **'Set APR'**
  String get dpSetApr;

  /// No description provided for @dpAprDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Interest rate (APR)'**
  String get dpAprDialogTitle;

  /// No description provided for @dpAprLabel.
  ///
  /// In en, this message translates to:
  /// **'Annual rate'**
  String get dpAprLabel;

  /// No description provided for @dpEditApr.
  ///
  /// In en, this message translates to:
  /// **'{name} rate'**
  String dpEditApr(Object name);

  /// No description provided for @efTitle.
  ///
  /// In en, this message translates to:
  /// **'Emergency fund'**
  String get efTitle;

  /// No description provided for @efMonthsUnit.
  ///
  /// In en, this message translates to:
  /// **'months of expenses'**
  String get efMonthsUnit;

  /// No description provided for @efStatusHealthy.
  ///
  /// In en, this message translates to:
  /// **'Fully funded'**
  String get efStatusHealthy;

  /// No description provided for @efStatusOnTrack.
  ///
  /// In en, this message translates to:
  /// **'On track'**
  String get efStatusOnTrack;

  /// No description provided for @efStatusBuilding.
  ///
  /// In en, this message translates to:
  /// **'Keep building'**
  String get efStatusBuilding;

  /// No description provided for @efCashLabel.
  ///
  /// In en, this message translates to:
  /// **'{amount} liquid cash'**
  String efCashLabel(Object amount);

  /// No description provided for @efSpendLabel.
  ///
  /// In en, this message translates to:
  /// **'{amount} / mo avg'**
  String efSpendLabel(Object amount);

  /// No description provided for @efScale0.
  ///
  /// In en, this message translates to:
  /// **'0'**
  String get efScale0;

  /// No description provided for @efScale3.
  ///
  /// In en, this message translates to:
  /// **'3 mo'**
  String get efScale3;

  /// No description provided for @efScale6.
  ///
  /// In en, this message translates to:
  /// **'6 mo+'**
  String get efScale6;

  /// No description provided for @efNoSpendTitle.
  ///
  /// In en, this message translates to:
  /// **'Runway not available yet'**
  String get efNoSpendTitle;

  /// No description provided for @efNoSpendBody.
  ///
  /// In en, this message translates to:
  /// **'Once you have about a month of transactions, we\'ll estimate how long your cash would last.'**
  String get efNoSpendBody;

  /// No description provided for @efNoCashHint.
  ///
  /// In en, this message translates to:
  /// **'No liquid cash detected — link a checking or savings account to track your runway.'**
  String get efNoCashHint;

  /// No description provided for @billsTitle.
  ///
  /// In en, this message translates to:
  /// **'Upcoming recurring bills'**
  String get billsTitle;

  /// No description provided for @billsNext12.
  ///
  /// In en, this message translates to:
  /// **'Projected · next 12 months'**
  String get billsNext12;

  /// No description provided for @rgTitle.
  ///
  /// In en, this message translates to:
  /// **'Realized gains'**
  String get rgTitle;

  /// No description provided for @rgThisYear.
  ///
  /// In en, this message translates to:
  /// **'This year'**
  String get rgThisYear;

  /// No description provided for @rgAllTime.
  ///
  /// In en, this message translates to:
  /// **'All time'**
  String get rgAllTime;

  /// No description provided for @rgProceeds.
  ///
  /// In en, this message translates to:
  /// **'Proceeds'**
  String get rgProceeds;

  /// No description provided for @rgCost.
  ///
  /// In en, this message translates to:
  /// **'Cost'**
  String get rgCost;

  /// No description provided for @rgLongTerm.
  ///
  /// In en, this message translates to:
  /// **'LT'**
  String get rgLongTerm;

  /// No description provided for @rgShortTerm.
  ///
  /// In en, this message translates to:
  /// **'ST'**
  String get rgShortTerm;

  /// No description provided for @rgMoreCount.
  ///
  /// In en, this message translates to:
  /// **'+{count} more disposals'**
  String rgMoreCount(Object count);

  /// No description provided for @spendByCatTitle.
  ///
  /// In en, this message translates to:
  /// **'Spending by category'**
  String get spendByCatTitle;

  /// No description provided for @spendByCatEmpty.
  ///
  /// In en, this message translates to:
  /// **'No spending recorded in this period yet.'**
  String get spendByCatEmpty;

  /// No description provided for @spendByCatTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get spendByCatTotal;

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

  /// No description provided for @cfBudgetsOverAlert.
  ///
  /// In en, this message translates to:
  /// **'Over budget in {count} — {amount} over total'**
  String cfBudgetsOverAlert(int count, String amount);

  /// No description provided for @cfBudgetsNearAlert.
  ///
  /// In en, this message translates to:
  /// **'Approaching budget in {count}'**
  String cfBudgetsNearAlert(Object count);

  /// No description provided for @cfBudgetsOverBy.
  ///
  /// In en, this message translates to:
  /// **'{amount} over'**
  String cfBudgetsOverBy(Object amount);

  /// No description provided for @cfBudgetsLeft.
  ///
  /// In en, this message translates to:
  /// **'{amount} left'**
  String cfBudgetsLeft(Object amount);

  /// No description provided for @cfBudgetsSuggest.
  ///
  /// In en, this message translates to:
  /// **'Suggest'**
  String get cfBudgetsSuggest;

  /// No description provided for @cfBudgetsSuggestTooltip.
  ///
  /// In en, this message translates to:
  /// **'Fill in budgets from your recent average spending'**
  String get cfBudgetsSuggestTooltip;

  /// No description provided for @cfBudgetsSuggestedSnack.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Added a budget for {count} category} other{Added budgets for {count} categories}}'**
  String cfBudgetsSuggestedSnack(int count);

  /// No description provided for @cfBudgetsSuggestNone.
  ///
  /// In en, this message translates to:
  /// **'No new suggestions — these are already budgeted, or there isn\'t enough recent spending to suggest from.'**
  String get cfBudgetsSuggestNone;

  /// No description provided for @cfBudgetsSuggestDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Suggested budgets'**
  String get cfBudgetsSuggestDialogTitle;

  /// No description provided for @cfBudgetsSuggestDialogSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Based on your last {months} months of spending. Pick the ones to add.'**
  String cfBudgetsSuggestDialogSubtitle(int months);

  /// No description provided for @cfBudgetsSuggestAvg.
  ///
  /// In en, this message translates to:
  /// **'Averages {amount}/mo'**
  String cfBudgetsSuggestAvg(String amount);

  /// No description provided for @cfBudgetsSuggestSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get cfBudgetsSuggestSelectAll;

  /// No description provided for @cfBudgetsSuggestClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get cfBudgetsSuggestClear;

  /// No description provided for @cfBudgetsSuggestApply.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Add} other{Add {count}}}'**
  String cfBudgetsSuggestApply(int count);

  /// No description provided for @cfBudgetsShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show {count} more'**
  String cfBudgetsShowAll(int count);

  /// No description provided for @cfBudgetsShowFewer.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get cfBudgetsShowFewer;

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

  /// No description provided for @impAlreadyImported.
  ///
  /// In en, this message translates to:
  /// **'Already imported'**
  String get impAlreadyImported;

  /// No description provided for @impCreateAccountForImport.
  ///
  /// In en, this message translates to:
  /// **'New account (e.g. Banamex)'**
  String get impCreateAccountForImport;

  /// No description provided for @impOcrHint.
  ///
  /// In en, this message translates to:
  /// **'Scanned or photographed statements are read with text recognition (OCR), which can take up to a minute each — this is normal, not stuck.'**
  String get impOcrHint;

  /// No description provided for @impCleanupTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage imports'**
  String get impCleanupTitle;

  /// No description provided for @impRecentImports.
  ///
  /// In en, this message translates to:
  /// **'Recent imports'**
  String get impRecentImports;

  /// No description provided for @impNoRecentImports.
  ///
  /// In en, this message translates to:
  /// **'No tracked imports yet. Imports you do from now on appear here and can be undone.'**
  String get impNoRecentImports;

  /// No description provided for @impUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get impUndo;

  /// No description provided for @impUndoImport.
  ///
  /// In en, this message translates to:
  /// **'Undo import'**
  String get impUndoImport;

  /// No description provided for @impUndoImportConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete all {count} transactions from this import?'**
  String impUndoImportConfirm(Object count);

  /// No description provided for @impDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get impDelete;

  /// No description provided for @impDeletedN.
  ///
  /// In en, this message translates to:
  /// **'Deleted {count} transactions'**
  String impDeletedN(Object count);

  /// No description provided for @impBulkDelete.
  ///
  /// In en, this message translates to:
  /// **'Clean up by account & date'**
  String get impBulkDelete;

  /// No description provided for @impBulkDeleteHint.
  ///
  /// In en, this message translates to:
  /// **'For imports done before this update (no batch). Removes transactions in the chosen account and date range.'**
  String get impBulkDeleteHint;

  /// No description provided for @impOnlyImported.
  ///
  /// In en, this message translates to:
  /// **'Only imported transactions'**
  String get impOnlyImported;

  /// No description provided for @impPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get impPreview;

  /// No description provided for @impWillDelete.
  ///
  /// In en, this message translates to:
  /// **'{count} transactions will be deleted'**
  String impWillDelete(Object count);

  /// No description provided for @impFrom.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get impFrom;

  /// No description provided for @impTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get impTo;

  /// No description provided for @impTransactionsLabel.
  ///
  /// In en, this message translates to:
  /// **'transactions'**
  String get impTransactionsLabel;

  /// No description provided for @impCleanupFillAll.
  ///
  /// In en, this message translates to:
  /// **'Pick an account and both dates'**
  String get impCleanupFillAll;

  /// No description provided for @impFileWaiting.
  ///
  /// In en, this message translates to:
  /// **'waiting…'**
  String get impFileWaiting;

  /// No description provided for @impFileParsing.
  ///
  /// In en, this message translates to:
  /// **'parsing…'**
  String get impFileParsing;

  /// No description provided for @impFileSkipped.
  ///
  /// In en, this message translates to:
  /// **'skipped'**
  String get impFileSkipped;

  /// No description provided for @impFileTransactions.
  ///
  /// In en, this message translates to:
  /// **'{count} transactions'**
  String impFileTransactions(Object count);

  /// No description provided for @impFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'\"{file}\" is {totalMb} MB, over the 100 MB limit for a single file — it can\'t be split. Try exporting a shorter statement period.'**
  String impFileTooLarge(Object file, Object totalMb);

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
  /// **'Import a statement (CSV or PDF)'**
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
  /// **'Import statement'**
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

  /// No description provided for @projTitle.
  ///
  /// In en, this message translates to:
  /// **'Wealth projection'**
  String get projTitle;

  /// No description provided for @projSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Project your financial future based on current assets and savings strategy.'**
  String get projSubtitle;

  /// No description provided for @projMonthlySavings.
  ///
  /// In en, this message translates to:
  /// **'Monthly savings'**
  String get projMonthlySavings;

  /// No description provided for @projExpectedReturn.
  ///
  /// In en, this message translates to:
  /// **'Expected return'**
  String get projExpectedReturn;

  /// No description provided for @projAnnualExpenses.
  ///
  /// In en, this message translates to:
  /// **'Annual expenses'**
  String get projAnnualExpenses;

  /// No description provided for @projSafeWithdrawalRate.
  ///
  /// In en, this message translates to:
  /// **'Safe withdrawal rate'**
  String get projSafeWithdrawalRate;

  /// No description provided for @projProjectionYears.
  ///
  /// In en, this message translates to:
  /// **'Projection years'**
  String get projProjectionYears;

  /// No description provided for @projGoal.
  ///
  /// In en, this message translates to:
  /// **'Goal'**
  String get projGoal;

  /// No description provided for @projClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get projClear;

  /// No description provided for @projGoalHitBy.
  ///
  /// In en, this message translates to:
  /// **'Hit {amount} by {year}'**
  String projGoalHitBy(Object amount, Object year);

  /// No description provided for @projGoalSetTarget.
  ///
  /// In en, this message translates to:
  /// **'Set a target — e.g. \$1M by 2030'**
  String get projGoalSetTarget;

  /// No description provided for @projSetTargetTitle.
  ///
  /// In en, this message translates to:
  /// **'Set a target'**
  String get projSetTargetTitle;

  /// No description provided for @projTargetNetWorth.
  ///
  /// In en, this message translates to:
  /// **'Target net worth'**
  String get projTargetNetWorth;

  /// No description provided for @projTargetYear.
  ///
  /// In en, this message translates to:
  /// **'Target year'**
  String get projTargetYear;

  /// No description provided for @projNetWorthProjection.
  ///
  /// In en, this message translates to:
  /// **'Net worth projection'**
  String get projNetWorthProjection;

  /// No description provided for @projScenarios.
  ///
  /// In en, this message translates to:
  /// **'Scenarios'**
  String get projScenarios;

  /// No description provided for @projYearAxisLabel.
  ///
  /// In en, this message translates to:
  /// **'Yr {year}'**
  String projYearAxisLabel(Object year);

  /// No description provided for @projTooltipYearAmount.
  ///
  /// In en, this message translates to:
  /// **'Year {year}\n{amount}'**
  String projTooltipYearAmount(Object amount, Object year);

  /// No description provided for @projFiNumber.
  ///
  /// In en, this message translates to:
  /// **'FI number'**
  String get projFiNumber;

  /// No description provided for @projProgress.
  ///
  /// In en, this message translates to:
  /// **'Progress'**
  String get projProgress;

  /// No description provided for @projTowardFire.
  ///
  /// In en, this message translates to:
  /// **'Toward FIRE'**
  String get projTowardFire;

  /// No description provided for @projYearsToFi.
  ///
  /// In en, this message translates to:
  /// **'Years to FI'**
  String get projYearsToFi;

  /// No description provided for @projEstimate.
  ///
  /// In en, this message translates to:
  /// **'Estimate'**
  String get projEstimate;

  /// No description provided for @projFiIncome.
  ///
  /// In en, this message translates to:
  /// **'FI income'**
  String get projFiIncome;

  /// No description provided for @projMonthlyAtWithdrawalRate.
  ///
  /// In en, this message translates to:
  /// **'Monthly @ withdrawal rate'**
  String get projMonthlyAtWithdrawalRate;

  /// No description provided for @projInflation.
  ///
  /// In en, this message translates to:
  /// **'Inflation'**
  String get projInflation;

  /// No description provided for @projYearsToRetirement.
  ///
  /// In en, this message translates to:
  /// **'Years to retirement'**
  String get projYearsToRetirement;

  /// No description provided for @projVolatility.
  ///
  /// In en, this message translates to:
  /// **'Return volatility'**
  String get projVolatility;

  /// No description provided for @projExpectedReturnNominal.
  ///
  /// In en, this message translates to:
  /// **'Expected return (nominal)'**
  String get projExpectedReturnNominal;

  /// No description provided for @projRange.
  ///
  /// In en, this message translates to:
  /// **'Range'**
  String get projRange;

  /// No description provided for @projRealNote.
  ///
  /// In en, this message translates to:
  /// **'All figures in today\'s dollars'**
  String get projRealNote;

  /// No description provided for @projSuccessRate.
  ///
  /// In en, this message translates to:
  /// **'Success rate'**
  String get projSuccessRate;

  /// No description provided for @projSuccessRateSub.
  ///
  /// In en, this message translates to:
  /// **'Chance the plan lasts the horizon'**
  String get projSuccessRateSub;

  /// No description provided for @projMedian.
  ///
  /// In en, this message translates to:
  /// **'Median outcome'**
  String get projMedian;

  /// No description provided for @projMedianSub.
  ///
  /// In en, this message translates to:
  /// **'Most likely path (50th pct)'**
  String get projMedianSub;

  /// No description provided for @projCoastReached.
  ///
  /// In en, this message translates to:
  /// **'Coast FIRE reached'**
  String get projCoastReached;

  /// No description provided for @projCoastReachedSub.
  ///
  /// In en, this message translates to:
  /// **'Growth alone reaches your goal — you can stop contributing.'**
  String get projCoastReachedSub;

  /// No description provided for @projCoastNeed.
  ///
  /// In en, this message translates to:
  /// **'Coast FIRE: need {amount} invested today'**
  String projCoastNeed(Object amount);

  /// No description provided for @projCoastNeedSub.
  ///
  /// In en, this message translates to:
  /// **'Invest this much now and growth alone gets you to FI by retirement.'**
  String get projCoastNeedSub;

  /// No description provided for @projBaristaFi.
  ///
  /// In en, this message translates to:
  /// **'Barista FI number'**
  String get projBaristaFi;

  /// No description provided for @projBaristaIncome.
  ///
  /// In en, this message translates to:
  /// **'Retirement income (SS/pension)'**
  String get projBaristaIncome;

  /// No description provided for @projFromYourData.
  ///
  /// In en, this message translates to:
  /// **'From your tracked spending'**
  String get projFromYourData;

  /// No description provided for @projBandLegend.
  ///
  /// In en, this message translates to:
  /// **'10th–90th percentile range'**
  String get projBandLegend;

  /// No description provided for @projTaxDrag.
  ///
  /// In en, this message translates to:
  /// **'Tax drag'**
  String get projTaxDrag;

  /// No description provided for @projGuardrails.
  ///
  /// In en, this message translates to:
  /// **'Spending guardrails'**
  String get projGuardrails;

  /// No description provided for @projGuardrailsOn.
  ///
  /// In en, this message translates to:
  /// **'Guardrails on — spending flexes with the market'**
  String get projGuardrailsOn;

  /// No description provided for @projGuardrailsOff.
  ///
  /// In en, this message translates to:
  /// **'Fixed spending — no adjustment in downturns'**
  String get projGuardrailsOff;

  /// No description provided for @taxTitle.
  ///
  /// In en, this message translates to:
  /// **'Tax planning'**
  String get taxTitle;

  /// No description provided for @taxFilingSingle.
  ///
  /// In en, this message translates to:
  /// **'Single'**
  String get taxFilingSingle;

  /// No description provided for @taxFilingMarried.
  ///
  /// In en, this message translates to:
  /// **'Married'**
  String get taxFilingMarried;

  /// No description provided for @taxFilingHeadOfHousehold.
  ///
  /// In en, this message translates to:
  /// **'Head of Household'**
  String get taxFilingHeadOfHousehold;

  /// No description provided for @taxCsvLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not launch CSV export.'**
  String get taxCsvLaunchFailed;

  /// No description provided for @taxPdfLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not launch PDF export.'**
  String get taxPdfLaunchFailed;

  /// No description provided for @taxLoadError.
  ///
  /// In en, this message translates to:
  /// **'Error loading tax data: {error}'**
  String taxLoadError(Object error);

  /// No description provided for @taxRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get taxRetry;

  /// No description provided for @taxExportCsv.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get taxExportCsv;

  /// No description provided for @taxExportPdf.
  ///
  /// In en, this message translates to:
  /// **'PDF'**
  String get taxExportPdf;

  /// No description provided for @taxTotalTaxableIncome.
  ///
  /// In en, this message translates to:
  /// **'Total taxable income'**
  String get taxTotalTaxableIncome;

  /// No description provided for @taxOrdinaryIncome.
  ///
  /// In en, this message translates to:
  /// **'Ordinary income: {amount}'**
  String taxOrdinaryIncome(Object amount);

  /// No description provided for @taxCapitalGains.
  ///
  /// In en, this message translates to:
  /// **'Capital gains: {amount}'**
  String taxCapitalGains(Object amount);

  /// No description provided for @taxStLtBreakdown.
  ///
  /// In en, this message translates to:
  /// **'Short-term {st} · Long-term {lt}'**
  String taxStLtBreakdown(String st, String lt);

  /// No description provided for @taxUsEstimatedLiability.
  ///
  /// In en, this message translates to:
  /// **'US estimated liability (IRS)'**
  String get taxUsEstimatedLiability;

  /// No description provided for @taxMxEstimatedLiability.
  ///
  /// In en, this message translates to:
  /// **'MX estimated liability (SAT)'**
  String get taxMxEstimatedLiability;

  /// No description provided for @taxEffectiveRate.
  ///
  /// In en, this message translates to:
  /// **'Effective rate: {rate}%'**
  String taxEffectiveRate(Object rate);

  /// No description provided for @taxTaxableEvents.
  ///
  /// In en, this message translates to:
  /// **'Taxable events'**
  String get taxTaxableEvents;

  /// No description provided for @taxNoEventsTitle.
  ///
  /// In en, this message translates to:
  /// **'No taxable events found for this year.'**
  String get taxNoEventsTitle;

  /// No description provided for @taxNoEventsBody.
  ///
  /// In en, this message translates to:
  /// **'Income, salary, interest, and investment sale transactions will appear here.'**
  String get taxNoEventsBody;

  /// No description provided for @taxDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'Disclaimer: Tax estimates are approximations using 2026 IRS/SAT brackets. Consult a qualified tax professional for filing.'**
  String get taxDisclaimer;

  /// No description provided for @acctxRenameAccount.
  ///
  /// In en, this message translates to:
  /// **'Rename account'**
  String get acctxRenameAccount;

  /// No description provided for @acctxNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get acctxNickname;

  /// No description provided for @acctxAccountFallback.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get acctxAccountFallback;

  /// No description provided for @acctxUpdateBalanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Update {account} balance'**
  String acctxUpdateBalanceTitle(Object account);

  /// No description provided for @acctxCurrentBalance.
  ///
  /// In en, this message translates to:
  /// **'Current balance'**
  String get acctxCurrentBalance;

  /// No description provided for @acctxAccountActions.
  ///
  /// In en, this message translates to:
  /// **'Account actions'**
  String get acctxAccountActions;

  /// No description provided for @acctxUpdateBalance.
  ///
  /// In en, this message translates to:
  /// **'Update balance'**
  String get acctxUpdateBalance;

  /// No description provided for @acctxLoadError.
  ///
  /// In en, this message translates to:
  /// **'Error loading transactions: {error}'**
  String acctxLoadError(Object error);

  /// No description provided for @acctxRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get acctxRetry;

  /// No description provided for @acctxBalanceOverTime.
  ///
  /// In en, this message translates to:
  /// **'Balance over time'**
  String get acctxBalanceOverTime;

  /// No description provided for @acctxSetLowBalanceAlert.
  ///
  /// In en, this message translates to:
  /// **'Set low-balance alert'**
  String get acctxSetLowBalanceAlert;

  /// No description provided for @acctxEditLowBalanceAlert.
  ///
  /// In en, this message translates to:
  /// **'Edit low-balance alert'**
  String get acctxEditLowBalanceAlert;

  /// No description provided for @acctxLowBalanceAlertTitle.
  ///
  /// In en, this message translates to:
  /// **'Low-balance alert'**
  String get acctxLowBalanceAlertTitle;

  /// No description provided for @acctxLowBalanceAlertBody.
  ///
  /// In en, this message translates to:
  /// **'We\'ll flag this account and add a notification when its balance drops to or below this amount.'**
  String get acctxLowBalanceAlertBody;

  /// No description provided for @acctxThresholdLabel.
  ///
  /// In en, this message translates to:
  /// **'Alert me below'**
  String get acctxThresholdLabel;

  /// No description provided for @acctxRemoveAlert.
  ///
  /// In en, this message translates to:
  /// **'Remove alert'**
  String get acctxRemoveAlert;

  /// No description provided for @acctxAlertSaved.
  ///
  /// In en, this message translates to:
  /// **'Low-balance alert saved'**
  String get acctxAlertSaved;

  /// No description provided for @acctxAlertRemoved.
  ///
  /// In en, this message translates to:
  /// **'Low-balance alert removed'**
  String get acctxAlertRemoved;

  /// No description provided for @acctxLowBalanceBanner.
  ///
  /// In en, this message translates to:
  /// **'Balance is at or below your {amount} alert'**
  String acctxLowBalanceBanner(Object amount);

  /// No description provided for @acctxNoTransactionsTitle.
  ///
  /// In en, this message translates to:
  /// **'No transactions yet'**
  String get acctxNoTransactionsTitle;

  /// No description provided for @acctxNoTransactionsBody.
  ///
  /// In en, this message translates to:
  /// **'Records might just be starting, or offline accounts have no history.'**
  String get acctxNoTransactionsBody;

  /// No description provided for @acctxUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update transaction: {error}'**
  String acctxUpdateFailed(Object error);

  /// No description provided for @acctxDismissBarrier.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get acctxDismissBarrier;

  /// No description provided for @hiddenTitle.
  ///
  /// In en, this message translates to:
  /// **'Hidden items'**
  String get hiddenTitle;

  /// No description provided for @hiddenRestoredMerchant.
  ///
  /// In en, this message translates to:
  /// **'Restored \"{merchant}\"'**
  String hiddenRestoredMerchant(Object merchant);

  /// No description provided for @hiddenRestoreFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to restore: {error}'**
  String hiddenRestoreFailed(Object error);

  /// No description provided for @hiddenBannerWillReappear.
  ///
  /// In en, this message translates to:
  /// **'Since-last-login banner will reappear.'**
  String get hiddenBannerWillReappear;

  /// No description provided for @hiddenFxPairRestored.
  ///
  /// In en, this message translates to:
  /// **'Restored — the detector may re-propose {summary} on the next sync.'**
  String hiddenFxPairRestored(Object summary);

  /// No description provided for @hiddenIntro.
  ///
  /// In en, this message translates to:
  /// **'Things you told Patrimonio to stop showing. Restoring a row brings it back where it normally lives.'**
  String get hiddenIntro;

  /// No description provided for @hiddenRecurringCharges.
  ///
  /// In en, this message translates to:
  /// **'Recurring charges'**
  String get hiddenRecurringCharges;

  /// No description provided for @hiddenNoSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'No subscriptions are currently hidden. When you dismiss a row with × on the Recurring charges card it shows up here.'**
  String get hiddenNoSubscriptions;

  /// No description provided for @hiddenBanners.
  ///
  /// In en, this message translates to:
  /// **'Banners'**
  String get hiddenBanners;

  /// No description provided for @hiddenNoBanners.
  ///
  /// In en, this message translates to:
  /// **'No banners are currently dismissed.'**
  String get hiddenNoBanners;

  /// No description provided for @hiddenSinceLastLogin.
  ///
  /// In en, this message translates to:
  /// **'Since last login'**
  String get hiddenSinceLastLogin;

  /// No description provided for @hiddenHiddenForVisit.
  ///
  /// In en, this message translates to:
  /// **'Hidden for the visit starting {date}'**
  String hiddenHiddenForVisit(Object date);

  /// No description provided for @hiddenShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Show again'**
  String get hiddenShowAgain;

  /// No description provided for @hiddenFxTransferPairs.
  ///
  /// In en, this message translates to:
  /// **'FX-transfer pairs'**
  String get hiddenFxTransferPairs;

  /// No description provided for @hiddenNoFxPairs.
  ///
  /// In en, this message translates to:
  /// **'No FX pairs are currently dismissed. When you unlink a detected Wise / Remitly / Xoom transfer on the Transactions tab, it lands here so the detector won\'t re-propose it.'**
  String get hiddenNoFxPairs;

  /// No description provided for @hiddenDismissedAt.
  ///
  /// In en, this message translates to:
  /// **'Dismissed {date}'**
  String hiddenDismissedAt(Object date);

  /// No description provided for @hiddenRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get hiddenRestore;

  /// No description provided for @cbTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect bank'**
  String get cbTitle;

  /// No description provided for @cbSetupIncompleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Plaid setup is incomplete.'**
  String get cbSetupIncompleteTitle;

  /// No description provided for @cbSetupIncompleteBody.
  ///
  /// In en, this message translates to:
  /// **'Set Plaid credentials and ENCRYPTION_KEY before linking real bank accounts.'**
  String get cbSetupIncompleteBody;

  /// No description provided for @cbConnectWithPlaid.
  ///
  /// In en, this message translates to:
  /// **'Connect with Plaid'**
  String get cbConnectWithPlaid;

  /// No description provided for @cbEnvSandbox.
  ///
  /// In en, this message translates to:
  /// **'Plaid Sandbox Mode — Mock data only'**
  String get cbEnvSandbox;

  /// No description provided for @cbEnvDevelopment.
  ///
  /// In en, this message translates to:
  /// **'Plaid Development Mode — Real account data (test items)'**
  String get cbEnvDevelopment;

  /// No description provided for @cbEnvProduction.
  ///
  /// In en, this message translates to:
  /// **'Plaid Production Mode — Real account data'**
  String get cbEnvProduction;

  /// No description provided for @cbEnvUnknown.
  ///
  /// In en, this message translates to:
  /// **'Plaid Environment: {env}'**
  String cbEnvUnknown(Object env);

  /// No description provided for @cbConnected.
  ///
  /// In en, this message translates to:
  /// **'Bank connected. Initial sync has started.'**
  String get cbConnected;

  /// No description provided for @cbExchangeTokenFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to exchange token'**
  String get cbExchangeTokenFailed;

  /// No description provided for @cbBackendCommError.
  ///
  /// In en, this message translates to:
  /// **'Error communicating with backend: {error}'**
  String cbBackendCommError(Object error);

  /// No description provided for @cbLinkTokenFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to retrieve link token'**
  String get cbLinkTokenFailed;

  /// No description provided for @cbBackendConnectError.
  ///
  /// In en, this message translates to:
  /// **'Error connecting to backend: {error}'**
  String cbBackendConnectError(Object error);

  /// No description provided for @cbHttpError.
  ///
  /// In en, this message translates to:
  /// **'{fallback}: HTTP {status}'**
  String cbHttpError(Object fallback, Object status);

  /// No description provided for @cbPlaidError.
  ///
  /// In en, this message translates to:
  /// **'Plaid Error: {message}'**
  String cbPlaidError(Object message);

  /// No description provided for @pfAssetBreakdown.
  ///
  /// In en, this message translates to:
  /// **'Asset breakdown'**
  String get pfAssetBreakdown;

  /// No description provided for @pfByType.
  ///
  /// In en, this message translates to:
  /// **'By type'**
  String get pfByType;

  /// No description provided for @pfByInstitution.
  ///
  /// In en, this message translates to:
  /// **'By institution'**
  String get pfByInstitution;

  /// No description provided for @pfOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get pfOther;

  /// No description provided for @pfBank.
  ///
  /// In en, this message translates to:
  /// **'Bank'**
  String get pfBank;

  /// No description provided for @pfNetWorthGoal.
  ///
  /// In en, this message translates to:
  /// **'Net-worth goal'**
  String get pfNetWorthGoal;

  /// No description provided for @pfGoalDueNow.
  ///
  /// In en, this message translates to:
  /// **'due now'**
  String get pfGoalDueNow;

  /// No description provided for @pfGoalYearsLeft.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 year left} other{{count} years left}}'**
  String pfGoalYearsLeft(int count);

  /// No description provided for @pfGoalHitBy.
  ///
  /// In en, this message translates to:
  /// **'Hit {amount} by {year} · {remaining}'**
  String pfGoalHitBy(Object amount, Object remaining, Object year);

  /// No description provided for @pfGoalCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current: {amount}'**
  String pfGoalCurrent(Object amount);

  /// No description provided for @pfShowingBands.
  ///
  /// In en, this message translates to:
  /// **'Showing per-institution bands'**
  String get pfShowingBands;

  /// No description provided for @pfShowingLine.
  ///
  /// In en, this message translates to:
  /// **'Showing only the net worth line'**
  String get pfShowingLine;

  /// No description provided for @pfSimple.
  ///
  /// In en, this message translates to:
  /// **'Simple'**
  String get pfSimple;

  /// No description provided for @pfDetailed.
  ///
  /// In en, this message translates to:
  /// **'Detailed'**
  String get pfDetailed;

  /// No description provided for @pfTotalNetWorthCurrency.
  ///
  /// In en, this message translates to:
  /// **'Total net worth ({currency})'**
  String pfTotalNetWorthCurrency(Object currency);

  /// No description provided for @pfTotalNetWorth.
  ///
  /// In en, this message translates to:
  /// **'Total net worth'**
  String get pfTotalNetWorth;

  /// No description provided for @pfTooltipNetWorth.
  ///
  /// In en, this message translates to:
  /// **'Net worth: {value}'**
  String pfTooltipNetWorth(Object value);

  /// No description provided for @pfTooltipAssets.
  ///
  /// In en, this message translates to:
  /// **'Assets: {value}'**
  String pfTooltipAssets(Object value);

  /// No description provided for @pfTooltipLiabilities.
  ///
  /// In en, this message translates to:
  /// **'Liabilities: {value}'**
  String pfTooltipLiabilities(Object value);

  /// No description provided for @pfDeltaVsAgo.
  ///
  /// In en, this message translates to:
  /// **'vs {window} ago'**
  String pfDeltaVsAgo(Object window);

  /// No description provided for @pfNoAccountsYet.
  ///
  /// In en, this message translates to:
  /// **'No accounts yet'**
  String get pfNoAccountsYet;

  /// No description provided for @pfNoAccountsBody.
  ///
  /// In en, this message translates to:
  /// **'Link a bank, import a CSV, or add a manual account to\nget started.'**
  String get pfNoAccountsBody;

  /// No description provided for @pfAddAnAccount.
  ///
  /// In en, this message translates to:
  /// **'Add an account'**
  String get pfAddAnAccount;

  /// No description provided for @pfAccountsHeader.
  ///
  /// In en, this message translates to:
  /// **'ACCOUNTS'**
  String get pfAccountsHeader;

  /// No description provided for @pfGroupCash.
  ///
  /// In en, this message translates to:
  /// **'Cash'**
  String get pfGroupCash;

  /// No description provided for @pfGroupInvestments.
  ///
  /// In en, this message translates to:
  /// **'Investments'**
  String get pfGroupInvestments;

  /// No description provided for @pfGroupCrypto.
  ///
  /// In en, this message translates to:
  /// **'Crypto'**
  String get pfGroupCrypto;

  /// No description provided for @pfGroupCreditCards.
  ///
  /// In en, this message translates to:
  /// **'Credit cards'**
  String get pfGroupCreditCards;

  /// No description provided for @pfGroupLoans.
  ///
  /// In en, this message translates to:
  /// **'Loans & mortgages'**
  String get pfGroupLoans;

  /// No description provided for @pfGroupRealAssets.
  ///
  /// In en, this message translates to:
  /// **'Real assets'**
  String get pfGroupRealAssets;

  /// No description provided for @pfGroupOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get pfGroupOther;

  /// No description provided for @pfUnknownSubtypes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Unknown subtype: {list}} other{Unknown subtypes: {list}}}'**
  String pfUnknownSubtypes(int count, Object list);

  /// No description provided for @pfVaults.
  ///
  /// In en, this message translates to:
  /// **'Vaults'**
  String get pfVaults;

  /// No description provided for @pfBase.
  ///
  /// In en, this message translates to:
  /// **'base'**
  String get pfBase;

  /// No description provided for @pfAccountsDescriptor.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get pfAccountsDescriptor;

  /// No description provided for @pfInstDescriptor.
  ///
  /// In en, this message translates to:
  /// **'{inst} · {descriptor}'**
  String pfInstDescriptor(Object descriptor, Object inst);

  /// No description provided for @pfVault.
  ///
  /// In en, this message translates to:
  /// **'Vault'**
  String get pfVault;

  /// No description provided for @pfUnknownAccount.
  ///
  /// In en, this message translates to:
  /// **'Unknown account'**
  String get pfUnknownAccount;

  /// No description provided for @pfAccountActions.
  ///
  /// In en, this message translates to:
  /// **'Account actions'**
  String get pfAccountActions;

  /// No description provided for @pfRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get pfRename;

  /// No description provided for @pfRevalue.
  ///
  /// In en, this message translates to:
  /// **'Revalue'**
  String get pfRevalue;

  /// No description provided for @pfDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get pfDelete;

  /// No description provided for @pfDeleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get pfDeleteAccountTitle;

  /// No description provided for @pfDeleteAccountConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"? This will remove all its history.'**
  String pfDeleteAccountConfirm(Object name);

  /// No description provided for @pfRevalueTitle.
  ///
  /// In en, this message translates to:
  /// **'Revalue {name}'**
  String pfRevalueTitle(Object name);

  /// No description provided for @pfRevalueCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current: {amount} {currency}'**
  String pfRevalueCurrent(Object amount, Object currency);

  /// No description provided for @pfNewBalance.
  ///
  /// In en, this message translates to:
  /// **'New balance'**
  String get pfNewBalance;

  /// No description provided for @pfNotesOptional.
  ///
  /// In en, this message translates to:
  /// **'Notes (optional)'**
  String get pfNotesOptional;

  /// No description provided for @pfNotesHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Zillow estimate, 2026 appraisal, last round'**
  String get pfNotesHint;

  /// No description provided for @pfHistoryPointNote.
  ///
  /// In en, this message translates to:
  /// **'A new history point is recorded with today\'s date.'**
  String get pfHistoryPointNote;

  /// No description provided for @pfEnterNumericBalance.
  ///
  /// In en, this message translates to:
  /// **'Enter a numeric balance'**
  String get pfEnterNumericBalance;

  /// No description provided for @pfAssetFallback.
  ///
  /// In en, this message translates to:
  /// **'asset'**
  String get pfAssetFallback;

  /// No description provided for @pfRenameAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename account'**
  String get pfRenameAccountTitle;

  /// No description provided for @pfRenameOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original: {name}'**
  String pfRenameOriginal(Object name);

  /// No description provided for @pfNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get pfNickname;

  /// No description provided for @pfNicknameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Joint checking'**
  String get pfNicknameHint;

  /// No description provided for @pfRenameBlankHint.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to clear and use the bank name.'**
  String get pfRenameBlankHint;

  /// No description provided for @pfInvestmentPortfolio.
  ///
  /// In en, this message translates to:
  /// **'Investment portfolio'**
  String get pfInvestmentPortfolio;

  /// No description provided for @pfTotalValue.
  ///
  /// In en, this message translates to:
  /// **'Total value'**
  String get pfTotalValue;

  /// No description provided for @pfProfitLoss.
  ///
  /// In en, this message translates to:
  /// **'Profit / Loss'**
  String get pfProfitLoss;

  /// No description provided for @pfUsDollar.
  ///
  /// In en, this message translates to:
  /// **'US Dollar'**
  String get pfUsDollar;

  /// No description provided for @pfMexicanPeso.
  ///
  /// In en, this message translates to:
  /// **'Mexican Peso'**
  String get pfMexicanPeso;

  /// No description provided for @pfHoldings.
  ///
  /// In en, this message translates to:
  /// **'Holdings'**
  String get pfHoldings;

  /// No description provided for @pfAccountsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 account} other{{count} accounts}}'**
  String pfAccountsCount(int count);

  /// No description provided for @pfTopPosition.
  ///
  /// In en, this message translates to:
  /// **'Top position'**
  String get pfTopPosition;

  /// No description provided for @pfBiggestGainer.
  ///
  /// In en, this message translates to:
  /// **'Biggest gainer'**
  String get pfBiggestGainer;

  /// No description provided for @pfBiggestLoser.
  ///
  /// In en, this message translates to:
  /// **'Biggest loser'**
  String get pfBiggestLoser;

  /// No description provided for @pfSignalsTitle.
  ///
  /// In en, this message translates to:
  /// **'Signals'**
  String get pfSignalsTitle;

  /// No description provided for @pfConcentrated.
  ///
  /// In en, this message translates to:
  /// **'Concentrated'**
  String get pfConcentrated;

  /// No description provided for @pfViewLots.
  ///
  /// In en, this message translates to:
  /// **'View lots'**
  String get pfViewLots;

  /// No description provided for @pfUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get pfUnknown;

  /// No description provided for @pfInstPositions.
  ///
  /// In en, this message translates to:
  /// **'{inst} · {count, plural, =1{1 position} other{{count} positions}}'**
  String pfInstPositions(Object inst, int count);

  /// No description provided for @pfSharesSuffix.
  ///
  /// In en, this message translates to:
  /// **'{qty} sh'**
  String pfSharesSuffix(Object qty);

  /// No description provided for @pfCategoryFilter.
  ///
  /// In en, this message translates to:
  /// **'Category: {category}'**
  String pfCategoryFilter(Object category);

  /// No description provided for @pfSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search ticker, name, account, or institution…'**
  String get pfSearchHint;

  /// No description provided for @pfHoldingsAccountsCount.
  ///
  /// In en, this message translates to:
  /// **'{holdings, plural, =1{1 holding} other{{holdings} holdings}} · {accounts, plural, =1{1 account} other{{accounts} accounts}}'**
  String pfHoldingsAccountsCount(int accounts, int holdings);

  /// No description provided for @pfShownOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{shown} of {total}'**
  String pfShownOfTotal(Object shown, Object total);

  /// No description provided for @pfFlat.
  ///
  /// In en, this message translates to:
  /// **'Flat'**
  String get pfFlat;

  /// No description provided for @pfByAccount.
  ///
  /// In en, this message translates to:
  /// **'By account'**
  String get pfByAccount;

  /// No description provided for @pfNoHoldingsYet.
  ///
  /// In en, this message translates to:
  /// **'No holdings yet'**
  String get pfNoHoldingsYet;

  /// No description provided for @pfNoHoldingsBody.
  ///
  /// In en, this message translates to:
  /// **'Once you link a brokerage with Plaid (or import a CSV) your\npositions will appear here.'**
  String get pfNoHoldingsBody;

  /// No description provided for @pfHoldingsShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show all {count} holdings'**
  String pfHoldingsShowAll(int count);

  /// No description provided for @pfHoldingsShowFewer.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get pfHoldingsShowFewer;

  /// No description provided for @pfColAsset.
  ///
  /// In en, this message translates to:
  /// **'Asset'**
  String get pfColAsset;

  /// No description provided for @pfColShares.
  ///
  /// In en, this message translates to:
  /// **'Shares'**
  String get pfColShares;

  /// No description provided for @pfColPrice.
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get pfColPrice;

  /// No description provided for @pfColValue.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get pfColValue;

  /// No description provided for @pfColCostBasis.
  ///
  /// In en, this message translates to:
  /// **'Cost basis'**
  String get pfColCostBasis;

  /// No description provided for @pfColGain.
  ///
  /// In en, this message translates to:
  /// **'Gain'**
  String get pfColGain;

  /// No description provided for @pfColReturn.
  ///
  /// In en, this message translates to:
  /// **'Return'**
  String get pfColReturn;

  /// No description provided for @pfShares.
  ///
  /// In en, this message translates to:
  /// **'sh'**
  String get pfShares;

  /// No description provided for @pfHolding.
  ///
  /// In en, this message translates to:
  /// **'Holding'**
  String get pfHolding;

  /// No description provided for @pfLotBreakdownTitle.
  ///
  /// In en, this message translates to:
  /// **'Lot breakdown · {title}'**
  String pfLotBreakdownTitle(Object title);

  /// No description provided for @pfLotBreakdownSubtitle.
  ///
  /// In en, this message translates to:
  /// **'FIFO order. Cost basis sums each lot at its historical USD/native FX rate, not today\'s.'**
  String get pfLotBreakdownSubtitle;

  /// No description provided for @pfLotAcquired.
  ///
  /// In en, this message translates to:
  /// **'Acquired'**
  String get pfLotAcquired;

  /// No description provided for @pfLotQty.
  ///
  /// In en, this message translates to:
  /// **'Qty'**
  String get pfLotQty;

  /// No description provided for @pfLotCostPerUnit.
  ///
  /// In en, this message translates to:
  /// **'Cost / unit'**
  String get pfLotCostPerUnit;

  /// No description provided for @pfLotFxAtLot.
  ///
  /// In en, this message translates to:
  /// **'FX at lot'**
  String get pfLotFxAtLot;

  /// No description provided for @pfLotUsdCost.
  ///
  /// In en, this message translates to:
  /// **'USD cost'**
  String get pfLotUsdCost;

  /// No description provided for @dlgAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Add manual account'**
  String get dlgAccountTitle;

  /// No description provided for @dlgAccountName.
  ///
  /// In en, this message translates to:
  /// **'Account name'**
  String get dlgAccountName;

  /// No description provided for @dlgAccountNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. My savings, Rental property'**
  String get dlgAccountNameHint;

  /// No description provided for @dlgAccountType.
  ///
  /// In en, this message translates to:
  /// **'Account type'**
  String get dlgAccountType;

  /// No description provided for @dlgAccountClabe.
  ///
  /// In en, this message translates to:
  /// **'CLABE'**
  String get dlgAccountClabe;

  /// No description provided for @dlgAccountHolder.
  ///
  /// In en, this message translates to:
  /// **'Account holder'**
  String get dlgAccountHolder;

  /// No description provided for @dlgAccountClabeInvalid.
  ///
  /// In en, this message translates to:
  /// **'CLABE must be 18 digits'**
  String get dlgAccountClabeInvalid;

  /// No description provided for @acctTypeChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get acctTypeChecking;

  /// No description provided for @acctTypeSavings.
  ///
  /// In en, this message translates to:
  /// **'Savings'**
  String get acctTypeSavings;

  /// No description provided for @acctTypeCD.
  ///
  /// In en, this message translates to:
  /// **'Certificate of deposit'**
  String get acctTypeCD;

  /// No description provided for @acctTypeBrokerage.
  ///
  /// In en, this message translates to:
  /// **'Brokerage'**
  String get acctTypeBrokerage;

  /// No description provided for @acctTypeInvestment.
  ///
  /// In en, this message translates to:
  /// **'Investment'**
  String get acctTypeInvestment;

  /// No description provided for @acctTypeBonds.
  ///
  /// In en, this message translates to:
  /// **'Bonds'**
  String get acctTypeBonds;

  /// No description provided for @acctTypeStockPlan.
  ///
  /// In en, this message translates to:
  /// **'Stock plan'**
  String get acctTypeStockPlan;

  /// No description provided for @acctTypeIRA.
  ///
  /// In en, this message translates to:
  /// **'IRA'**
  String get acctTypeIRA;

  /// No description provided for @acctType401k.
  ///
  /// In en, this message translates to:
  /// **'401(k)'**
  String get acctType401k;

  /// No description provided for @acctTypeCrypto.
  ///
  /// In en, this message translates to:
  /// **'Crypto'**
  String get acctTypeCrypto;

  /// No description provided for @acctTypeRealEstate.
  ///
  /// In en, this message translates to:
  /// **'Real estate'**
  String get acctTypeRealEstate;

  /// No description provided for @acctTypeVehicle.
  ///
  /// In en, this message translates to:
  /// **'Vehicle'**
  String get acctTypeVehicle;

  /// No description provided for @acctTypePrivateEquity.
  ///
  /// In en, this message translates to:
  /// **'Private equity'**
  String get acctTypePrivateEquity;

  /// No description provided for @acctTypeCollectibles.
  ///
  /// In en, this message translates to:
  /// **'Collectibles'**
  String get acctTypeCollectibles;

  /// No description provided for @acctTypeOtherAsset.
  ///
  /// In en, this message translates to:
  /// **'Other asset'**
  String get acctTypeOtherAsset;

  /// No description provided for @acctTypeCreditCard.
  ///
  /// In en, this message translates to:
  /// **'Credit card'**
  String get acctTypeCreditCard;

  /// No description provided for @acctTypeLoan.
  ///
  /// In en, this message translates to:
  /// **'Loan'**
  String get acctTypeLoan;

  /// No description provided for @acctTypeMortgage.
  ///
  /// In en, this message translates to:
  /// **'Mortgage'**
  String get acctTypeMortgage;

  /// No description provided for @acctTypeOtherLiability.
  ///
  /// In en, this message translates to:
  /// **'Other liability'**
  String get acctTypeOtherLiability;

  /// No description provided for @impAccountMatched.
  ///
  /// In en, this message translates to:
  /// **'Matched to {account} from the statement'**
  String impAccountMatched(Object account);

  /// No description provided for @impNoAccountMatch.
  ///
  /// In en, this message translates to:
  /// **'No existing account matches this statement — create one below.'**
  String get impNoAccountMatch;

  /// No description provided for @impAccountCreatedCue.
  ///
  /// In en, this message translates to:
  /// **'Created {account} — importing here'**
  String impAccountCreatedCue(Object account);

  /// No description provided for @impSummaryFound.
  ///
  /// In en, this message translates to:
  /// **'Found'**
  String get impSummaryFound;

  /// No description provided for @impSummaryInflow.
  ///
  /// In en, this message translates to:
  /// **'Inflow'**
  String get impSummaryInflow;

  /// No description provided for @impSummaryOutflow.
  ///
  /// In en, this message translates to:
  /// **'Outflow'**
  String get impSummaryOutflow;

  /// No description provided for @impSummaryFiles.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file} other{{count} files}}'**
  String impSummaryFiles(int count);

  /// No description provided for @impContinuityGap.
  ///
  /// In en, this message translates to:
  /// **'Possible missing statement: ‘{fromFile}’ ends at {fromBalance} ({fromDate}), but ‘{toFile}’ opens at {toBalance} ({toDate}) — an unexplained difference of {diff}. A statement covering the period between them may be missing.'**
  String impContinuityGap(
    Object fromFile,
    Object fromBalance,
    Object fromDate,
    Object toFile,
    Object toBalance,
    Object toDate,
    Object diff,
  );

  /// No description provided for @dlgAccountCurrency.
  ///
  /// In en, this message translates to:
  /// **'Currency'**
  String get dlgAccountCurrency;

  /// No description provided for @dlgAccountInitialBalance.
  ///
  /// In en, this message translates to:
  /// **'Initial balance'**
  String get dlgAccountInitialBalance;

  /// No description provided for @dlgAccountBalanceHelper.
  ///
  /// In en, this message translates to:
  /// **'For credit cards / loans, enter the amount owed as a positive number.'**
  String get dlgAccountBalanceHelper;

  /// No description provided for @dlgAccountBalanceInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a numeric amount'**
  String get dlgAccountBalanceInvalid;

  /// No description provided for @dlgAccountCreate.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get dlgAccountCreate;

  /// No description provided for @dlgAccountGroupCashBanking.
  ///
  /// In en, this message translates to:
  /// **'Cash & banking'**
  String get dlgAccountGroupCashBanking;

  /// No description provided for @dlgAccountGroupInvestments.
  ///
  /// In en, this message translates to:
  /// **'Investments'**
  String get dlgAccountGroupInvestments;

  /// No description provided for @dlgAccountGroupCrypto.
  ///
  /// In en, this message translates to:
  /// **'Crypto'**
  String get dlgAccountGroupCrypto;

  /// No description provided for @dlgAccountGroupRealAssets.
  ///
  /// In en, this message translates to:
  /// **'Real assets'**
  String get dlgAccountGroupRealAssets;

  /// No description provided for @dlgAccountGroupLiabilities.
  ///
  /// In en, this message translates to:
  /// **'Liabilities'**
  String get dlgAccountGroupLiabilities;

  /// No description provided for @dlgAccountCreated.
  ///
  /// In en, this message translates to:
  /// **'Account \"{name}\" created!'**
  String dlgAccountCreated(Object name);

  /// No description provided for @dlgAccountCreateError.
  ///
  /// In en, this message translates to:
  /// **'Could not add account: {error}'**
  String dlgAccountCreateError(Object error);

  /// No description provided for @dlgCryptoLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Link {exchange}'**
  String dlgCryptoLinkTitle(Object exchange);

  /// No description provided for @dlgCryptoIntro.
  ///
  /// In en, this message translates to:
  /// **'Generate a \"Read-Only\" API key in {exchange} settings. We only use this to fetch balances and estimate their value.'**
  String dlgCryptoIntro(Object exchange);

  /// No description provided for @dlgCryptoWhereApiKeys.
  ///
  /// In en, this message translates to:
  /// **'Where do I find my API keys? ↗'**
  String get dlgCryptoWhereApiKeys;

  /// No description provided for @dlgCryptoDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Display Name (e.g. {example})'**
  String dlgCryptoDisplayName(Object example);

  /// No description provided for @dlgCryptoApiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get dlgCryptoApiKey;

  /// No description provided for @dlgCryptoApiSecret.
  ///
  /// In en, this message translates to:
  /// **'API Secret'**
  String get dlgCryptoApiSecret;

  /// No description provided for @dlgCryptoLinkAccount.
  ///
  /// In en, this message translates to:
  /// **'Link account'**
  String get dlgCryptoLinkAccount;

  /// No description provided for @dlgCryptoApiKeysTitle.
  ///
  /// In en, this message translates to:
  /// **'{exchange} API keys'**
  String dlgCryptoApiKeysTitle(Object exchange);

  /// No description provided for @dlgCryptoApiKeysFallbackBody.
  ///
  /// In en, this message translates to:
  /// **'Generate a Read-Only API key in your {exchange} settings, then paste it here. Open:'**
  String dlgCryptoApiKeysFallbackBody(Object exchange);

  /// No description provided for @dlgCryptoLinkSuccess.
  ///
  /// In en, this message translates to:
  /// **'Successfully linked {exchange}!'**
  String dlgCryptoLinkSuccess(Object exchange);

  /// No description provided for @dlgCryptoLinkError.
  ///
  /// In en, this message translates to:
  /// **'Error linking: {error}'**
  String dlgCryptoLinkError(Object error);

  /// No description provided for @dlgTxTitle.
  ///
  /// In en, this message translates to:
  /// **'Add transaction'**
  String get dlgTxTitle;

  /// No description provided for @dlgTxAdded.
  ///
  /// In en, this message translates to:
  /// **'Transaction added'**
  String get dlgTxAdded;

  /// No description provided for @dlgTxNoAccounts.
  ///
  /// In en, this message translates to:
  /// **'You need at least one account before you can add a transaction.'**
  String get dlgTxNoAccounts;

  /// No description provided for @dlgTxAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get dlgTxAccount;

  /// No description provided for @dlgTxExpense.
  ///
  /// In en, this message translates to:
  /// **'Expense'**
  String get dlgTxExpense;

  /// No description provided for @dlgTxIncome.
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get dlgTxIncome;

  /// No description provided for @dlgTxAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get dlgTxAmount;

  /// No description provided for @dlgTxAmountRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter an amount'**
  String get dlgTxAmountRequired;

  /// No description provided for @dlgTxAmountPositive.
  ///
  /// In en, this message translates to:
  /// **'Enter a positive amount'**
  String get dlgTxAmountPositive;

  /// No description provided for @dlgTxDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get dlgTxDate;

  /// No description provided for @dlgTxDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get dlgTxDescription;

  /// No description provided for @dlgTxDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Coffee with Sam'**
  String get dlgTxDescriptionHint;

  /// No description provided for @dlgTxDescriptionRequired.
  ///
  /// In en, this message translates to:
  /// **'Description is required'**
  String get dlgTxDescriptionRequired;

  /// No description provided for @dlgTxCategory.
  ///
  /// In en, this message translates to:
  /// **'Category (optional)'**
  String get dlgTxCategory;

  /// No description provided for @dlgTxCategoryHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Restaurants'**
  String get dlgTxCategoryHint;

  /// No description provided for @dlgTxNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes (optional)'**
  String get dlgTxNotes;

  /// No description provided for @dlgRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Save your recovery codes'**
  String get dlgRecoveryTitle;

  /// No description provided for @dlgRecoveryWarning.
  ///
  /// In en, this message translates to:
  /// **'These codes will NOT be shown again. Each is single-use; use one if you lose your password.'**
  String get dlgRecoveryWarning;

  /// No description provided for @dlgRecoveryCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get dlgRecoveryCopied;

  /// No description provided for @dlgClabeCopied.
  ///
  /// In en, this message translates to:
  /// **'CLABE copied to clipboard'**
  String get dlgClabeCopied;

  /// No description provided for @dlgCopyClabe.
  ///
  /// In en, this message translates to:
  /// **'Copy CLABE'**
  String get dlgCopyClabe;

  /// No description provided for @dlgRecoveryCopyAll.
  ///
  /// In en, this message translates to:
  /// **'Copy all'**
  String get dlgRecoveryCopyAll;

  /// No description provided for @dlgRecoverySavedConfirm.
  ///
  /// In en, this message translates to:
  /// **'I\'ve saved these codes somewhere safe'**
  String get dlgRecoverySavedConfirm;

  /// No description provided for @dlgRecoveryContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get dlgRecoveryContinue;

  /// No description provided for @lwFxExchangeRate.
  ///
  /// In en, this message translates to:
  /// **'Exchange rate'**
  String get lwFxExchangeRate;

  /// No description provided for @lwFxRefreshNow.
  ///
  /// In en, this message translates to:
  /// **'Refresh rate now'**
  String get lwFxRefreshNow;

  /// No description provided for @lwFxSource.
  ///
  /// In en, this message translates to:
  /// **'Source: {source}'**
  String lwFxSource(Object source);

  /// No description provided for @lwFxUpdatedUnknown.
  ///
  /// In en, this message translates to:
  /// **'Updated: unknown'**
  String get lwFxUpdatedUnknown;

  /// No description provided for @lwFxStalePrefix.
  ///
  /// In en, this message translates to:
  /// **'Stale · {age}'**
  String lwFxStalePrefix(Object age);

  /// No description provided for @lwFxUpdatedJustNow.
  ///
  /// In en, this message translates to:
  /// **'Updated just now'**
  String get lwFxUpdatedJustNow;

  /// No description provided for @lwFxUpdatedMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'Updated {minutes}m ago'**
  String lwFxUpdatedMinutesAgo(Object minutes);

  /// No description provided for @lwFxUpdatedHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'Updated {hours}h ago'**
  String lwFxUpdatedHoursAgo(Object hours);

  /// No description provided for @lwFxUpdatedDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, one{Updated {days} day ago} other{Updated {days} days ago}}'**
  String lwFxUpdatedDaysAgo(int days);

  /// No description provided for @lwSyncInstitutionsHeader.
  ///
  /// In en, this message translates to:
  /// **'INSTITUTIONS'**
  String get lwSyncInstitutionsHeader;

  /// No description provided for @lwSyncRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry {count} failed'**
  String lwSyncRetryFailed(Object count);

  /// No description provided for @lwSyncNoInstitutions.
  ///
  /// In en, this message translates to:
  /// **'No institutions linked yet'**
  String get lwSyncNoInstitutions;

  /// No description provided for @lwSyncNoInstitutionsHint.
  ///
  /// In en, this message translates to:
  /// **'Use the buttons below to connect a bank, import a\nstatement, or add a manual account.'**
  String get lwSyncNoInstitutionsHint;

  /// No description provided for @lwSyncNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get lwSyncNever;

  /// No description provided for @lwSyncUnknownInstitution.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get lwSyncUnknownInstitution;

  /// No description provided for @lwSyncFailedUnknownReason.
  ///
  /// In en, this message translates to:
  /// **'Sync failed. Reason unknown — try Retry or Reconnect.'**
  String get lwSyncFailedUnknownReason;

  /// No description provided for @lwSyncReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get lwSyncReconnect;

  /// No description provided for @lwSyncRetrySync.
  ///
  /// In en, this message translates to:
  /// **'Retry sync'**
  String get lwSyncRetrySync;

  /// No description provided for @lwSyncDeleteInstitution.
  ///
  /// In en, this message translates to:
  /// **'Delete institution'**
  String get lwSyncDeleteInstitution;

  /// No description provided for @lwSyncVia.
  ///
  /// In en, this message translates to:
  /// **'Via {source}'**
  String lwSyncVia(Object source);

  /// No description provided for @lwSyncDetailSyncingNow.
  ///
  /// In en, this message translates to:
  /// **'Syncing now'**
  String get lwSyncDetailSyncingNow;

  /// No description provided for @lwSyncDetailSetupRequired.
  ///
  /// In en, this message translates to:
  /// **'Setup required before sync'**
  String get lwSyncDetailSetupRequired;

  /// No description provided for @lwSyncDetailReconnectRequired.
  ///
  /// In en, this message translates to:
  /// **'Reconnect required'**
  String get lwSyncDetailReconnectRequired;

  /// No description provided for @lwSyncDetailWaitingFirstSync.
  ///
  /// In en, this message translates to:
  /// **'Waiting for first sync'**
  String get lwSyncDetailWaitingFirstSync;

  /// No description provided for @lwSyncDetailManualSource.
  ///
  /// In en, this message translates to:
  /// **'Manual/offline source'**
  String get lwSyncDetailManualSource;

  /// No description provided for @lwSyncStaleSuffix.
  ///
  /// In en, this message translates to:
  /// **'(Stale)'**
  String get lwSyncStaleSuffix;

  /// No description provided for @lwSyncBannerOneNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'{name} needs attention'**
  String lwSyncBannerOneNeedsAttention(Object name);

  /// No description provided for @lwSyncBannerManyNeedAttention.
  ///
  /// In en, this message translates to:
  /// **'{count} institutions need attention'**
  String lwSyncBannerManyNeedAttention(Object count);

  /// No description provided for @lwSyncBannerReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get lwSyncBannerReconnect;

  /// No description provided for @lwSyncBannerReconnectName.
  ///
  /// In en, this message translates to:
  /// **'Reconnect {name}'**
  String lwSyncBannerReconnectName(Object name);

  /// No description provided for @lwSyncBannerReconnectCount.
  ///
  /// In en, this message translates to:
  /// **'Reconnect {count}…'**
  String lwSyncBannerReconnectCount(Object count);

  /// No description provided for @lwSyncBannerOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get lwSyncBannerOpenSettings;

  /// No description provided for @lwSinceNewTransactions.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} new transaction} other{{count} new transactions}}'**
  String lwSinceNewTransactions(int count);

  /// No description provided for @lwSinceLargestMove.
  ///
  /// In en, this message translates to:
  /// **'{amount} on {account}'**
  String lwSinceLargestMove(Object account, Object amount);

  /// No description provided for @lwSinceSyncErrors.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} sync error} other{{count} sync errors}}'**
  String lwSinceSyncErrors(int count);

  /// No description provided for @lwSinceLastVisit.
  ///
  /// In en, this message translates to:
  /// **'Since your last visit'**
  String get lwSinceLastVisit;

  /// No description provided for @lwSinceDate.
  ///
  /// In en, this message translates to:
  /// **'Since {date}'**
  String lwSinceDate(Object date);

  /// No description provided for @lwSinceViewAction.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get lwSinceViewAction;

  /// No description provided for @lwSinceFixAction.
  ///
  /// In en, this message translates to:
  /// **'Fix'**
  String get lwSinceFixAction;

  /// No description provided for @lwSinceDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get lwSinceDismiss;

  /// No description provided for @lwNotifBorrowerFallback.
  ///
  /// In en, this message translates to:
  /// **'Borrower'**
  String get lwNotifBorrowerFallback;

  /// No description provided for @lwNotifInstitutionFallback.
  ///
  /// In en, this message translates to:
  /// **'Institution'**
  String get lwNotifInstitutionFallback;

  /// No description provided for @lwNotifAccountFallback.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get lwNotifAccountFallback;

  /// No description provided for @lwNotifLowBalanceTitle.
  ///
  /// In en, this message translates to:
  /// **'{account} is running low'**
  String lwNotifLowBalanceTitle(Object account);

  /// No description provided for @lwNotifLowBalanceDetail.
  ///
  /// In en, this message translates to:
  /// **'Balance {balance} is at or below your {threshold} alert.'**
  String lwNotifLowBalanceDetail(Object balance, Object threshold);

  /// No description provided for @lwNotifRepaymentOverdueTitle.
  ///
  /// In en, this message translates to:
  /// **'{borrower} repayment overdue'**
  String lwNotifRepaymentOverdueTitle(Object borrower);

  /// No description provided for @lwNotifRepaymentOverdueDetail.
  ///
  /// In en, this message translates to:
  /// **'Installment #{number} of {amount} was due {dueDate} ({daysOverdue}d ago).'**
  String lwNotifRepaymentOverdueDetail(
    Object amount,
    Object daysOverdue,
    Object dueDate,
    Object number,
  );

  /// No description provided for @lwNotifRepaymentDueTitle.
  ///
  /// In en, this message translates to:
  /// **'{borrower} repayment due in {days}d'**
  String lwNotifRepaymentDueTitle(Object borrower, Object days);

  /// No description provided for @lwNotifRepaymentDueDetail.
  ///
  /// In en, this message translates to:
  /// **'Installment #{number} of {amount} due {dueDate}.'**
  String lwNotifRepaymentDueDetail(
    Object amount,
    Object dueDate,
    Object number,
  );

  /// No description provided for @lwNotifNeedsReconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} needs reconnect'**
  String lwNotifNeedsReconnectTitle(Object name);

  /// No description provided for @lwNotifNeedsReconnectDetail.
  ///
  /// In en, this message translates to:
  /// **'Plaid token expired — reconnect to resume sync.'**
  String get lwNotifNeedsReconnectDetail;

  /// No description provided for @lwNotifSyncFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} sync failed'**
  String lwNotifSyncFailedTitle(Object name);

  /// No description provided for @lwNotifUnknownSyncError.
  ///
  /// In en, this message translates to:
  /// **'Unknown sync error'**
  String get lwNotifUnknownSyncError;

  /// No description provided for @lwNotifStaleSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} last synced {days}d ago'**
  String lwNotifStaleSyncTitle(Object days, Object name);

  /// No description provided for @lwNotifStaleSyncDetail.
  ///
  /// In en, this message translates to:
  /// **'Trigger a sync to pull in transactions and balance updates.'**
  String get lwNotifStaleSyncDetail;

  /// No description provided for @lwNotifNetWorthDropTitle.
  ///
  /// In en, this message translates to:
  /// **'Net worth dropped {pct} in 30 days'**
  String lwNotifNetWorthDropTitle(Object pct);

  /// No description provided for @lwNotifNetWorthDropDetail.
  ///
  /// In en, this message translates to:
  /// **'Latest {latest} vs {reference}.'**
  String lwNotifNetWorthDropDetail(Object latest, Object reference);

  /// No description provided for @lwNotifSpendingUpTitle.
  ///
  /// In en, this message translates to:
  /// **'{category} up {pct}'**
  String lwNotifSpendingUpTitle(String category, String pct);

  /// No description provided for @lwNotifSpendingUpDetail.
  ///
  /// In en, this message translates to:
  /// **'vs your {months}-month average of {avg}'**
  String lwNotifSpendingUpDetail(int months, String avg);

  /// No description provided for @lwNotifSubPriceUpTitle.
  ///
  /// In en, this message translates to:
  /// **'{merchant} price increased'**
  String lwNotifSubPriceUpTitle(String merchant);

  /// No description provided for @lwNotifSubPriceUpDetail.
  ///
  /// In en, this message translates to:
  /// **'Now {newAmount}, was {oldAmount}'**
  String lwNotifSubPriceUpDetail(String newAmount, String oldAmount);

  /// No description provided for @lwNotifTooltipNone.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get lwNotifTooltipNone;

  /// No description provided for @lwNotifTooltipCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} alert} other{{count} alerts}}'**
  String lwNotifTooltipCount(int count);

  /// No description provided for @lwNotifAllClear.
  ///
  /// In en, this message translates to:
  /// **'All clear'**
  String get lwNotifAllClear;

  /// No description provided for @lwNotifNoAlerts.
  ///
  /// In en, this message translates to:
  /// **'No alerts right now.'**
  String get lwNotifNoAlerts;

  /// No description provided for @lwPaletteSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search accounts, holdings, transactions, or jump to a tab…'**
  String get lwPaletteSearchHint;

  /// No description provided for @lwPaletteNoMatches.
  ///
  /// In en, this message translates to:
  /// **'No matches.'**
  String get lwPaletteNoMatches;

  /// No description provided for @lwPaletteHintNavigate.
  ///
  /// In en, this message translates to:
  /// **'navigate'**
  String get lwPaletteHintNavigate;

  /// No description provided for @lwPaletteHintSelect.
  ///
  /// In en, this message translates to:
  /// **'select'**
  String get lwPaletteHintSelect;

  /// No description provided for @lwPaletteHintClose.
  ///
  /// In en, this message translates to:
  /// **'close'**
  String get lwPaletteHintClose;

  /// No description provided for @lwTrendsTitle.
  ///
  /// In en, this message translates to:
  /// **'Cash flow trends'**
  String get lwTrendsTitle;

  /// No description provided for @lwTrendsIncome.
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get lwTrendsIncome;

  /// No description provided for @lwTrendsSpending.
  ///
  /// In en, this message translates to:
  /// **'Spending'**
  String get lwTrendsSpending;

  /// No description provided for @lwTrendsTapToView.
  ///
  /// In en, this message translates to:
  /// **'Tap to view transactions'**
  String get lwTrendsTapToView;

  /// No description provided for @lwTrendsInfoTooltip.
  ///
  /// In en, this message translates to:
  /// **'Internal transfers (between your accounts) and credit-card bill payments are excluded so the bars reflect actual external income and spending.'**
  String get lwTrendsInfoTooltip;

  /// No description provided for @lwTrendsSemanticNoData.
  ///
  /// In en, this message translates to:
  /// **'Cash flow trends chart, no data'**
  String get lwTrendsSemanticNoData;

  /// No description provided for @lwTrendsSemanticSummary.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Cash flow trends, {count} month. Latest {month}: income {income}, spending {spending}.} other{Cash flow trends, {count} months. Latest {month}: income {income}, spending {spending}.}}'**
  String lwTrendsSemanticSummary(
    int count,
    Object income,
    Object month,
    Object spending,
  );

  /// No description provided for @lwTrendsSemanticMonth.
  ///
  /// In en, this message translates to:
  /// **'{month}: income {income}, spending {spending}'**
  String lwTrendsSemanticMonth(Object income, Object month, Object spending);

  /// No description provided for @lwAllocTitle.
  ///
  /// In en, this message translates to:
  /// **'Asset distribution'**
  String get lwAllocTitle;

  /// No description provided for @lwAllocTotal.
  ///
  /// In en, this message translates to:
  /// **'Total: {amount}'**
  String lwAllocTotal(Object amount);

  /// No description provided for @lwAllocOtherCategory.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get lwAllocOtherCategory;

  /// No description provided for @lwAllocHoldingsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} holding} other{{count} holdings}}'**
  String lwAllocHoldingsCount(int count);

  /// No description provided for @lwAllocSharesSuffix.
  ///
  /// In en, this message translates to:
  /// **'{qty} sh'**
  String lwAllocSharesSuffix(Object qty);

  /// No description provided for @lwAllocShowMore.
  ///
  /// In en, this message translates to:
  /// **'Show {count} more'**
  String lwAllocShowMore(int count);

  /// No description provided for @lwAllocShowFewer.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get lwAllocShowFewer;

  /// No description provided for @lwAllocDimClass.
  ///
  /// In en, this message translates to:
  /// **'Asset class'**
  String get lwAllocDimClass;

  /// No description provided for @lwAllocDimType.
  ///
  /// In en, this message translates to:
  /// **'Account type'**
  String get lwAllocDimType;

  /// No description provided for @lwAllocDimInstitution.
  ///
  /// In en, this message translates to:
  /// **'Institution'**
  String get lwAllocDimInstitution;

  /// No description provided for @lwAllocConcentration.
  ///
  /// In en, this message translates to:
  /// **'{holding} is {pct} of your portfolio — a concentrated position.'**
  String lwAllocConcentration(String holding, String pct);

  /// No description provided for @lwAllocFilteringHint.
  ///
  /// In en, this message translates to:
  /// **'Filtering holdings to this category — tap again to clear'**
  String get lwAllocFilteringHint;

  /// No description provided for @lwAllocSemanticLabel.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{category}, {pct} of portfolio, {count} holding} other{{category}, {pct} of portfolio, {count} holdings}}'**
  String lwAllocSemanticLabel(Object category, Object pct, int count);

  /// No description provided for @lwRangeOneMonth.
  ///
  /// In en, this message translates to:
  /// **'1M'**
  String get lwRangeOneMonth;

  /// No description provided for @lwRangeYearToDate.
  ///
  /// In en, this message translates to:
  /// **'YTD'**
  String get lwRangeYearToDate;

  /// No description provided for @lwRangeOneYear.
  ///
  /// In en, this message translates to:
  /// **'1Y'**
  String get lwRangeOneYear;

  /// No description provided for @lwRangeFiveYears.
  ///
  /// In en, this message translates to:
  /// **'5Y'**
  String get lwRangeFiveYears;

  /// No description provided for @lwRangeAll.
  ///
  /// In en, this message translates to:
  /// **'ALL'**
  String get lwRangeAll;

  /// No description provided for @lwPerfTitle.
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get lwPerfTitle;

  /// No description provided for @lwPerfValueSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Investment value over time (includes contributions)'**
  String get lwPerfValueSubtitle;

  /// No description provided for @lwPerfNotEnough.
  ///
  /// In en, this message translates to:
  /// **'Not enough history yet to chart your portfolio value over time.'**
  String get lwPerfNotEnough;

  /// No description provided for @lwPerfTwrReturn.
  ///
  /// In en, this message translates to:
  /// **'Time-weighted return'**
  String get lwPerfTwrReturn;

  /// No description provided for @lwPerfTwrYou.
  ///
  /// In en, this message translates to:
  /// **'Your portfolio'**
  String get lwPerfTwrYou;

  /// No description provided for @lwPerfTwrSp.
  ///
  /// In en, this message translates to:
  /// **'S&P 500'**
  String get lwPerfTwrSp;

  /// No description provided for @lwPerfTwrCoverage.
  ///
  /// In en, this message translates to:
  /// **'Reflects {pct} of your portfolio we can price daily'**
  String lwPerfTwrCoverage(Object pct);
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
