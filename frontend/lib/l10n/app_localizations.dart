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

  /// Footnote under a loan card's Outstanding figure when that figure includes unpaid scheduled interest on top of the principal. {amount} is the formatted interest portion.
  ///
  /// In en, this message translates to:
  /// **'incl. {amount} interest'**
  String lendingOutstandingInclInterest(String amount);

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

  /// No description provided for @lendViewInstallments.
  ///
  /// In en, this message translates to:
  /// **'View {count} installment{count, plural, =1{} other{s}}'**
  String lendViewInstallments(int count);

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

  /// No description provided for @txAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get txAmount;

  /// No description provided for @txAmountMin.
  ///
  /// In en, this message translates to:
  /// **'Min'**
  String get txAmountMin;

  /// No description provided for @txAmountMax.
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get txAmountMax;

  /// No description provided for @txAmountFilterHelp.
  ///
  /// In en, this message translates to:
  /// **'Matches the amount regardless of sign or currency.'**
  String get txAmountFilterHelp;

  /// No description provided for @txClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get txClearAll;

  /// No description provided for @txSpikeBanner.
  ///
  /// In en, this message translates to:
  /// **'{category} in {monthLabel}: {recent} spent — {percent} above your {months}-month average of {average}'**
  String txSpikeBanner(
    String average,
    String category,
    String monthLabel,
    int months,
    String percent,
    String recent,
  );

  /// No description provided for @txClaimNewSince.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 new transaction since {date}} other{{count} new transactions since {date}}}'**
  String txClaimNewSince(int count, String date);

  /// No description provided for @txClaimNetWorthMove.
  ///
  /// In en, this message translates to:
  /// **'Net worth {amount} ({percent}) since {date}'**
  String txClaimNetWorthMove(String amount, String date, String percent);

  /// No description provided for @txClaimAccountMove.
  ///
  /// In en, this message translates to:
  /// **'{account} moved {amount} since {date}'**
  String txClaimAccountMove(String account, String amount, String date);

  /// No description provided for @txClaimReconciliation.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 synced transaction accounts for {amount} of this move; the rest changed without synced activity (transfers or pending).} other{{count} synced transactions account for {amount} of this move; the rest changed without synced activity (transfers or pending).}}'**
  String txClaimReconciliation(String amount, int count);

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

  /// No description provided for @txNoMatchesTitle.
  ///
  /// In en, this message translates to:
  /// **'No transactions match'**
  String get txNoMatchesTitle;

  /// No description provided for @txNoMatchesBody.
  ///
  /// In en, this message translates to:
  /// **'Try adjusting your search or filters.'**
  String get txNoMatchesBody;

  /// No description provided for @txClearFiltersSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear filters & search'**
  String get txClearFiltersSearch;

  /// No description provided for @txShowingCount.
  ///
  /// In en, this message translates to:
  /// **'Showing {shown} of {total}'**
  String txShowingCount(Object shown, Object total);

  /// No description provided for @txShowingMatches.
  ///
  /// In en, this message translates to:
  /// **'{shown, plural, =1{1 matching} other{{shown} matching}} · {total} total'**
  String txShowingMatches(num shown, Object total);

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

  /// No description provided for @txDeletedOne.
  ///
  /// In en, this message translates to:
  /// **'Transaction deleted'**
  String get txDeletedOne;

  /// No description provided for @txDeleteOneFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete the transaction'**
  String get txDeleteOneFailed;

  /// No description provided for @txDeleteSomeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete some transactions'**
  String get txDeleteSomeFailed;

  /// No description provided for @txUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get txUndo;

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

  /// No description provided for @txFilterSort.
  ///
  /// In en, this message translates to:
  /// **'Filter & sort'**
  String get txFilterSort;

  /// No description provided for @txFilterLoadingHistory.
  ///
  /// In en, this message translates to:
  /// **'Loading your full history so every option is available…'**
  String get txFilterLoadingHistory;

  /// No description provided for @txLoadingFullHistory.
  ///
  /// In en, this message translates to:
  /// **'Loading full history…'**
  String get txLoadingFullHistory;

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

  /// No description provided for @txExportCsvAllNote.
  ///
  /// In en, this message translates to:
  /// **'Export CSV — exports all transactions (filters and search don\'t apply)'**
  String get txExportCsvAllNote;

  /// No description provided for @txExportCsvFiltered.
  ///
  /// In en, this message translates to:
  /// **'Export CSV — exports the transactions matching your current filter'**
  String get txExportCsvFiltered;

  /// No description provided for @txExportNoRows.
  ///
  /// In en, this message translates to:
  /// **'Nothing to export — no transactions match the current filter.'**
  String get txExportNoRows;

  /// No description provided for @txExportAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Export all transactions?'**
  String get txExportAllTitle;

  /// No description provided for @txExportAllBody.
  ///
  /// In en, this message translates to:
  /// **'Filters and search don\'t apply to the CSV export — it will include your entire transaction history.'**
  String get txExportAllBody;

  /// No description provided for @txExportAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'Export all'**
  String get txExportAllConfirm;

  /// No description provided for @txSortBy.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get txSortBy;

  /// No description provided for @txSortDateNewest.
  ///
  /// In en, this message translates to:
  /// **'Date (newest first)'**
  String get txSortDateNewest;

  /// No description provided for @txSortDateOldest.
  ///
  /// In en, this message translates to:
  /// **'Date (oldest first)'**
  String get txSortDateOldest;

  /// No description provided for @txSortAmountHigh.
  ///
  /// In en, this message translates to:
  /// **'Amount (largest first)'**
  String get txSortAmountHigh;

  /// No description provided for @txSortAmountLow.
  ///
  /// In en, this message translates to:
  /// **'Amount (smallest first)'**
  String get txSortAmountLow;

  /// No description provided for @txSortMerchant.
  ///
  /// In en, this message translates to:
  /// **'Merchant (A–Z)'**
  String get txSortMerchant;

  /// No description provided for @txScanTransfers.
  ///
  /// In en, this message translates to:
  /// **'Scan for cross-currency transfers (Wise / Remitly / etc.)'**
  String get txScanTransfers;

  /// No description provided for @txMoreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get txMoreActions;

  /// No description provided for @txDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get txDetails;

  /// No description provided for @txMoreDetails.
  ///
  /// In en, this message translates to:
  /// **'More details'**
  String get txMoreDetails;

  /// No description provided for @txDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get txDate;

  /// No description provided for @txAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get txAccount;

  /// No description provided for @txAutoCategory.
  ///
  /// In en, this message translates to:
  /// **'Auto-category'**
  String get txAutoCategory;

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

  /// No description provided for @txMonthNet.
  ///
  /// In en, this message translates to:
  /// **'{amount} net'**
  String txMonthNet(Object amount);

  /// No description provided for @txMonthNetPartial.
  ///
  /// In en, this message translates to:
  /// **'{amount} net (partial)'**
  String txMonthNetPartial(Object amount);

  /// No description provided for @txBalanceAfter.
  ///
  /// In en, this message translates to:
  /// **'Bal. {amount}'**
  String txBalanceAfter(Object amount);

  /// No description provided for @txBalanceAfterTooltip.
  ///
  /// In en, this message translates to:
  /// **'Balance after this transaction'**
  String get txBalanceAfterTooltip;

  /// No description provided for @txBalanceAfterEstimatedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Estimated from current balance'**
  String get txBalanceAfterEstimatedTooltip;

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

  /// No description provided for @txTransferPill.
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get txTransferPill;

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

  /// No description provided for @txOriginalText.
  ///
  /// In en, this message translates to:
  /// **'Original text'**
  String get txOriginalText;

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

  /// No description provided for @txEditTransaction.
  ///
  /// In en, this message translates to:
  /// **'Edit transaction'**
  String get txEditTransaction;

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

  /// Active-filter chip for the since-last-visit drill-down: only transactions SYNCED after the user's previous visit are shown. {date} arrives pre-formatted (DateFormat.MMMd of the local anchor).
  ///
  /// In en, this message translates to:
  /// **'New since {date}'**
  String txNewSince(Object date);

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

  /// No description provided for @secAccountSection.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get secAccountSection;

  /// No description provided for @secAccountNoEmail.
  ///
  /// In en, this message translates to:
  /// **'No email on file'**
  String get secAccountNoEmail;

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

  /// No description provided for @secSetPasswordWithPasskey.
  ///
  /// In en, this message translates to:
  /// **'Set a new password (with passkey)'**
  String get secSetPasswordWithPasskey;

  /// No description provided for @secSetPasswordWithPasskeySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use your passkey instead of your current password.'**
  String get secSetPasswordWithPasskeySubtitle;

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

  /// No description provided for @secSetPasswordWithPasskeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Set a new password'**
  String get secSetPasswordWithPasskeyTitle;

  /// No description provided for @secSetPasswordWithPasskeyBody.
  ///
  /// In en, this message translates to:
  /// **'Your passkey verified you. Choose a new password — you won\'t need your old one.'**
  String get secSetPasswordWithPasskeyBody;

  /// No description provided for @secSetPasswordButton.
  ///
  /// In en, this message translates to:
  /// **'Set password'**
  String get secSetPasswordButton;

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

  /// No description provided for @cfCashFlowShort.
  ///
  /// In en, this message translates to:
  /// **'Cash flow'**
  String get cfCashFlowShort;

  /// No description provided for @cfNetEquivalence.
  ///
  /// In en, this message translates to:
  /// **'Net this period ≈ {amount}'**
  String cfNetEquivalence(Object amount);

  /// No description provided for @cfMonthlyExcludesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Excludes securities trades and internal transfers between your own accounts, plus credit-card payments — that money moves around your balance sheet without changing your income or spending. The amounts are shown below.'**
  String get cfMonthlyExcludesTooltip;

  /// No description provided for @cfAlsoThisPeriod.
  ///
  /// In en, this message translates to:
  /// **'Also this period —'**
  String get cfAlsoThisPeriod;

  /// No description provided for @cfInvestedContext.
  ///
  /// In en, this message translates to:
  /// **'Invested {amount}'**
  String cfInvestedContext(Object amount);

  /// No description provided for @cfWithdrawnContext.
  ///
  /// In en, this message translates to:
  /// **'Withdrawn {amount}'**
  String cfWithdrawnContext(Object amount);

  /// No description provided for @cfTransferredInContext.
  ///
  /// In en, this message translates to:
  /// **'Transferred in {amount}'**
  String cfTransferredInContext(Object amount);

  /// No description provided for @cfTransferredOutContext.
  ///
  /// In en, this message translates to:
  /// **'Transferred out {amount}'**
  String cfTransferredOutContext(Object amount);

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

  /// No description provided for @cfPeriodLabel.
  ///
  /// In en, this message translates to:
  /// **'Period'**
  String get cfPeriodLabel;

  /// No description provided for @cfPeriodThisMonth.
  ///
  /// In en, this message translates to:
  /// **'This month'**
  String get cfPeriodThisMonth;

  /// No description provided for @cfPeriodLastMonth.
  ///
  /// In en, this message translates to:
  /// **'Last month'**
  String get cfPeriodLastMonth;

  /// No description provided for @cfPeriod3Months.
  ///
  /// In en, this message translates to:
  /// **'Last 3 months'**
  String get cfPeriod3Months;

  /// No description provided for @cfPeriodYtd.
  ///
  /// In en, this message translates to:
  /// **'Year to date'**
  String get cfPeriodYtd;

  /// No description provided for @cfPeriodLastMonthShort.
  ///
  /// In en, this message translates to:
  /// **'Last month'**
  String get cfPeriodLastMonthShort;

  /// No description provided for @cfPeriod3MonthsShort.
  ///
  /// In en, this message translates to:
  /// **'3 months'**
  String get cfPeriod3MonthsShort;

  /// No description provided for @cfPeriodYtdShort.
  ///
  /// In en, this message translates to:
  /// **'This year'**
  String get cfPeriodYtdShort;

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
  /// **'Money-weighted, all time — if your contributions had bought the index on each purchase date'**
  String get bmSubtitle;

  /// No description provided for @bmContribCaveat.
  ///
  /// In en, this message translates to:
  /// **'Covers only purchases with recorded lots — recent buys weigh most, so this can sit far below the portfolio return above.'**
  String get bmContribCaveat;

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

  /// No description provided for @bmSeeTracked.
  ///
  /// In en, this message translates to:
  /// **'See what\'s tracked'**
  String get bmSeeTracked;

  /// No description provided for @bmSheetTapHint.
  ///
  /// In en, this message translates to:
  /// **'Shows which tickers have recorded lots and which are excluded'**
  String get bmSheetTapHint;

  /// No description provided for @bmSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s tracked'**
  String get bmSheetTitle;

  /// No description provided for @bmSheetCaption.
  ///
  /// In en, this message translates to:
  /// **'Purchases with recorded lots, compared with buying the index on the same dates'**
  String get bmSheetCaption;

  /// No description provided for @bmLots.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 lot} other{{count} lots}}'**
  String bmLots(num count);

  /// No description provided for @bmFirstBuy.
  ///
  /// In en, this message translates to:
  /// **'first buy {monthYear}'**
  String bmFirstBuy(Object monthYear);

  /// No description provided for @bmInvestedToValue.
  ///
  /// In en, this message translates to:
  /// **'{invested} → {value}'**
  String bmInvestedToValue(Object invested, Object value);

  /// No description provided for @bmPtsVsIndex.
  ///
  /// In en, this message translates to:
  /// **'{pts} pts vs index'**
  String bmPtsVsIndex(Object pts);

  /// No description provided for @bmUntrackedHeader.
  ///
  /// In en, this message translates to:
  /// **'Not included — no recorded purchase data'**
  String get bmUntrackedHeader;

  /// No description provided for @bmUntrackedTotal.
  ///
  /// In en, this message translates to:
  /// **'{amount} of holdings excluded'**
  String bmUntrackedTotal(Object amount);

  /// No description provided for @bmUntrackedHint.
  ///
  /// In en, this message translates to:
  /// **'Add purchase lots to include these holdings in the comparison.'**
  String get bmUntrackedHint;

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

  /// No description provided for @dpSimulator.
  ///
  /// In en, this message translates to:
  /// **'Payoff simulator'**
  String get dpSimulator;

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

  /// No description provided for @dpTotalOwed.
  ///
  /// In en, this message translates to:
  /// **'Total owed'**
  String get dpTotalOwed;

  /// No description provided for @dpWeightedApr.
  ///
  /// In en, this message translates to:
  /// **'Avg APR'**
  String get dpWeightedApr;

  /// No description provided for @dpMonthlyInterest.
  ///
  /// In en, this message translates to:
  /// **'Interest / mo'**
  String get dpMonthlyInterest;

  /// No description provided for @dpSplitCredit.
  ///
  /// In en, this message translates to:
  /// **'{count} credit · {amount}'**
  String dpSplitCredit(Object amount, Object count);

  /// No description provided for @dpSplitLoan.
  ///
  /// In en, this message translates to:
  /// **'{count} loans · {amount}'**
  String dpSplitLoan(Object amount, Object count);

  /// No description provided for @dpCardTermsTitle.
  ///
  /// In en, this message translates to:
  /// **'Card terms'**
  String get dpCardTermsTitle;

  /// No description provided for @dpEditCardTerms.
  ///
  /// In en, this message translates to:
  /// **'{name} terms'**
  String dpEditCardTerms(Object name);

  /// No description provided for @dpStatementBalance.
  ///
  /// In en, this message translates to:
  /// **'Statement balance'**
  String get dpStatementBalance;

  /// No description provided for @dpMinPayment.
  ///
  /// In en, this message translates to:
  /// **'Minimum payment'**
  String get dpMinPayment;

  /// No description provided for @dpDueDate.
  ///
  /// In en, this message translates to:
  /// **'Due date'**
  String get dpDueDate;

  /// No description provided for @dpDueDateNone.
  ///
  /// In en, this message translates to:
  /// **'No date'**
  String get dpDueDateNone;

  /// No description provided for @dpAddTerms.
  ///
  /// In en, this message translates to:
  /// **'Terms'**
  String get dpAddTerms;

  /// No description provided for @dpDueSoonTitle.
  ///
  /// In en, this message translates to:
  /// **'Due soon'**
  String get dpDueSoonTitle;

  /// No description provided for @dpDueInDays.
  ///
  /// In en, this message translates to:
  /// **'Due in {n}d'**
  String dpDueInDays(int n);

  /// No description provided for @dpDueToday.
  ///
  /// In en, this message translates to:
  /// **'Due today'**
  String get dpDueToday;

  /// No description provided for @dpOverdue.
  ///
  /// In en, this message translates to:
  /// **'Overdue'**
  String get dpOverdue;

  /// No description provided for @dpDueOn.
  ///
  /// In en, this message translates to:
  /// **'Due {date}'**
  String dpDueOn(Object date);

  /// No description provided for @dpInDays.
  ///
  /// In en, this message translates to:
  /// **'in {n}d'**
  String dpInDays(int n);

  /// No description provided for @dpMinAmount.
  ///
  /// In en, this message translates to:
  /// **'min {amount}'**
  String dpMinAmount(Object amount);

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

  /// No description provided for @spendByCatAvgPerMonth.
  ///
  /// In en, this message translates to:
  /// **'Average per month'**
  String get spendByCatAvgPerMonth;

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

  /// No description provided for @cfInsightRecentLabel.
  ///
  /// In en, this message translates to:
  /// **'Spent in {monthLabel}'**
  String cfInsightRecentLabel(String monthLabel);

  /// No description provided for @cfInsightAvgLabel.
  ///
  /// In en, this message translates to:
  /// **'{months}-month average'**
  String cfInsightAvgLabel(int months);

  /// No description provided for @cfInsightDelta.
  ///
  /// In en, this message translates to:
  /// **'{amount} above average ({percent})'**
  String cfInsightDelta(String amount, String percent);

  /// No description provided for @cfInsightTrendTitle.
  ///
  /// In en, this message translates to:
  /// **'Last {months} months'**
  String cfInsightTrendTitle(int months);

  /// No description provided for @cfInsightTrendSemantics.
  ///
  /// In en, this message translates to:
  /// **'Monthly spending for {category} over the last {months} months'**
  String cfInsightTrendSemantics(String category, int months);

  /// No description provided for @cfInsightTopMerchantsTitle.
  ///
  /// In en, this message translates to:
  /// **'Top merchants in {monthLabel}'**
  String cfInsightTopMerchantsTitle(String monthLabel);

  /// No description provided for @cfInsightMerchantTxCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transaction} other{{count} transactions}}'**
  String cfInsightMerchantTxCount(int count);

  /// No description provided for @cfInsightNoMerchantData.
  ///
  /// In en, this message translates to:
  /// **'No loaded transactions for this month yet'**
  String get cfInsightNoMerchantData;

  /// No description provided for @cfInsightSeeTransactions.
  ///
  /// In en, this message translates to:
  /// **'See all transactions'**
  String get cfInsightSeeTransactions;

  /// No description provided for @cfInsightSetBudget.
  ///
  /// In en, this message translates to:
  /// **'Set budget'**
  String get cfInsightSetBudget;

  /// No description provided for @cfInsightUpdateBudget.
  ///
  /// In en, this message translates to:
  /// **'Update budget'**
  String get cfInsightUpdateBudget;

  /// No description provided for @cfInsightBudgetDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Monthly budget for {category}'**
  String cfInsightBudgetDialogTitle(String category);

  /// No description provided for @cfInsightBudgetDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Suggested from your {months}-month average'**
  String cfInsightBudgetDialogHint(int months);

  /// No description provided for @cfInsightBudgetSaved.
  ///
  /// In en, this message translates to:
  /// **'Budget saved: {amount} for {category}'**
  String cfInsightBudgetSaved(String amount, String category);

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

  /// No description provided for @impHoldingsNotAttached.
  ///
  /// In en, this message translates to:
  /// **'Transactions imported, but the statement\'s positions were not attached: {error}'**
  String impHoldingsNotAttached(Object error);

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

  /// No description provided for @dashFxPill.
  ///
  /// In en, this message translates to:
  /// **'{base}/{target} {rate}'**
  String dashFxPill(Object base, Object rate, Object target);

  /// No description provided for @dashFxRateEquation.
  ///
  /// In en, this message translates to:
  /// **'1 {base} = {rate}'**
  String dashFxRateEquation(Object base, Object rate);

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

  /// No description provided for @ovDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get ovDetailsTitle;

  /// No description provided for @ovDetailsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Stats, goal & emergency fund'**
  String get ovDetailsSubtitle;

  /// No description provided for @mgmtConnectionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connections & sync'**
  String get mgmtConnectionsTitle;

  /// No description provided for @mgmtConnectionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Banks, sync status & exchange rate'**
  String get mgmtConnectionsSubtitle;

  /// No description provided for @dashSyncingAll.
  ///
  /// In en, this message translates to:
  /// **'Syncing all institutions…'**
  String get dashSyncingAll;

  /// No description provided for @dashSyncingProgress.
  ///
  /// In en, this message translates to:
  /// **'Updating… ({done} of {total})'**
  String dashSyncingProgress(int done, int total);

  /// No description provided for @dashSyncComplete.
  ///
  /// In en, this message translates to:
  /// **'Sync complete'**
  String get dashSyncComplete;

  /// No description provided for @dashSyncStillRunning.
  ///
  /// In en, this message translates to:
  /// **'Sync is taking longer than usual — it keeps running in the background'**
  String get dashSyncStillRunning;

  /// No description provided for @dashSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync failed: {error}'**
  String dashSyncFailed(Object error);

  /// No description provided for @dashSyncedAt.
  ///
  /// In en, this message translates to:
  /// **'Synced {when}'**
  String dashSyncedAt(Object when);

  /// No description provided for @dashSyncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get dashSyncNow;

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

  /// No description provided for @dashAddAccountsTitle.
  ///
  /// In en, this message translates to:
  /// **'Add accounts'**
  String get dashAddAccountsTitle;

  /// No description provided for @dashSetupReadyPill.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get dashSetupReadyPill;

  /// No description provided for @dashSetupShowDetails.
  ///
  /// In en, this message translates to:
  /// **'Show details'**
  String get dashSetupShowDetails;

  /// No description provided for @dashSetupHideDetails.
  ///
  /// In en, this message translates to:
  /// **'Hide details'**
  String get dashSetupHideDetails;

  /// No description provided for @dashSetupCheckPlaid.
  ///
  /// In en, this message translates to:
  /// **'Plaid account linking'**
  String get dashSetupCheckPlaid;

  /// No description provided for @dashSetupCheckEncryption.
  ///
  /// In en, this message translates to:
  /// **'Credential encryption'**
  String get dashSetupCheckEncryption;

  /// No description provided for @dashSetupCheckFx.
  ///
  /// In en, this message translates to:
  /// **'Exchange rates'**
  String get dashSetupCheckFx;

  /// No description provided for @dashSetupCheckCoinbase.
  ///
  /// In en, this message translates to:
  /// **'Coinbase OAuth'**
  String get dashSetupCheckCoinbase;

  /// No description provided for @dashSetupCheckPlaidWebhook.
  ///
  /// In en, this message translates to:
  /// **'Plaid webhook URL'**
  String get dashSetupCheckPlaidWebhook;

  /// No description provided for @dashSetupCheckCors.
  ///
  /// In en, this message translates to:
  /// **'CORS allow-list'**
  String get dashSetupCheckCors;

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

  /// No description provided for @dashThemeSystemShort.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get dashThemeSystemShort;

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

  /// No description provided for @dashThemeMenu.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get dashThemeMenu;

  /// No description provided for @dashPreferencesTitle.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get dashPreferencesTitle;

  /// No description provided for @dashLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get dashLanguageLabel;

  /// No description provided for @dashAccountSecurityTitle.
  ///
  /// In en, this message translates to:
  /// **'Account & security'**
  String get dashAccountSecurityTitle;

  /// No description provided for @dashServerLabel.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get dashServerLabel;

  /// No description provided for @dashServerChangeTitle.
  ///
  /// In en, this message translates to:
  /// **'Change server?'**
  String get dashServerChangeTitle;

  /// No description provided for @dashServerChangeBody.
  ///
  /// In en, this message translates to:
  /// **'Changing the server will sign you out.'**
  String get dashServerChangeBody;

  /// No description provided for @dashThemeTooltip.
  ///
  /// In en, this message translates to:
  /// **'{label} · tap to cycle, long-press to pick'**
  String dashThemeTooltip(Object label);

  /// No description provided for @dashSearchCommandsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search & commands (⌘K)'**
  String get dashSearchCommandsTooltip;

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

  /// No description provided for @projTooltipYearAmount.
  ///
  /// In en, this message translates to:
  /// **'{year} · {amount}'**
  String projTooltipYearAmount(Object amount, Object year);

  /// No description provided for @projFiNumber.
  ///
  /// In en, this message translates to:
  /// **'FI number'**
  String get projFiNumber;

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

  /// No description provided for @projIncomeAtProjectedBalance.
  ///
  /// In en, this message translates to:
  /// **'Income at projected balance'**
  String get projIncomeAtProjectedBalance;

  /// No description provided for @projIncomeAtProjectedBalanceSub.
  ///
  /// In en, this message translates to:
  /// **'Monthly · projected balance × withdrawal rate'**
  String get projIncomeAtProjectedBalanceSub;

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

  /// F12: success-rate tile caption when retirement starts at/after the projection horizon, so no withdrawal phase was simulated.
  ///
  /// In en, this message translates to:
  /// **'n/a — no retirement phase in this projection'**
  String get projSuccessRateNa;

  /// No description provided for @projCoastReachedSub.
  ///
  /// In en, this message translates to:
  /// **'Growth alone reaches your goal — you can stop contributing.'**
  String get projCoastReachedSub;

  /// No description provided for @projBaristaFiSub.
  ///
  /// In en, this message translates to:
  /// **'Nest egg needed once part-time income helps cover spending'**
  String get projBaristaFiSub;

  /// No description provided for @projBaristaIncome.
  ///
  /// In en, this message translates to:
  /// **'Barista / pension income'**
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

  /// No description provided for @projHelpExpectedReturn.
  ///
  /// In en, this message translates to:
  /// **'Gross annual return before inflation. ~7% ≈ the long-run stock-market average.'**
  String get projHelpExpectedReturn;

  /// No description provided for @projHelpInflation.
  ///
  /// In en, this message translates to:
  /// **'Shrinks future money to today\'s value. ~3% is the long-run average.'**
  String get projHelpInflation;

  /// No description provided for @projHelpVolatility.
  ///
  /// In en, this message translates to:
  /// **'How bumpy returns are — widens the shaded range of outcomes. ~13% ≈ a stock-heavy mix.'**
  String get projHelpVolatility;

  /// No description provided for @projHelpAnnualExpenses.
  ///
  /// In en, this message translates to:
  /// **'Your target yearly spending in retirement, in today\'s dollars.'**
  String get projHelpAnnualExpenses;

  /// No description provided for @projHelpSwr.
  ///
  /// In en, this message translates to:
  /// **'How much you withdraw from the portfolio each year in retirement. The classic \'4% rule\' implies a 25× nest egg.'**
  String get projHelpSwr;

  /// No description provided for @projHelpBaristaIncome.
  ///
  /// In en, this message translates to:
  /// **'Part-time work, a pension, or Social Security in retirement. Lowers the nest egg you need — this drives the Barista FI number.'**
  String get projHelpBaristaIncome;

  /// No description provided for @projHelpTaxDrag.
  ///
  /// In en, this message translates to:
  /// **'What taxes and fund fees take out of your return each year. ~0.5–1% is typical.'**
  String get projHelpTaxDrag;

  /// No description provided for @projLegendProjected.
  ///
  /// In en, this message translates to:
  /// **'Projected (average path)'**
  String get projLegendProjected;

  /// No description provided for @projLegendTarget.
  ///
  /// In en, this message translates to:
  /// **'{flavor} target'**
  String projLegendTarget(Object flavor);

  /// No description provided for @projLegendGoal.
  ///
  /// In en, this message translates to:
  /// **'Your goal'**
  String get projLegendGoal;

  /// No description provided for @projHelpYearsToRetirement.
  ///
  /// In en, this message translates to:
  /// **'When you stop contributing and start withdrawing — also sets the Coast FIRE target.'**
  String get projHelpYearsToRetirement;

  /// No description provided for @projAdvancedAssumptions.
  ///
  /// In en, this message translates to:
  /// **'Advanced assumptions'**
  String get projAdvancedAssumptions;

  /// No description provided for @projGlossaryTitle.
  ///
  /// In en, this message translates to:
  /// **'What do these terms mean?'**
  String get projGlossaryTitle;

  /// No description provided for @projTermCoast.
  ///
  /// In en, this message translates to:
  /// **'Coast FIRE'**
  String get projTermCoast;

  /// No description provided for @projTermBarista.
  ///
  /// In en, this message translates to:
  /// **'Barista FI'**
  String get projTermBarista;

  /// No description provided for @projTermRange.
  ///
  /// In en, this message translates to:
  /// **'The shaded range'**
  String get projTermRange;

  /// No description provided for @projTermRealDollars.
  ///
  /// In en, this message translates to:
  /// **'Today\'s dollars'**
  String get projTermRealDollars;

  /// No description provided for @projGlossaryFiNumberDef.
  ///
  /// In en, this message translates to:
  /// **'The nest egg that lets you live on withdrawals indefinitely — roughly your yearly spending × 25 at a 4% withdrawal rate.'**
  String get projGlossaryFiNumberDef;

  /// No description provided for @projGlossaryCoastDef.
  ///
  /// In en, this message translates to:
  /// **'The amount that, invested today, would grow to your FI number by retirement with no more saving — reach it and you can stop contributing.'**
  String get projGlossaryCoastDef;

  /// No description provided for @projGlossaryBaristaDef.
  ///
  /// In en, this message translates to:
  /// **'A smaller target: part-time work or a pension covers some of your spending, so your portfolio only has to fund the rest.'**
  String get projGlossaryBaristaDef;

  /// No description provided for @projGlossarySwrDef.
  ///
  /// In en, this message translates to:
  /// **'The share of your portfolio you withdraw each year in retirement. The well-known \'4% rule\' is the default here.'**
  String get projGlossarySwrDef;

  /// No description provided for @projGlossaryRangeDef.
  ///
  /// In en, this message translates to:
  /// **'The band is a 1,000-run market simulation — the spread of good and bad luck. \'Success rate\' is how often the money lasts the whole horizon.'**
  String get projGlossaryRangeDef;

  /// No description provided for @projGlossaryRealDef.
  ///
  /// In en, this message translates to:
  /// **'Every figure is in today\'s dollars, so a future amount already accounts for inflation.'**
  String get projGlossaryRealDef;

  /// F11: glossary term for the chart's bold expected-path line.
  ///
  /// In en, this message translates to:
  /// **'The bold projected line'**
  String get projTermAveragePath;

  /// F11: glossary definition disclosing that the bold line is the mean path, which can sit above the Monte Carlo median.
  ///
  /// In en, this message translates to:
  /// **'The bold line compounds your expected return exactly — the average path. The typical (median) simulated outcome is often lower, so read it as an illustration, not a forecast.'**
  String get projGlossaryAveragePathDef;

  /// No description provided for @projFirePlanTitle.
  ///
  /// In en, this message translates to:
  /// **'Your FIRE plan'**
  String get projFirePlanTitle;

  /// No description provided for @projGoalLabel.
  ///
  /// In en, this message translates to:
  /// **'Goal'**
  String get projGoalLabel;

  /// No description provided for @projTermLifestyle.
  ///
  /// In en, this message translates to:
  /// **'Lean / Standard / Fat'**
  String get projTermLifestyle;

  /// No description provided for @projGlossaryLifestyleDef.
  ///
  /// In en, this message translates to:
  /// **'Lifestyle levels — Lean is frugal, Fat is generous, Standard ≈ your tracked spending. They set your annual expenses, which sets every target.'**
  String get projGlossaryLifestyleDef;

  /// No description provided for @projFocusFull.
  ///
  /// In en, this message translates to:
  /// **'Full FIRE'**
  String get projFocusFull;

  /// No description provided for @projFullReached.
  ///
  /// In en, this message translates to:
  /// **'You\'ve reached your FI number — full FIRE is covered.'**
  String get projFullReached;

  /// No description provided for @projFullYearsAway.
  ///
  /// In en, this message translates to:
  /// **'About {years} years away at your current pace.'**
  String projFullYearsAway(Object years);

  /// No description provided for @projFullUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Not reachable at your current pace — raise savings or returns.'**
  String get projFullUnreachable;

  /// No description provided for @projCoastTake.
  ///
  /// In en, this message translates to:
  /// **'You\'re at {amount} today — close the gap and growth alone finishes the job.'**
  String projCoastTake(Object amount);

  /// No description provided for @projBaristaPrompt.
  ///
  /// In en, this message translates to:
  /// **'Set \'Barista / pension income\' above to see this lower target.'**
  String get projBaristaPrompt;

  /// No description provided for @projSpendingLevel.
  ///
  /// In en, this message translates to:
  /// **'Lifestyle'**
  String get projSpendingLevel;

  /// No description provided for @projPresetLean.
  ///
  /// In en, this message translates to:
  /// **'Lean'**
  String get projPresetLean;

  /// No description provided for @projPresetStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get projPresetStandard;

  /// No description provided for @projPresetFat.
  ///
  /// In en, this message translates to:
  /// **'Fat'**
  String get projPresetFat;

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

  /// F2: chart-card error message when the projection fetch fails and there is no cached data to show.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your projection.'**
  String get projLoadFailed;

  /// F2: retry button under the projection load-failure message.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get projRetry;

  /// F3: provenance hint under a slider whose default was adopted from the user's tracked cash flow; {months} is how many months of history back it.
  ///
  /// In en, this message translates to:
  /// **'{months, plural, =1{Based on 1 month of your data} other{Based on {months} months of your data}}'**
  String projBasedOnMonths(int months);

  /// F3: hint under the annual-expenses slider when the static $40k default stands (no tracked data adopted).
  ///
  /// In en, this message translates to:
  /// **'Estimate — adjust to your spending'**
  String get projExpensesEstimateHint;

  /// F5: inline validation error for the goal dialog's target amount field.
  ///
  /// In en, this message translates to:
  /// **'Enter an amount above zero (up to 1 billion)'**
  String get projGoalAmountInvalid;

  /// F5: inline validation error for the goal dialog's target year field. The explicit placeholders below keep this declaration order in the generated signature: (min, max).
  ///
  /// In en, this message translates to:
  /// **'Enter a year between {min} and {max}'**
  String projGoalYearRange(int min, int max);

  /// F5: snackbar when persisting the net-worth goal to the backend fails.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save your goal'**
  String get projGoalSaveFailed;

  /// U1: small label on the chart's dashed vertical marker at the retirement year (the accumulation-to-drawdown kink).
  ///
  /// In en, this message translates to:
  /// **'Retirement'**
  String get projRetirementMarker;

  /// U1: label on the goal line when the goal amount exceeds the chart's y-range and the line is clamped to the top edge; {amount} is the compact goal amount.
  ///
  /// In en, this message translates to:
  /// **'Your goal: {amount}'**
  String projGoalOffChart(String amount);

  /// U2: inline validation error in the typed slider-value dialog; min/max arrive pre-formatted as money. The explicit placeholders below keep this declaration order in the generated signature: (min, max).
  ///
  /// In en, this message translates to:
  /// **'Enter an amount between {min} and {max}'**
  String projValueEntryRange(String min, String max);

  /// U5: inline validation error in the typed slider-value dialog for percent sliders; min/max arrive pre-formatted as percentages (formatPercent). The explicit placeholders below keep this declaration order in the generated signature: (min, max).
  ///
  /// In en, this message translates to:
  /// **'Enter a rate between {min} and {max}'**
  String projValueEntryRangePercent(String min, String max);

  /// U5: inline validation error in the typed slider-value dialog for the whole-year sliders (years to retirement, projection years); also shown for fractional input like 12.5, which is rejected, not clamped. The explicit placeholders below keep this declaration order in the generated signature: (min, max).
  ///
  /// In en, this message translates to:
  /// **'Enter a whole number of years between {min} and {max}'**
  String projValueEntryWholeYears(int min, int max);

  /// U3: caption under the monthly-savings slider relating the current contribution to tracked annual income; {pct} is a pre-formatted percentage, capped at 100%.
  ///
  /// In en, this message translates to:
  /// **'You\'re saving about {pct} of your income'**
  String projSavingsRateCaption(String pct);

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

  /// No description provided for @taxSectionLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'This section could not be loaded — the figures below are not a result.'**
  String get taxSectionLoadFailed;

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

  /// No description provided for @taxExportsTitle.
  ///
  /// In en, this message translates to:
  /// **'Year-end export pack'**
  String get taxExportsTitle;

  /// No description provided for @taxExportsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Filing-shaped documents generated from the figures on this screen — pick a tax year and download each one.'**
  String get taxExportsSubtitle;

  /// No description provided for @taxExportsFbar.
  ///
  /// In en, this message translates to:
  /// **'FBAR worksheet (FinCEN 114)'**
  String get taxExportsFbar;

  /// No description provided for @taxExportsFbarDesc.
  ///
  /// In en, this message translates to:
  /// **'Maximum annual balance per foreign account, in USD. Printable.'**
  String get taxExportsFbarDesc;

  /// No description provided for @taxExports8949.
  ///
  /// In en, this message translates to:
  /// **'Form 8949 CSV'**
  String get taxExports8949;

  /// No description provided for @taxExports8949Desc.
  ///
  /// In en, this message translates to:
  /// **'Realized gains split short/long-term with proceeds, cost basis, and gain.'**
  String get taxExports8949Desc;

  /// No description provided for @taxExportsScheduleB.
  ///
  /// In en, this message translates to:
  /// **'Schedule B interest CSV'**
  String get taxExportsScheduleB;

  /// No description provided for @taxExportsScheduleBDesc.
  ///
  /// In en, this message translates to:
  /// **'Interest income by payer — personal loans plus bank and CETES/bond interest.'**
  String get taxExportsScheduleBDesc;

  /// No description provided for @taxExportsMx.
  ///
  /// In en, this message translates to:
  /// **'MX annual summary CSV'**
  String get taxExportsMx;

  /// No description provided for @taxExportsMxDesc.
  ///
  /// In en, this message translates to:
  /// **'Income, dividends, interest, and realized gains with the simplified SAT estimate.'**
  String get taxExportsMxDesc;

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

  /// No description provided for @taxIncomeDecomposition.
  ///
  /// In en, this message translates to:
  /// **'Wages {wages} · Dividends {dividends} · Interest {interest}'**
  String taxIncomeDecomposition(
    String wages,
    String dividends,
    String interest,
  );

  /// No description provided for @taxMxWithheld.
  ///
  /// In en, this message translates to:
  /// **'ISR already withheld {withheld} · est. remaining {net}'**
  String taxMxWithheld(String withheld, String net);

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
  /// **'Disclaimer: Tax estimates are approximations using {bracketYear} IRS/SAT brackets. Consult a qualified tax professional for filing.'**
  String taxDisclaimer(String bracketYear);

  /// No description provided for @taxConstantsUnverified.
  ///
  /// In en, this message translates to:
  /// **'Estimates — tax constants pending verification'**
  String get taxConstantsUnverified;

  /// No description provided for @taxFilingStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Filing status'**
  String get taxFilingStatusLabel;

  /// No description provided for @taxYearLabel.
  ///
  /// In en, this message translates to:
  /// **'Tax year'**
  String get taxYearLabel;

  /// No description provided for @taxRealizedGainsTitle.
  ///
  /// In en, this message translates to:
  /// **'Realized gains'**
  String get taxRealizedGainsTitle;

  /// No description provided for @taxIncomeSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get taxIncomeSectionTitle;

  /// No description provided for @taxTermShort.
  ///
  /// In en, this message translates to:
  /// **'Short'**
  String get taxTermShort;

  /// No description provided for @taxTermLong.
  ///
  /// In en, this message translates to:
  /// **'Long'**
  String get taxTermLong;

  /// No description provided for @taxTermUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get taxTermUnknown;

  /// No description provided for @taxColProceeds.
  ///
  /// In en, this message translates to:
  /// **'Proceeds'**
  String get taxColProceeds;

  /// No description provided for @taxColCost.
  ///
  /// In en, this message translates to:
  /// **'Cost'**
  String get taxColCost;

  /// No description provided for @taxAcquiredUnknown.
  ///
  /// In en, this message translates to:
  /// **'Acquired —'**
  String get taxAcquiredUnknown;

  /// No description provided for @taxAcquiredToSold.
  ///
  /// In en, this message translates to:
  /// **'{acquired} → {sold}'**
  String taxAcquiredToSold(String acquired, String sold);

  /// No description provided for @taxTaxAdvantagedBadge.
  ///
  /// In en, this message translates to:
  /// **'Tax-advantaged'**
  String get taxTaxAdvantagedBadge;

  /// No description provided for @taxTaxAdvantagedSection.
  ///
  /// In en, this message translates to:
  /// **'Tax-advantaged accounts (excluded from taxable totals)'**
  String get taxTaxAdvantagedSection;

  /// No description provided for @taxTaxAdvantagedNote.
  ///
  /// In en, this message translates to:
  /// **'Disposals inside 401(k)/IRA/HSA-type accounts. Not part of the taxable headline above.'**
  String get taxTaxAdvantagedNote;

  /// No description provided for @taxGainsSubtotal.
  ///
  /// In en, this message translates to:
  /// **'Net realized gain: {amount}'**
  String taxGainsSubtotal(String amount);

  /// No description provided for @taxIncomeSubtotal.
  ///
  /// In en, this message translates to:
  /// **'Total income: {amount}'**
  String taxIncomeSubtotal(String amount);

  /// No description provided for @taxSubtotalReconcileNote.
  ///
  /// In en, this message translates to:
  /// **'Matches the {kpi} card above.'**
  String taxSubtotalReconcileNote(String kpi);

  /// No description provided for @taxNoDisposals.
  ///
  /// In en, this message translates to:
  /// **'No realized disposals for this year.'**
  String get taxNoDisposals;

  /// No description provided for @taxScenarioUsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'If all income were taxed in the US'**
  String get taxScenarioUsSubtitle;

  /// No description provided for @taxScenarioMxSubtitle.
  ///
  /// In en, this message translates to:
  /// **'If all income were taxed in Mexico'**
  String get taxScenarioMxSubtitle;

  /// No description provided for @taxScenarioUsCaveat.
  ///
  /// In en, this message translates to:
  /// **'Federal only — excludes NIIT and state tax, no foreign tax credit.'**
  String get taxScenarioUsCaveat;

  /// No description provided for @taxScenarioMxCaveat.
  ///
  /// In en, this message translates to:
  /// **'Everything run through the salary ISR tarifa (a simplification).'**
  String get taxScenarioMxCaveat;

  /// No description provided for @taxScenariosNote.
  ///
  /// In en, this message translates to:
  /// **'These are two alternative scenarios over the same income, not amounts you add together.'**
  String get taxScenariosNote;

  /// No description provided for @taxRoughEstimateBadge.
  ///
  /// In en, this message translates to:
  /// **'Rough estimate'**
  String get taxRoughEstimateBadge;

  /// No description provided for @taxRoughEstimateTooltip.
  ///
  /// In en, this message translates to:
  /// **'No purchase lots on record — gains use a blended cost-basis guess.'**
  String get taxRoughEstimateTooltip;

  /// No description provided for @taxAssumptionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Assumptions'**
  String get taxAssumptionsTitle;

  /// No description provided for @taxAssumptionBracketYear.
  ///
  /// In en, this message translates to:
  /// **'Bracket year: {year}'**
  String taxAssumptionBracketYear(String year);

  /// No description provided for @taxAssumptionFx.
  ///
  /// In en, this message translates to:
  /// **'FX: each row converted at its own date\'s stored USD/MXN rate.'**
  String get taxAssumptionFx;

  /// No description provided for @taxAssumptionFilingStatus.
  ///
  /// In en, this message translates to:
  /// **'Filing status: {status}'**
  String taxAssumptionFilingStatus(String status);

  /// No description provided for @taxAssumptionExclusions.
  ///
  /// In en, this message translates to:
  /// **'Excludes tax-advantaged accounts (401(k)/IRA/HSA).'**
  String get taxAssumptionExclusions;

  /// No description provided for @taxAssumptionHoldingsNoBasis.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 holding has no cost basis on record} other{{count} holdings have no cost basis on record}}'**
  String taxAssumptionHoldingsNoBasis(int count);

  /// No description provided for @taxAssumptionProReview.
  ///
  /// In en, this message translates to:
  /// **'Wording and constants are pending review by a tax professional — treat as guidance, not advice.'**
  String get taxAssumptionProReview;

  /// No description provided for @taxUnrealizedTitle.
  ///
  /// In en, this message translates to:
  /// **'Unrealized positions — what if I sell'**
  String get taxUnrealizedTitle;

  /// No description provided for @taxUnrealizedShortTerm.
  ///
  /// In en, this message translates to:
  /// **'Short-term lots'**
  String get taxUnrealizedShortTerm;

  /// No description provided for @taxUnrealizedLongTerm.
  ///
  /// In en, this message translates to:
  /// **'Long-term lots'**
  String get taxUnrealizedLongTerm;

  /// No description provided for @taxNoUnrealizedLots.
  ///
  /// In en, this message translates to:
  /// **'No taxable lots to evaluate.'**
  String get taxNoUnrealizedLots;

  /// No description provided for @taxUnrealizedSubtotal.
  ///
  /// In en, this message translates to:
  /// **'Unrealized: {amount}'**
  String taxUnrealizedSubtotal(String amount);

  /// No description provided for @taxFlipsToLongIn.
  ///
  /// In en, this message translates to:
  /// **'Long-term in {days}d — {date}'**
  String taxFlipsToLongIn(String days, String date);

  /// No description provided for @taxColBasis.
  ///
  /// In en, this message translates to:
  /// **'Basis'**
  String get taxColBasis;

  /// No description provided for @taxColValue.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get taxColValue;

  /// No description provided for @taxHarvestTitle.
  ///
  /// In en, this message translates to:
  /// **'Harvest candidates'**
  String get taxHarvestTitle;

  /// No description provided for @taxHarvestEstimate.
  ///
  /// In en, this message translates to:
  /// **'Est. tax saving {amount}'**
  String taxHarvestEstimate(String amount);

  /// No description provided for @taxHarvestEstimateBadge.
  ///
  /// In en, this message translates to:
  /// **'Estimate'**
  String get taxHarvestEstimateBadge;

  /// No description provided for @taxHarvestEstimateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Loss × your marginal rate — an estimate on unverified constants, not a guaranteed saving.'**
  String get taxHarvestEstimateTooltip;

  /// No description provided for @taxHarvestNote.
  ///
  /// In en, this message translates to:
  /// **'Selling these losers could offset gains. Estimated saving = loss × your marginal rate.'**
  String get taxHarvestNote;

  /// No description provided for @taxNoHarvestCandidates.
  ///
  /// In en, this message translates to:
  /// **'No loss lots to harvest right now.'**
  String get taxNoHarvestCandidates;

  /// No description provided for @taxHarvestLossesNoSavings.
  ///
  /// In en, this message translates to:
  /// **'Loss lots exist above, but under this simplified estimate (loss × marginal rate) selling them wouldn\'t reduce your estimated tax right now.'**
  String get taxHarvestLossesNoSavings;

  /// No description provided for @taxWashSaleMarker.
  ///
  /// In en, this message translates to:
  /// **'Wash sale'**
  String get taxWashSaleMarker;

  /// No description provided for @taxWashSaleSafeAfter.
  ///
  /// In en, this message translates to:
  /// **'Safe to re-buy after {date}'**
  String taxWashSaleSafeAfter(String date);

  /// No description provided for @taxWashSaleTooltip.
  ///
  /// In en, this message translates to:
  /// **'A same-security buy near this date can disallow the loss. Re-buying after the safe date avoids the wash-sale rule.'**
  String get taxWashSaleTooltip;

  /// No description provided for @taxFbarTitle.
  ///
  /// In en, this message translates to:
  /// **'Foreign accounts — FBAR monitor'**
  String get taxFbarTitle;

  /// No description provided for @taxFbarPeakAggregate.
  ///
  /// In en, this message translates to:
  /// **'Peak aggregate foreign balance (this year)'**
  String get taxFbarPeakAggregate;

  /// No description provided for @taxFbarThreshold.
  ///
  /// In en, this message translates to:
  /// **'FBAR reporting threshold: {amount}'**
  String taxFbarThreshold(String amount);

  /// No description provided for @taxFbarExceeded.
  ///
  /// In en, this message translates to:
  /// **'Aggregate exceeded the threshold this year'**
  String get taxFbarExceeded;

  /// No description provided for @taxFbarUnder.
  ///
  /// In en, this message translates to:
  /// **'Aggregate stayed under the threshold this year'**
  String get taxFbarUnder;

  /// No description provided for @taxFbarPeakDate.
  ///
  /// In en, this message translates to:
  /// **'Peak on {date}'**
  String taxFbarPeakDate(String date);

  /// No description provided for @taxFbarInformational.
  ///
  /// In en, this message translates to:
  /// **'Informational only — this does not decide an FBAR filing obligation. Consult a tax professional.'**
  String get taxFbarInformational;

  /// No description provided for @taxFbarFatcaNote.
  ///
  /// In en, this message translates to:
  /// **'FATCA Form 8938 thresholds are different and higher, and are not computed here.'**
  String get taxFbarFatcaNote;

  /// No description provided for @taxFbarNoForeignAccounts.
  ///
  /// In en, this message translates to:
  /// **'No foreign accounts detected for this year.'**
  String get taxFbarNoForeignAccounts;

  /// No description provided for @taxFbarConfirmLocation.
  ///
  /// In en, this message translates to:
  /// **'Confirm location'**
  String get taxFbarConfirmLocation;

  /// No description provided for @taxFbarConfirmLocationTooltip.
  ///
  /// In en, this message translates to:
  /// **'This institution has no country set, so the account was counted as foreign only because it is in MXN. Set the institution\'s country to confirm or correct this.'**
  String get taxFbarConfirmLocationTooltip;

  /// No description provided for @taxFbarAccountPeak.
  ///
  /// In en, this message translates to:
  /// **'On peak date: {amount}'**
  String taxFbarAccountPeak(String amount);

  /// No description provided for @taxFbarAccountYtdMax.
  ///
  /// In en, this message translates to:
  /// **'Own YTD max: {amount}'**
  String taxFbarAccountYtdMax(String amount);

  /// No description provided for @taxRetirementTitle.
  ///
  /// In en, this message translates to:
  /// **'Retirement contributions'**
  String get taxRetirementTitle;

  /// No description provided for @taxRetirementGroup401k.
  ///
  /// In en, this message translates to:
  /// **'401(k) / 403(b) / 457(b)'**
  String get taxRetirementGroup401k;

  /// No description provided for @taxRetirementGroupIra.
  ///
  /// In en, this message translates to:
  /// **'IRA (Traditional + Roth)'**
  String get taxRetirementGroupIra;

  /// No description provided for @taxRetirementGroupHsa.
  ///
  /// In en, this message translates to:
  /// **'HSA'**
  String get taxRetirementGroupHsa;

  /// No description provided for @taxContributedOfLimit.
  ///
  /// In en, this message translates to:
  /// **'{ytd} of {limit}'**
  String taxContributedOfLimit(String ytd, String limit);

  /// No description provided for @taxBackdoorRothBadge.
  ///
  /// In en, this message translates to:
  /// **'Backdoor Roth'**
  String get taxBackdoorRothBadge;

  /// No description provided for @taxMegaBackdoorNote.
  ///
  /// In en, this message translates to:
  /// **'§415(c) total (elective + employer + after-tax); elective limit {elective}. {room} mega-backdoor Roth room left.'**
  String taxMegaBackdoorNote(String elective, String room);

  /// No description provided for @taxHsaFamilyCoverage.
  ///
  /// In en, this message translates to:
  /// **'Family coverage'**
  String get taxHsaFamilyCoverage;

  /// No description provided for @taxHsaEmployerNote.
  ///
  /// In en, this message translates to:
  /// **'includes {amount} employer'**
  String taxHsaEmployerNote(String amount);

  /// No description provided for @tax401kElectiveSet.
  ///
  /// In en, this message translates to:
  /// **'+ Set your elective deferral to split this'**
  String get tax401kElectiveSet;

  /// No description provided for @tax401kElectiveSplit.
  ///
  /// In en, this message translates to:
  /// **'Elective {elective} of {limit} · employer + after-tax {rest}'**
  String tax401kElectiveSplit(String elective, String limit, String rest);

  /// No description provided for @tax401kElectiveDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Annual 401k elective deferral'**
  String get tax401kElectiveDialogTitle;

  /// No description provided for @tax401kElectiveDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Your employee contribution (pre-tax + Roth); limit {limit}'**
  String tax401kElectiveDialogHint(String limit);

  /// No description provided for @taxRemainingRoom.
  ///
  /// In en, this message translates to:
  /// **'Room left: {amount}'**
  String taxRemainingRoom(String amount);

  /// No description provided for @taxContributionDeadline.
  ///
  /// In en, this message translates to:
  /// **'Deadline: {date}'**
  String taxContributionDeadline(String date);

  /// No description provided for @taxPriorYearWindowNote.
  ///
  /// In en, this message translates to:
  /// **'Prior-year contributions allowed until this deadline.'**
  String get taxPriorYearWindowNote;

  /// No description provided for @taxMatchRolloverCaveat.
  ///
  /// In en, this message translates to:
  /// **'May include employer match or rollovers — personal contributions could be overcounted.'**
  String get taxMatchRolloverCaveat;

  /// No description provided for @taxContributionOverLimit.
  ///
  /// In en, this message translates to:
  /// **'Over the base limit'**
  String get taxContributionOverLimit;

  /// No description provided for @taxCatchUpNote.
  ///
  /// In en, this message translates to:
  /// **'+{amount} catch-up if age-eligible'**
  String taxCatchUpNote(String amount);

  /// No description provided for @taxNoRetirementAccounts.
  ///
  /// In en, this message translates to:
  /// **'No retirement accounts with contributions this year.'**
  String get taxNoRetirementAccounts;

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
  /// **'Since your last visit'**
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

  /// No description provided for @hiddenClosedAccounts.
  ///
  /// In en, this message translates to:
  /// **'Closed accounts'**
  String get hiddenClosedAccounts;

  /// No description provided for @hiddenClosedAccountsIntro.
  ///
  /// In en, this message translates to:
  /// **'Accounts Patrimonio archived because they were closed or removed at the bank. They no longer count toward your net worth. Restore one to bring it back, or delete it permanently.'**
  String get hiddenClosedAccountsIntro;

  /// No description provided for @hiddenNoClosedAccounts.
  ///
  /// In en, this message translates to:
  /// **'No closed accounts. When a bank reports an account as closed, it lands here instead of disappearing.'**
  String get hiddenNoClosedAccounts;

  /// No description provided for @accountRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get accountRestore;

  /// No description provided for @accountRestored.
  ///
  /// In en, this message translates to:
  /// **'Restored \"{name}\"'**
  String accountRestored(String name);

  /// No description provided for @accountDeletePermanently.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get accountDeletePermanently;

  /// No description provided for @accountDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account permanently?'**
  String get accountDeleteConfirmTitle;

  /// No description provided for @accountDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes \"{name}\" and all of its transactions. This can\'t be undone.'**
  String accountDeleteConfirmBody(String name);

  /// No description provided for @accountDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted \"{name}\"'**
  String accountDeleted(String name);

  /// No description provided for @accountClosedOn.
  ///
  /// In en, this message translates to:
  /// **'Closed {date}'**
  String accountClosedOn(Object date);

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

  /// No description provided for @pfSearchAccounts.
  ///
  /// In en, this message translates to:
  /// **'Search accounts'**
  String get pfSearchAccounts;

  /// No description provided for @pfHideZero.
  ///
  /// In en, this message translates to:
  /// **'Hide \$0'**
  String get pfHideZero;

  /// No description provided for @pfNoAccountMatches.
  ///
  /// In en, this message translates to:
  /// **'No accounts match'**
  String get pfNoAccountMatches;

  /// No description provided for @pfClearFilters.
  ///
  /// In en, this message translates to:
  /// **'Clear filters'**
  String get pfClearFilters;

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

  /// No description provided for @pfUnrecognizedTypes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Includes an account type we don\'t recognize yet} other{Includes account types we don\'t recognize yet}}'**
  String pfUnrecognizedTypes(int count);

  /// No description provided for @pfVaults.
  ///
  /// In en, this message translates to:
  /// **'Vaults'**
  String get pfVaults;

  /// No description provided for @pfCards.
  ///
  /// In en, this message translates to:
  /// **'Cards'**
  String get pfCards;

  /// No description provided for @pfBase.
  ///
  /// In en, this message translates to:
  /// **'base'**
  String get pfBase;

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

  /// No description provided for @pfTotalInMxn.
  ///
  /// In en, this message translates to:
  /// **'Total value in pesos'**
  String get pfTotalInMxn;

  /// No description provided for @pfTotalInUsd.
  ///
  /// In en, this message translates to:
  /// **'Total value in dollars'**
  String get pfTotalInUsd;

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

  /// Toolbar counter. Placeholder order matters: gen-l10n derives the positional parameters from this declaration order, and the call site passes (holdings, accounts) — declaring accounts first transposed the two numbers.
  ///
  /// In en, this message translates to:
  /// **'{holdings, plural, =1{1 holding} other{{holdings} holdings}} · {accounts, plural, =1{1 account} other{{accounts} accounts}}'**
  String pfHoldingsAccountsCount(int holdings, int accounts);

  /// Narrow-toolbar variant of pfHoldingsAccountsCount: fits at 390px without ellipsizing either number. Same (holdings, accounts) parameter order.
  ///
  /// In en, this message translates to:
  /// **'{holdings} · {accounts, plural, =1{1 acct} other{{accounts} accts}}'**
  String fix3HoldingsAccountsCompact(int holdings, int accounts);

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

  /// No description provided for @pfCostBasisUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Cost basis unavailable from this institution'**
  String get pfCostBasisUnavailable;

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

  /// No description provided for @acctDetailsToggle.
  ///
  /// In en, this message translates to:
  /// **'Account details'**
  String get acctDetailsToggle;

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

  /// No description provided for @impCoverageTitle.
  ///
  /// In en, this message translates to:
  /// **'Statement coverage'**
  String get impCoverageTitle;

  /// No description provided for @impCoverageThrough.
  ///
  /// In en, this message translates to:
  /// **'through {month}'**
  String impCoverageThrough(String month);

  /// No description provided for @impCoverageLastFile.
  ///
  /// In en, this message translates to:
  /// **'{file}'**
  String impCoverageLastFile(String file);

  /// No description provided for @impCoverageImports.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 import} other{{count} imports}}'**
  String impCoverageImports(int count);

  /// No description provided for @impCoverageMaybeDue.
  ///
  /// In en, this message translates to:
  /// **'A newer statement may be available'**
  String get impCoverageMaybeDue;

  /// No description provided for @impCoverageEmpty.
  ///
  /// In en, this message translates to:
  /// **'No statements imported yet'**
  String get impCoverageEmpty;

  /// No description provided for @impAsOfDate.
  ///
  /// In en, this message translates to:
  /// **'as of {date}'**
  String impAsOfDate(Object date);

  /// No description provided for @impStaleBannerSummary.
  ///
  /// In en, this message translates to:
  /// **'{name} data is {days, plural, =1{1 day} other{{days} days}} old — import a statement'**
  String impStaleBannerSummary(int days, Object name);

  /// No description provided for @impStaleBannerMore.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more institution also needs} other{{count} more institutions also need}} a fresh import'**
  String impStaleBannerMore(int count);

  /// No description provided for @impStaleBannerImport.
  ///
  /// In en, this message translates to:
  /// **'Import statement'**
  String get impStaleBannerImport;

  /// No description provided for @impStaleBannerDismiss.
  ///
  /// In en, this message translates to:
  /// **'Snooze for 7 days'**
  String get impStaleBannerDismiss;

  /// No description provided for @impStaleSnoozedSnack.
  ///
  /// In en, this message translates to:
  /// **'Import reminders snoozed for 7 days'**
  String get impStaleSnoozedSnack;

  /// No description provided for @impStaleThresholdTitle.
  ///
  /// In en, this message translates to:
  /// **'Import staleness reminder'**
  String get impStaleThresholdTitle;

  /// No description provided for @impStaleThresholdSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Remind me when imported data is older than this'**
  String get impStaleThresholdSubtitle;

  /// No description provided for @impStaleRemindHeader.
  ///
  /// In en, this message translates to:
  /// **'Remind me per institution'**
  String get impStaleRemindHeader;

  /// No description provided for @impStaleRemindSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Off silences the banner and bell for that institution — its “as of” dates stay visible'**
  String get impStaleRemindSubtitle;

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

  /// No description provided for @dlgTxEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit transaction'**
  String get dlgTxEditTitle;

  /// No description provided for @dlgTxAdded.
  ///
  /// In en, this message translates to:
  /// **'Transaction added'**
  String get dlgTxAdded;

  /// No description provided for @dlgTxUpdated.
  ///
  /// In en, this message translates to:
  /// **'Transaction updated'**
  String get dlgTxUpdated;

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

  /// No description provided for @lwSyncBannerDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss for a week'**
  String get lwSyncBannerDismiss;

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

  /// No description provided for @lwNotifRepaymentDueTodayTitle.
  ///
  /// In en, this message translates to:
  /// **'{borrower} repayment due today'**
  String lwNotifRepaymentDueTodayTitle(Object borrower);

  /// No description provided for @lwNotifRepaymentDueTodayDetail.
  ///
  /// In en, this message translates to:
  /// **'Installment #{number} of {amount} is due today.'**
  String lwNotifRepaymentDueTodayDetail(Object amount, Object number);

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

  /// No description provided for @lwNotifNetWorthUpTitle.
  ///
  /// In en, this message translates to:
  /// **'Net worth up {amount} ({pct})'**
  String lwNotifNetWorthUpTitle(String amount, String pct);

  /// No description provided for @lwNotifNetWorthDownTitle.
  ///
  /// In en, this message translates to:
  /// **'Net worth down {amount} ({pct})'**
  String lwNotifNetWorthDownTitle(String amount, String pct);

  /// No description provided for @lwNotifNetWorthSinceSyncDetail.
  ///
  /// In en, this message translates to:
  /// **'Since your last sync · {date}'**
  String lwNotifNetWorthSinceSyncDetail(String date);

  /// No description provided for @lwNotifSinceVisitDetail.
  ///
  /// In en, this message translates to:
  /// **'Since your last visit · {date}. Tap to review.'**
  String lwNotifSinceVisitDetail(String date);

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

  /// No description provided for @lwNotifAccountArchivedTitle.
  ///
  /// In en, this message translates to:
  /// **'Account closed: {institution}'**
  String lwNotifAccountArchivedTitle(String institution);

  /// No description provided for @lwNotifAccountArchivedDetail.
  ///
  /// In en, this message translates to:
  /// **'{account} is no longer at {institution} — it\'s been archived. Tap to restore or remove.'**
  String lwNotifAccountArchivedDetail(String account, String institution);

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

  /// Screen-reader label for the notifications bell button when there are unread alerts.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Notifications, 1 unread alert} other{Notifications, {count} unread alerts}}'**
  String lwNotifBellUnread(int count);

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

  /// No description provided for @lwNotifHeader.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get lwNotifHeader;

  /// No description provided for @lwNotifMarkAllRead.
  ///
  /// In en, this message translates to:
  /// **'Mark all read'**
  String get lwNotifMarkAllRead;

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

  /// No description provided for @lwPerfTwrMethodNote.
  ///
  /// In en, this message translates to:
  /// **'Time-weighted return over the selected period'**
  String get lwPerfTwrMethodNote;

  /// No description provided for @lwPerfTwrCoverage.
  ///
  /// In en, this message translates to:
  /// **'Reflects {pct} of your portfolio we can price daily'**
  String lwPerfTwrCoverage(Object pct);

  /// No description provided for @ovByCurrency.
  ///
  /// In en, this message translates to:
  /// **'By currency'**
  String get ovByCurrency;

  /// No description provided for @lendingGlanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Lending'**
  String get lendingGlanceTitle;

  /// No description provided for @lendingGlanceOutstanding.
  ///
  /// In en, this message translates to:
  /// **'Outstanding'**
  String get lendingGlanceOutstanding;

  /// No description provided for @lendingGlanceActiveCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 active loan} other{{count} active loans}}'**
  String lendingGlanceActiveCount(int count);

  /// No description provided for @lendingGlanceNextDue.
  ///
  /// In en, this message translates to:
  /// **'Next due'**
  String get lendingGlanceNextDue;

  /// No description provided for @lendingGlanceDueIn.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{due in 1 day} other{due in {days} days}}'**
  String lendingGlanceDueIn(int days);

  /// No description provided for @lendingGlanceDueToday.
  ///
  /// In en, this message translates to:
  /// **'due today'**
  String get lendingGlanceDueToday;

  /// No description provided for @lendingGlanceOverdueBy.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{overdue by 1 day} other{overdue by {days} days}}'**
  String lendingGlanceOverdueBy(int days);

  /// No description provided for @pfGoalPaceAhead.
  ///
  /// In en, this message translates to:
  /// **'Ahead of pace'**
  String get pfGoalPaceAhead;

  /// No description provided for @pfGoalPaceOnTrack.
  ///
  /// In en, this message translates to:
  /// **'On track'**
  String get pfGoalPaceOnTrack;

  /// No description provided for @pfGoalPaceBehind.
  ///
  /// In en, this message translates to:
  /// **'Behind pace'**
  String get pfGoalPaceBehind;

  /// No description provided for @mgmtArchivedTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-archived accounts'**
  String get mgmtArchivedTitle;

  /// No description provided for @mgmtArchivedIntro.
  ///
  /// In en, this message translates to:
  /// **'Accounts the sync closed at the bank. Restore one to bring it back into your net worth.'**
  String get mgmtArchivedIntro;

  /// No description provided for @mgmtArchivedManageAll.
  ///
  /// In en, this message translates to:
  /// **'Manage all hidden items'**
  String get mgmtArchivedManageAll;

  /// No description provided for @lendingInterest.
  ///
  /// In en, this message translates to:
  /// **'Interest'**
  String get lendingInterest;

  /// No description provided for @lendingInterestEarnedLabel.
  ///
  /// In en, this message translates to:
  /// **'Interest earned'**
  String get lendingInterestEarnedLabel;

  /// No description provided for @lendingAccruedNotYetPaid.
  ///
  /// In en, this message translates to:
  /// **'Accrued (not yet paid)'**
  String get lendingAccruedNotYetPaid;

  /// No description provided for @lendingAgingTitle.
  ///
  /// In en, this message translates to:
  /// **'Due & overdue'**
  String get lendingAgingTitle;

  /// No description provided for @lendingAgingOverdue30.
  ///
  /// In en, this message translates to:
  /// **'30+ days overdue'**
  String get lendingAgingOverdue30;

  /// No description provided for @lendingAgingOverdue7.
  ///
  /// In en, this message translates to:
  /// **'7-29 days overdue'**
  String get lendingAgingOverdue7;

  /// No description provided for @lendingAgingOverdue1.
  ///
  /// In en, this message translates to:
  /// **'1-6 days overdue'**
  String get lendingAgingOverdue1;

  /// No description provided for @lendingAgingDueToday.
  ///
  /// In en, this message translates to:
  /// **'Due today'**
  String get lendingAgingDueToday;

  /// No description provided for @lendingAgingDueSoon.
  ///
  /// In en, this message translates to:
  /// **'Due soon'**
  String get lendingAgingDueSoon;

  /// No description provided for @lendingAgingDaysOverdue.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day overdue} other{{count} days overdue}}'**
  String lendingAgingDaysOverdue(int count);

  /// No description provided for @lendingAgingDaysUntil.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{in 1 day} other{in {count} days}}'**
  String lendingAgingDaysUntil(int count);

  /// No description provided for @pfMoversTodayTitle.
  ///
  /// In en, this message translates to:
  /// **'Top movers today (by \$)'**
  String get pfMoversTodayTitle;

  /// No description provided for @pfBestWorstAllTime.
  ///
  /// In en, this message translates to:
  /// **'Best & worst (all time)'**
  String get pfBestWorstAllTime;

  /// No description provided for @pfTopGainersByValue.
  ///
  /// In en, this message translates to:
  /// **'Top gainers'**
  String get pfTopGainersByValue;

  /// No description provided for @pfTopLosersByValue.
  ///
  /// In en, this message translates to:
  /// **'Top losers'**
  String get pfTopLosersByValue;

  /// No description provided for @pfLotCurrentValue.
  ///
  /// In en, this message translates to:
  /// **'Current value'**
  String get pfLotCurrentValue;

  /// No description provided for @pfLotTerm.
  ///
  /// In en, this message translates to:
  /// **'Term'**
  String get pfLotTerm;

  /// No description provided for @pfLotLongTerm.
  ///
  /// In en, this message translates to:
  /// **'Long-term'**
  String get pfLotLongTerm;

  /// No description provided for @pfLotShortTerm.
  ///
  /// In en, this message translates to:
  /// **'Short-term'**
  String get pfLotShortTerm;

  /// No description provided for @pfFlatCostBasis.
  ///
  /// In en, this message translates to:
  /// **'Cost basis'**
  String get pfFlatCostBasis;

  /// No description provided for @pfLotsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No cost-basis detail available'**
  String get pfLotsUnavailable;

  /// No description provided for @pfLotsUnavailableTooltip.
  ///
  /// In en, this message translates to:
  /// **'This institution did not report acquisition dates, so a per-lot breakdown isn\'t available.'**
  String get pfLotsUnavailableTooltip;

  /// No description provided for @pfViewCostBasis.
  ///
  /// In en, this message translates to:
  /// **'View cost basis'**
  String get pfViewCostBasis;

  /// No description provided for @taxHarvestMarginalRate.
  ///
  /// In en, this message translates to:
  /// **'Marginal rate used for harvest estimates'**
  String get taxHarvestMarginalRate;

  /// No description provided for @taxHarvestMarginalOrdinary.
  ///
  /// In en, this message translates to:
  /// **'Ordinary (short-term)'**
  String get taxHarvestMarginalOrdinary;

  /// No description provided for @taxHarvestMarginalLtcg.
  ///
  /// In en, this message translates to:
  /// **'LTCG (long-term)'**
  String get taxHarvestMarginalLtcg;

  /// No description provided for @projShowNominal.
  ///
  /// In en, this message translates to:
  /// **'Show nominal amounts'**
  String get projShowNominal;

  /// No description provided for @projNominalNote.
  ///
  /// In en, this message translates to:
  /// **'Future (nominal) dollars'**
  String get projNominalNote;

  /// No description provided for @projFisherHelp.
  ///
  /// In en, this message translates to:
  /// **'{nominal}% nominal − {inflation}% inflation ≈ {real}% real (Fisher relation)'**
  String projFisherHelp(String nominal, String inflation, String real);

  /// No description provided for @lwSyncBadgeSuccess.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get lwSyncBadgeSuccess;

  /// No description provided for @lwSyncBadgeSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get lwSyncBadgeSyncing;

  /// No description provided for @lwSyncBadgeError.
  ///
  /// In en, this message translates to:
  /// **'Errors'**
  String get lwSyncBadgeError;

  /// No description provided for @lwSyncBadgeReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get lwSyncBadgeReconnect;

  /// No description provided for @lwSyncBadgeStale.
  ///
  /// In en, this message translates to:
  /// **'Stale'**
  String get lwSyncBadgeStale;

  /// No description provided for @lwSyncFilterProblems.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get lwSyncFilterProblems;

  /// No description provided for @lwSyncNoProblems.
  ///
  /// In en, this message translates to:
  /// **'Everything is up to date'**
  String get lwSyncNoProblems;

  /// Coverage caption shown beside the portfolio hero return %, clarifying that the % is a return on cost basis and only covers the subset of holdings that report a basis. {covered} is the compact display-currency value of basis-known holdings (e.g. $160.7K), {total} is the compact full portfolio value (e.g. $1.53M).
  ///
  /// In en, this message translates to:
  /// **'on {covered} of {total} with known cost basis'**
  String pfReturnCoverage(String covered, String total);

  /// No description provided for @taxFbarNoData.
  ///
  /// In en, this message translates to:
  /// **'No foreign-account balance history found for this year.'**
  String get taxFbarNoData;

  /// Subtle caption next to the nominal-mode Full-FIRE target figure, clarifying it is expressed in the retirement-year (years-to-retirement) dollars rather than the 'years away' (years-to-FI) horizon.
  ///
  /// In en, this message translates to:
  /// **'in {years}-yr dollars'**
  String projNominalHorizonCaption(int years);

  /// No description provided for @statInvestmentsCashSleeveNote.
  ///
  /// In en, this message translates to:
  /// **'Includes uninvested cash inside brokerage accounts, so this differs from the Portfolio total (sum of holdings).'**
  String get statInvestmentsCashSleeveNote;

  /// No description provided for @dashFxStaleLabel.
  ///
  /// In en, this message translates to:
  /// **'approx.'**
  String get dashFxStaleLabel;

  /// No description provided for @dashFxStaleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Approximate — the exchange rate is stale (missing or over 7 days old), so this conversion may be off.'**
  String get dashFxStaleTooltip;

  /// No description provided for @lwFxEnterManually.
  ///
  /// In en, this message translates to:
  /// **'Enter rate manually'**
  String get lwFxEnterManually;

  /// No description provided for @lwFxManualDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter exchange rate'**
  String get lwFxManualDialogTitle;

  /// No description provided for @lwFxManualDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Set a manual {base}/{target} rate. This overrides the automatic rate until the next refresh.'**
  String lwFxManualDialogHint(Object base, Object target);

  /// No description provided for @lwFxManualInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid rate greater than zero'**
  String get lwFxManualInvalid;

  /// No description provided for @lwFxManualSaved.
  ///
  /// In en, this message translates to:
  /// **'Manual exchange rate saved'**
  String get lwFxManualSaved;

  /// No description provided for @lwFxManualFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save rate: {error}'**
  String lwFxManualFailed(Object error);

  /// No description provided for @taxHeadroomTitle.
  ///
  /// In en, this message translates to:
  /// **'Headroom'**
  String get taxHeadroomTitle;

  /// No description provided for @taxHeadroomSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Room before the next US tax step'**
  String get taxHeadroomSubtitle;

  /// No description provided for @taxHeadroomOrdinaryRoom.
  ///
  /// In en, this message translates to:
  /// **'Room in current bracket: {amount} before {rate}%'**
  String taxHeadroomOrdinaryRoom(Object amount, Object rate);

  /// No description provided for @taxHeadroomOrdinaryRoomTop.
  ///
  /// In en, this message translates to:
  /// **'Room in current bracket: {amount}'**
  String taxHeadroomOrdinaryRoomTop(Object amount);

  /// No description provided for @taxHeadroomLtcg0Room.
  ///
  /// In en, this message translates to:
  /// **'LTCG 0% room: {amount} tax-free'**
  String taxHeadroomLtcg0Room(Object amount);

  /// No description provided for @taxHeadroomLtcg15Room.
  ///
  /// In en, this message translates to:
  /// **'LTCG 15% room: {amount} before {rate}%'**
  String taxHeadroomLtcg15Room(Object amount, Object rate);

  /// No description provided for @txFilteredNet.
  ///
  /// In en, this message translates to:
  /// **'Net'**
  String get txFilteredNet;

  /// No description provided for @txFilteredOutflow.
  ///
  /// In en, this message translates to:
  /// **'Out {amount}'**
  String txFilteredOutflow(Object amount);

  /// No description provided for @txFilteredInflow.
  ///
  /// In en, this message translates to:
  /// **'In {amount}'**
  String txFilteredInflow(Object amount);

  /// No description provided for @statDrilldownApprox.
  ///
  /// In en, this message translates to:
  /// **'≈ {amount}'**
  String statDrilldownApprox(Object amount);

  /// No description provided for @cfBudgetsPacingToExceed.
  ///
  /// In en, this message translates to:
  /// **'On track to exceed'**
  String get cfBudgetsPacingToExceed;

  /// No description provided for @cfBudgetsPacingAlert.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 category is on track to exceed its budget} other{{count} categories are on track to exceed their budgets}}'**
  String cfBudgetsPacingAlert(num count);

  /// No description provided for @pfGoalOnPaceFor.
  ///
  /// In en, this message translates to:
  /// **'on pace for ~{when} at +{rate}/mo'**
  String pfGoalOnPaceFor(Object rate, Object when);

  /// No description provided for @pfGoalNeedPerMonth.
  ///
  /// In en, this message translates to:
  /// **'need {amount}/mo to hit goal year'**
  String pfGoalNeedPerMonth(Object amount);

  /// No description provided for @lendingInterestIncomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Interest income'**
  String get lendingInterestIncomeTitle;

  /// No description provided for @lendingInterestIncomeLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load interest income. Try again.'**
  String get lendingInterestIncomeLoadError;

  /// No description provided for @lendingInterestIncomeRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get lendingInterestIncomeRetry;

  /// No description provided for @lendingInterestIncomeAllTime.
  ///
  /// In en, this message translates to:
  /// **'All time'**
  String get lendingInterestIncomeAllTime;

  /// No description provided for @lendingInterestIncomeEmpty.
  ///
  /// In en, this message translates to:
  /// **'No interest received in this period yet.'**
  String get lendingInterestIncomeEmpty;

  /// No description provided for @lendingInterestIncomeTotalsByCurrency.
  ///
  /// In en, this message translates to:
  /// **'Totals by currency'**
  String get lendingInterestIncomeTotalsByCurrency;

  /// No description provided for @lendingInterestIncomeInterestReceived.
  ///
  /// In en, this message translates to:
  /// **'Interest collected so far'**
  String get lendingInterestIncomeInterestReceived;

  /// No description provided for @lendingInterestIncomePrincipalReceived.
  ///
  /// In en, this message translates to:
  /// **'Principal received'**
  String get lendingInterestIncomePrincipalReceived;

  /// No description provided for @lendingInterestIncomePaymentsCount.
  ///
  /// In en, this message translates to:
  /// **'Payments'**
  String get lendingInterestIncomePaymentsCount;

  /// No description provided for @lendingInterestIncomeByMonth.
  ///
  /// In en, this message translates to:
  /// **'Interest by month'**
  String get lendingInterestIncomeByMonth;

  /// No description provided for @lendingInterestIncomeByLoan.
  ///
  /// In en, this message translates to:
  /// **'By loan'**
  String get lendingInterestIncomeByLoan;

  /// No description provided for @lendingInterestIncomeBorrower.
  ///
  /// In en, this message translates to:
  /// **'Borrower'**
  String get lendingInterestIncomeBorrower;

  /// No description provided for @lendingInterestIncomeBelowMarketTitle.
  ///
  /// In en, this message translates to:
  /// **'§7872 below-market loans'**
  String get lendingInterestIncomeBelowMarketTitle;

  /// No description provided for @lendingInterestIncomeBelowMarketBody.
  ///
  /// In en, this message translates to:
  /// **'These active 0%-rate loans exceed the \$10,000 gift-loan threshold, so the IRS may impute interest under §7872. Informational only — confirm with an accountant.'**
  String get lendingInterestIncomeBelowMarketBody;

  /// No description provided for @cfSavingsRate.
  ///
  /// In en, this message translates to:
  /// **'{rate} saved'**
  String cfSavingsRate(Object rate);

  /// No description provided for @cfPtsAbbrev.
  ///
  /// In en, this message translates to:
  /// **'pts'**
  String get cfPtsAbbrev;

  /// No description provided for @taxHarvestFooterTotal.
  ///
  /// In en, this message translates to:
  /// **'Total harvestable loss ({count} lots)'**
  String taxHarvestFooterTotal(Object count);

  /// No description provided for @taxHarvestFooterSavings.
  ///
  /// In en, this message translates to:
  /// **'Est. total savings {amount}'**
  String taxHarvestFooterSavings(Object amount);

  /// No description provided for @taxHarvestFooterFlow.
  ///
  /// In en, this message translates to:
  /// **'{gains} taxable gains remain, {ordinary} offset against income, {carryforward} carried forward'**
  String taxHarvestFooterFlow(
    Object carryforward,
    Object gains,
    Object ordinary,
  );

  /// No description provided for @taxHarvestFooterCarryforward.
  ///
  /// In en, this message translates to:
  /// **'{amount} loss carries forward to next year'**
  String taxHarvestFooterCarryforward(Object amount);

  /// No description provided for @lwPerfBenchSp500.
  ///
  /// In en, this message translates to:
  /// **'S&P 500'**
  String get lwPerfBenchSp500;

  /// No description provided for @lwPerfBenchNdx.
  ///
  /// In en, this message translates to:
  /// **'Nasdaq-100'**
  String get lwPerfBenchNdx;

  /// No description provided for @lwPerfBenchAcwi.
  ///
  /// In en, this message translates to:
  /// **'World (ACWI)'**
  String get lwPerfBenchAcwi;

  /// No description provided for @lwPerfBenchAgg.
  ///
  /// In en, this message translates to:
  /// **'US Bonds'**
  String get lwPerfBenchAgg;

  /// No description provided for @lwPerfBenchMxx.
  ///
  /// In en, this message translates to:
  /// **'IPC Mexico'**
  String get lwPerfBenchMxx;

  /// No description provided for @lwPerfBenchPickerTooltip.
  ///
  /// In en, this message translates to:
  /// **'Benchmark'**
  String get lwPerfBenchPickerTooltip;

  /// No description provided for @lendingDueOverdue.
  ///
  /// In en, this message translates to:
  /// **'Overdue'**
  String get lendingDueOverdue;

  /// No description provided for @lendingDueOn.
  ///
  /// In en, this message translates to:
  /// **'Due {date}'**
  String lendingDueOn(Object date);

  /// No description provided for @lendingDuePaidAhead.
  ///
  /// In en, this message translates to:
  /// **'Paid ahead'**
  String get lendingDuePaidAhead;

  /// No description provided for @lendingInterestOwedSoFar.
  ///
  /// In en, this message translates to:
  /// **'Interest owed so far'**
  String get lendingInterestOwedSoFar;

  /// No description provided for @dashLenderNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get dashLenderNameTitle;

  /// No description provided for @dashLenderNameSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Shown as the lender on loan agreements. Leave blank to use your username.'**
  String get dashLenderNameSubtitle;

  /// No description provided for @dashLenderNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Nick Van der Auwermeulen'**
  String get dashLenderNameHint;

  /// No description provided for @dashLenderNameSaved.
  ///
  /// In en, this message translates to:
  /// **'Name saved'**
  String get dashLenderNameSaved;

  /// No description provided for @dashLenderNameSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save your name'**
  String get dashLenderNameSaveFailed;

  /// No description provided for @dashSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get dashSave;

  /// No description provided for @dashDataExportTitle.
  ///
  /// In en, this message translates to:
  /// **'Data export'**
  String get dashDataExportTitle;

  /// No description provided for @dashDataExportSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download your transactions and tax reports. Files download directly in your browser.'**
  String get dashDataExportSubtitle;

  /// No description provided for @dashExportTransactionsCsv.
  ///
  /// In en, this message translates to:
  /// **'All transactions (CSV)'**
  String get dashExportTransactionsCsv;

  /// No description provided for @dashExportTaxCsv.
  ///
  /// In en, this message translates to:
  /// **'Tax report (CSV)'**
  String get dashExportTaxCsv;

  /// No description provided for @dashExportTaxPdf.
  ///
  /// In en, this message translates to:
  /// **'Tax report (PDF)'**
  String get dashExportTaxPdf;

  /// No description provided for @dashImportedBatchesTitle.
  ///
  /// In en, this message translates to:
  /// **'Imported batches'**
  String get dashImportedBatchesTitle;

  /// No description provided for @dashImportedBatchesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Review or undo past statement imports'**
  String get dashImportedBatchesSubtitle;

  /// No description provided for @dossierTitle.
  ///
  /// In en, this message translates to:
  /// **'Continuity dossier'**
  String get dossierTitle;

  /// No description provided for @dossierEntrySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Printable emergency packet: every account, balance, and loan — plus your instructions'**
  String get dossierEntrySubtitle;

  /// No description provided for @dossierIntro.
  ///
  /// In en, this message translates to:
  /// **'A bilingual, printable inventory of everything Patrimonio tracks — institutions, accounts and last balances, manual-asset valuations, holdings, the lending book, and FBAR flags — for the household member or executor who has to take over. It contains no passwords or tokens, only names and balances.'**
  String get dossierIntro;

  /// No description provided for @dossierInstructionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Your instructions'**
  String get dossierInstructionsTitle;

  /// No description provided for @dossierInstructionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Free text printed on the dossier\'s first page: where credentials live, who to call, what to do first.'**
  String get dossierInstructionsSubtitle;

  /// No description provided for @dossierInstructionsHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Passwords are in the family password manager; call the notary first…'**
  String get dossierInstructionsHint;

  /// No description provided for @dossierInstructionsSaved.
  ///
  /// In en, this message translates to:
  /// **'Instructions saved'**
  String get dossierInstructionsSaved;

  /// No description provided for @dossierInstructionsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the instructions'**
  String get dossierInstructionsSaveFailed;

  /// No description provided for @dossierLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Document language'**
  String get dossierLanguageLabel;

  /// No description provided for @dossierLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get dossierLanguageEnglish;

  /// No description provided for @dossierLanguageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get dossierLanguageSpanish;

  /// No description provided for @dossierGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate printable dossier'**
  String get dossierGenerate;

  /// No description provided for @dossierGenerateNote.
  ///
  /// In en, this message translates to:
  /// **'Opens as a printable page — print or save as PDF and keep a copy where your family can find it.'**
  String get dossierGenerateNote;

  /// No description provided for @divCardTitle.
  ///
  /// In en, this message translates to:
  /// **'Dividend income'**
  String get divCardTitle;

  /// No description provided for @divProjectedAnnual.
  ///
  /// In en, this message translates to:
  /// **'Projected annual'**
  String get divProjectedAnnual;

  /// No description provided for @divBlendedYield.
  ///
  /// In en, this message translates to:
  /// **'Blended yield'**
  String get divBlendedYield;

  /// No description provided for @divTopPayers.
  ///
  /// In en, this message translates to:
  /// **'Top payers'**
  String get divTopPayers;

  /// No description provided for @divUpcomingExDates.
  ///
  /// In en, this message translates to:
  /// **'Upcoming ex-dates'**
  String get divUpcomingExDates;

  /// No description provided for @divPaymentsPerYear.
  ///
  /// In en, this message translates to:
  /// **'{count}×/yr'**
  String divPaymentsPerYear(Object count);

  /// No description provided for @divFxStaleHint.
  ///
  /// In en, this message translates to:
  /// **'Some income converted with a stale FX rate — figures are approximate.'**
  String get divFxStaleHint;

  /// No description provided for @lendCustomStyleLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom schedule'**
  String get lendCustomStyleLabel;

  /// No description provided for @lendCustomStyleDesc.
  ///
  /// In en, this message translates to:
  /// **'You set every payment by hand — irregular amounts and dates that add up to the amount lent.'**
  String get lendCustomStyleDesc;

  /// No description provided for @lendCustomPasteTitle.
  ///
  /// In en, this message translates to:
  /// **'Paste from a spreadsheet'**
  String get lendCustomPasteTitle;

  /// No description provided for @lendCustomPasteHint.
  ///
  /// In en, this message translates to:
  /// **'Paste two columns from Google Sheets / Excel: date then amount, one payment per line.'**
  String get lendCustomPasteHint;

  /// No description provided for @lendCustomPasteButton.
  ///
  /// In en, this message translates to:
  /// **'Parse pasted rows'**
  String get lendCustomPasteButton;

  /// No description provided for @lendCustomPastedN.
  ///
  /// In en, this message translates to:
  /// **'Loaded {count} payment{count, plural, =1{} other{s}} from the paste.'**
  String lendCustomPastedN(int count);

  /// No description provided for @lendCustomPasteEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing to parse — paste some date + amount rows first.'**
  String get lendCustomPasteEmpty;

  /// No description provided for @lendCustomRowsTitle.
  ///
  /// In en, this message translates to:
  /// **'Payments'**
  String get lendCustomRowsTitle;

  /// No description provided for @lendCustomAddRow.
  ///
  /// In en, this message translates to:
  /// **'Add payment'**
  String get lendCustomAddRow;

  /// No description provided for @lendCustomRemoveRow.
  ///
  /// In en, this message translates to:
  /// **'Remove payment'**
  String get lendCustomRemoveRow;

  /// No description provided for @lendCustomRowDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get lendCustomRowDate;

  /// No description provided for @lendCustomRowAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get lendCustomRowAmount;

  /// No description provided for @lendCustomNoRows.
  ///
  /// In en, this message translates to:
  /// **'No payments yet — paste from a spreadsheet or add them below.'**
  String get lendCustomNoRows;

  /// No description provided for @lendCustomGeneratorTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick fill'**
  String get lendCustomGeneratorTitle;

  /// No description provided for @lendCustomGenFirstN.
  ///
  /// In en, this message translates to:
  /// **'First payments'**
  String get lendCustomGenFirstN;

  /// No description provided for @lendCustomGenFirstAmount.
  ///
  /// In en, this message translates to:
  /// **'First amount'**
  String get lendCustomGenFirstAmount;

  /// No description provided for @lendCustomGenThenAmount.
  ///
  /// In en, this message translates to:
  /// **'Then each'**
  String get lendCustomGenThenAmount;

  /// No description provided for @lendCustomGenDayOfMonth.
  ///
  /// In en, this message translates to:
  /// **'Day of month'**
  String get lendCustomGenDayOfMonth;

  /// No description provided for @lendCustomGenStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get lendCustomGenStart;

  /// No description provided for @lendCustomGenEnd.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get lendCustomGenEnd;

  /// No description provided for @lendCustomGenApply.
  ///
  /// In en, this message translates to:
  /// **'Fill payments'**
  String get lendCustomGenApply;

  /// No description provided for @lendCustomPreviewCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 payment} other{{count} payments}}'**
  String lendCustomPreviewCount(int count);

  /// No description provided for @lendCustomPreviewSum.
  ///
  /// In en, this message translates to:
  /// **'Sum of payments'**
  String get lendCustomPreviewSum;

  /// No description provided for @lendCustomClosesToZero.
  ///
  /// In en, this message translates to:
  /// **'Closes to 0 — the payments add up to the amount lent.'**
  String get lendCustomClosesToZero;

  /// No description provided for @lendCustomDoesNotAddUp.
  ///
  /// In en, this message translates to:
  /// **'Payments total {sum}, but the amount lent is {principal}.'**
  String lendCustomDoesNotAddUp(String sum, String principal);

  /// No description provided for @lendCustomNeedRows.
  ///
  /// In en, this message translates to:
  /// **'Add at least one payment before saving.'**
  String get lendCustomNeedRows;

  /// No description provided for @lendCustomScheduleFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the schedule: {error}'**
  String lendCustomScheduleFailed(String error);

  /// No description provided for @lendDisbursementConflict.
  ///
  /// In en, this message translates to:
  /// **'That transaction already funds another loan — the loan wasn\'t created.'**
  String get lendDisbursementConflict;

  /// No description provided for @lendCopyForSheets.
  ///
  /// In en, this message translates to:
  /// **'Copy for Google Sheets'**
  String get lendCopyForSheets;

  /// No description provided for @lendCopiedForSheets.
  ///
  /// In en, this message translates to:
  /// **'Copied — paste into the sheet with Ctrl/Cmd+V.'**
  String get lendCopiedForSheets;

  /// No description provided for @lendSchedulePaidProgress.
  ///
  /// In en, this message translates to:
  /// **'Paid {paid} of {total} payments'**
  String lendSchedulePaidProgress(int paid, int total);

  /// No description provided for @lendScheduleRemaining.
  ///
  /// In en, this message translates to:
  /// **'{amount} remaining'**
  String lendScheduleRemaining(String amount);

  /// No description provided for @lendScheduleColDue.
  ///
  /// In en, this message translates to:
  /// **'Due'**
  String get lendScheduleColDue;

  /// No description provided for @lendScheduleColInterest.
  ///
  /// In en, this message translates to:
  /// **'Interest'**
  String get lendScheduleColInterest;

  /// No description provided for @lendScheduleColPayment.
  ///
  /// In en, this message translates to:
  /// **'Payment'**
  String get lendScheduleColPayment;

  /// No description provided for @lendScheduleColBalance.
  ///
  /// In en, this message translates to:
  /// **'Principal balance'**
  String get lendScheduleColBalance;

  /// Footnote under the amortization table (wide layouts) explaining the Principal balance column excludes interest.
  ///
  /// In en, this message translates to:
  /// **'Principal balance is what\'s left of the amount lent — interest isn\'t included.'**
  String get lendSchedulePrincipalBalanceNote;

  /// No description provided for @lendScheduleRowMeta.
  ///
  /// In en, this message translates to:
  /// **'Bal {balance} · int {interest}'**
  String lendScheduleRowMeta(String balance, String interest);

  /// No description provided for @lendScheduleColStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get lendScheduleColStatus;

  /// No description provided for @lendScheduleNextDue.
  ///
  /// In en, this message translates to:
  /// **'Next due'**
  String get lendScheduleNextDue;

  /// No description provided for @lendScheduleTotals.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get lendScheduleTotals;

  /// No description provided for @txCreateLoanFromTx.
  ///
  /// In en, this message translates to:
  /// **'Create loan from this transaction'**
  String get txCreateLoanFromTx;

  /// Shown in a loan's detail line when no funding transaction is attached. Clarifies a disbursement is optional (a loan can just represent money owed) so the loan doesn't look misconfigured.
  ///
  /// In en, this message translates to:
  /// **'no disbursement linked (optional)'**
  String get lendDisbursementNotLinkedOptional;

  /// No description provided for @lendLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load loans. Pull to retry.'**
  String get lendLoadError;

  /// No description provided for @lendRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get lendRetry;

  /// No description provided for @lendExportInterestTooltip.
  ///
  /// In en, this message translates to:
  /// **'Export interest income'**
  String get lendExportInterestTooltip;

  /// No description provided for @lendExportPaymentsCsv.
  ///
  /// In en, this message translates to:
  /// **'Interest payments (CSV)'**
  String get lendExportPaymentsCsv;

  /// No description provided for @lendExportYearEndCsv.
  ///
  /// In en, this message translates to:
  /// **'Year-end summary by borrower (CSV)'**
  String get lendExportYearEndCsv;

  /// No description provided for @lendTotalsConvertedNote.
  ///
  /// In en, this message translates to:
  /// **'Totals converted to {currency} at the current spot rate'**
  String lendTotalsConvertedNote(String currency);

  /// No description provided for @lendUnknownBorrower.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get lendUnknownBorrower;

  /// No description provided for @lendStatusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get lendStatusActive;

  /// No description provided for @lendStatusPaidOff.
  ///
  /// In en, this message translates to:
  /// **'Paid off'**
  String get lendStatusPaidOff;

  /// No description provided for @lendStatusWrittenOff.
  ///
  /// In en, this message translates to:
  /// **'Written off'**
  String get lendStatusWrittenOff;

  /// No description provided for @lendStatusDefaulted.
  ///
  /// In en, this message translates to:
  /// **'Defaulted'**
  String get lendStatusDefaulted;

  /// No description provided for @lendStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get lendStatusCancelled;

  /// No description provided for @lendLentMeta.
  ///
  /// In en, this message translates to:
  /// **'Lent {amount} · {date}'**
  String lendLentMeta(String amount, String date);

  /// No description provided for @lendLentOutstandingMeta.
  ///
  /// In en, this message translates to:
  /// **'Lent {principal} · outstanding {outstanding}'**
  String lendLentOutstandingMeta(String principal, String outstanding);

  /// No description provided for @lendRatePeriodYear.
  ///
  /// In en, this message translates to:
  /// **'Year'**
  String get lendRatePeriodYear;

  /// No description provided for @lendRatePeriodMonth.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get lendRatePeriodMonth;

  /// No description provided for @lendRateHintExample.
  ///
  /// In en, this message translates to:
  /// **'e.g. 5'**
  String get lendRateHintExample;

  /// No description provided for @lendRatePerMonthSuffix.
  ///
  /// In en, this message translates to:
  /// **'% / month'**
  String get lendRatePerMonthSuffix;

  /// No description provided for @lendRatePerYearSuffix.
  ///
  /// In en, this message translates to:
  /// **'% / year'**
  String get lendRatePerYearSuffix;

  /// No description provided for @lendFreqLumpSum.
  ///
  /// In en, this message translates to:
  /// **'Lump sum'**
  String get lendFreqLumpSum;

  /// No description provided for @lendInterestTypeNone.
  ///
  /// In en, this message translates to:
  /// **'No interest'**
  String get lendInterestTypeNone;

  /// No description provided for @lendInterestTypeSimple.
  ///
  /// In en, this message translates to:
  /// **'Simple interest'**
  String get lendInterestTypeSimple;

  /// No description provided for @lendInterestTypeAmortized.
  ///
  /// In en, this message translates to:
  /// **'Amortized'**
  String get lendInterestTypeAmortized;

  /// No description provided for @lendInterestTypeInterestOnly.
  ///
  /// In en, this message translates to:
  /// **'Interest-only'**
  String get lendInterestTypeInterestOnly;

  /// No description provided for @lendInterestTypeCompound.
  ///
  /// In en, this message translates to:
  /// **'Compound'**
  String get lendInterestTypeCompound;

  /// No description provided for @lendAddLoanSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Record money you lent and track repayment'**
  String get lendAddLoanSubtitle;

  /// No description provided for @lendEditLoanTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit loan'**
  String get lendEditLoanTitle;

  /// No description provided for @lendEditLoanSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Correct the borrower, amount, or interest terms'**
  String get lendEditLoanSubtitle;

  /// No description provided for @lendFieldBorrowerName.
  ///
  /// In en, this message translates to:
  /// **'Borrower name'**
  String get lendFieldBorrowerName;

  /// No description provided for @lendFieldAmountLent.
  ///
  /// In en, this message translates to:
  /// **'Amount lent'**
  String get lendFieldAmountLent;

  /// No description provided for @lendFieldCurrency.
  ///
  /// In en, this message translates to:
  /// **'Currency'**
  String get lendFieldCurrency;

  /// No description provided for @lendFieldLentOn.
  ///
  /// In en, this message translates to:
  /// **'Lent on'**
  String get lendFieldLentOn;

  /// No description provided for @lendFieldInterestRate.
  ///
  /// In en, this message translates to:
  /// **'Interest rate'**
  String get lendFieldInterestRate;

  /// No description provided for @lendFieldNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get lendFieldNotes;

  /// No description provided for @lendFieldNotesHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. for the car deposit'**
  String get lendFieldNotesHint;

  /// Empty-state hint inside the clearable 'Pay back by' date field. The field is optional; optionality is conveyed by the hint styling, not the word 'optional'.
  ///
  /// In en, this message translates to:
  /// **'When do they pay it back?'**
  String get lendFieldPayBackByHint;

  /// No description provided for @lendFieldTermMonths.
  ///
  /// In en, this message translates to:
  /// **'Term (months)'**
  String get lendFieldTermMonths;

  /// No description provided for @lendFieldMostTheyCanPay.
  ///
  /// In en, this message translates to:
  /// **'Most they can pay'**
  String get lendFieldMostTheyCanPay;

  /// No description provided for @lendFieldRateIsPer.
  ///
  /// In en, this message translates to:
  /// **'Rate is per'**
  String get lendFieldRateIsPer;

  /// No description provided for @lendFieldPaymentFrequency.
  ///
  /// In en, this message translates to:
  /// **'Payment frequency'**
  String get lendFieldPaymentFrequency;

  /// No description provided for @lendFieldPayBackBy.
  ///
  /// In en, this message translates to:
  /// **'Pay back by'**
  String get lendFieldPayBackBy;

  /// No description provided for @lendFieldInterestType.
  ///
  /// In en, this message translates to:
  /// **'Interest type'**
  String get lendFieldInterestType;

  /// No description provided for @lendFieldAmountReceived.
  ///
  /// In en, this message translates to:
  /// **'Amount received'**
  String get lendFieldAmountReceived;

  /// No description provided for @lendFieldReceivedOn.
  ///
  /// In en, this message translates to:
  /// **'Received on'**
  String get lendFieldReceivedOn;

  /// No description provided for @lendSegSetTheTerm.
  ///
  /// In en, this message translates to:
  /// **'Set the term'**
  String get lendSegSetTheTerm;

  /// No description provided for @lendSegSetThePayment.
  ///
  /// In en, this message translates to:
  /// **'Set the payment'**
  String get lendSegSetThePayment;

  /// No description provided for @lendSegBankTransaction.
  ///
  /// In en, this message translates to:
  /// **'Bank transaction'**
  String get lendSegBankTransaction;

  /// No description provided for @lendSegCash.
  ///
  /// In en, this message translates to:
  /// **'Record manually'**
  String get lendSegCash;

  /// No description provided for @lendAdvancedOptions.
  ///
  /// In en, this message translates to:
  /// **'Advanced options'**
  String get lendAdvancedOptions;

  /// No description provided for @lendPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Loan preview'**
  String get lendPreviewTitle;

  /// No description provided for @lendPreviewEstimate.
  ///
  /// In en, this message translates to:
  /// **'estimate'**
  String get lendPreviewEstimate;

  /// No description provided for @lendPreviewEnterAmount.
  ///
  /// In en, this message translates to:
  /// **'Enter an amount to see the projection'**
  String get lendPreviewEnterAmount;

  /// No description provided for @lendPreviewTotalToRepay.
  ///
  /// In en, this message translates to:
  /// **'Total to repay'**
  String get lendPreviewTotalToRepay;

  /// No description provided for @lendPreviewProjectedInterest.
  ///
  /// In en, this message translates to:
  /// **'Projected interest'**
  String get lendPreviewProjectedInterest;

  /// No description provided for @lendPreviewNoInterest.
  ///
  /// In en, this message translates to:
  /// **'No interest on this loan'**
  String get lendPreviewNoInterest;

  /// No description provided for @lendPreviewOpenEnded.
  ///
  /// In en, this message translates to:
  /// **'Open-ended — repay anytime, no fixed schedule'**
  String get lendPreviewOpenEnded;

  /// No description provided for @lendPreviewMinimumPayment.
  ///
  /// In en, this message translates to:
  /// **'Minimum payment'**
  String get lendPreviewMinimumPayment;

  /// No description provided for @lendPreviewPaidOffIn.
  ///
  /// In en, this message translates to:
  /// **'Paid off in'**
  String get lendPreviewPaidOffIn;

  /// No description provided for @lendPreviewPaidOffValue.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 payment} other{{count} payments}}  ·  {term}'**
  String lendPreviewPaidOffValue(int count, String term);

  /// No description provided for @lendTermMonths.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 month} other{{count} months}}'**
  String lendTermMonths(int count);

  /// No description provided for @lendTermYearsAbbrev.
  ///
  /// In en, this message translates to:
  /// **'~{years} yr'**
  String lendTermYearsAbbrev(String years);

  /// No description provided for @lendSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get lendSaveChanges;

  /// No description provided for @lendDisbursementLinked.
  ///
  /// In en, this message translates to:
  /// **'Linked to a bank transaction'**
  String get lendDisbursementLinked;

  /// No description provided for @lendWhichTxFunded.
  ///
  /// In en, this message translates to:
  /// **'Which transaction funded this loan?'**
  String get lendWhichTxFunded;

  /// No description provided for @lendLinkATransaction.
  ///
  /// In en, this message translates to:
  /// **'Link a transaction'**
  String get lendLinkATransaction;

  /// No description provided for @lendNoneRecordedYet.
  ///
  /// In en, this message translates to:
  /// **'None recorded yet.'**
  String get lendNoneRecordedYet;

  /// No description provided for @lendSuggestedRepayments.
  ///
  /// In en, this message translates to:
  /// **'Suggested repayments'**
  String get lendSuggestedRepayments;

  /// No description provided for @lendRecordAPayment.
  ///
  /// In en, this message translates to:
  /// **'Record a payment'**
  String get lendRecordAPayment;

  /// No description provided for @lendConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get lendConfirm;

  /// No description provided for @lendLinkedPaymentUntitled.
  ///
  /// In en, this message translates to:
  /// **'Linked payment'**
  String get lendLinkedPaymentUntitled;

  /// No description provided for @lendOffBankBadge.
  ///
  /// In en, this message translates to:
  /// **'Recorded manually'**
  String get lendOffBankBadge;

  /// No description provided for @lendMatchStrong.
  ///
  /// In en, this message translates to:
  /// **'Strong match'**
  String get lendMatchStrong;

  /// No description provided for @lendMatchLikely.
  ///
  /// In en, this message translates to:
  /// **'Likely match'**
  String get lendMatchLikely;

  /// No description provided for @lendMatchPossible.
  ///
  /// In en, this message translates to:
  /// **'Possible match'**
  String get lendMatchPossible;

  /// No description provided for @lendMatchNameHit.
  ///
  /// In en, this message translates to:
  /// **'Name matches'**
  String get lendMatchNameHit;

  /// No description provided for @lendExportPrintablePlan.
  ///
  /// In en, this message translates to:
  /// **'Printable plan (PDF)'**
  String get lendExportPrintablePlan;

  /// No description provided for @lendExportDownloadCsv.
  ///
  /// In en, this message translates to:
  /// **'Download CSV (Google Sheets / Excel)'**
  String get lendExportDownloadCsv;

  /// No description provided for @lendActionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get lendActionEdit;

  /// No description provided for @lendActionAgreement.
  ///
  /// In en, this message translates to:
  /// **'Agreement'**
  String get lendActionAgreement;

  /// No description provided for @lendActionMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get lendActionMore;

  /// No description provided for @lendAgreementEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get lendAgreementEnglish;

  /// No description provided for @lendAgreementSpanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get lendAgreementSpanish;

  /// No description provided for @lendActionPayOffInFull.
  ///
  /// In en, this message translates to:
  /// **'Pay off in full'**
  String get lendActionPayOffInFull;

  /// No description provided for @lendActionMarkDefaulted.
  ///
  /// In en, this message translates to:
  /// **'Mark defaulted'**
  String get lendActionMarkDefaulted;

  /// No description provided for @lendActionWriteOff.
  ///
  /// In en, this message translates to:
  /// **'Write off'**
  String get lendActionWriteOff;

  /// No description provided for @lendActionReactivate.
  ///
  /// In en, this message translates to:
  /// **'Reactivate'**
  String get lendActionReactivate;

  /// No description provided for @lendPayoffConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Pay off in full?'**
  String get lendPayoffConfirmTitle;

  /// No description provided for @lendPayoffConfirmButton.
  ///
  /// In en, this message translates to:
  /// **'Pay off'**
  String get lendPayoffConfirmButton;

  /// No description provided for @lendDeleteLoan.
  ///
  /// In en, this message translates to:
  /// **'Delete loan'**
  String get lendDeleteLoan;

  /// No description provided for @lendDeleteLoanTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete loan?'**
  String get lendDeleteLoanTitle;

  /// No description provided for @lendTooltipClearDate.
  ///
  /// In en, this message translates to:
  /// **'Clear date'**
  String get lendTooltipClearDate;

  /// No description provided for @lendTooltipUnlink.
  ///
  /// In en, this message translates to:
  /// **'Unlink'**
  String get lendTooltipUnlink;

  /// No description provided for @lendTooltipExportPaymentPlan.
  ///
  /// In en, this message translates to:
  /// **'Export payment plan'**
  String get lendTooltipExportPaymentPlan;

  /// No description provided for @lendToastEnterBorrowerName.
  ///
  /// In en, this message translates to:
  /// **'Enter a borrower name'**
  String get lendToastEnterBorrowerName;

  /// No description provided for @lendToastEnterValidAmount.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid amount'**
  String get lendToastEnterValidAmount;

  /// Fallback toast on a failed loan-form submit, naming the first invalid field (its visible label) in case it is off-screen.
  ///
  /// In en, this message translates to:
  /// **'Fix “{field}” to continue'**
  String lendToastCheckField(String field);

  /// No description provided for @lendErrEnterPayment.
  ///
  /// In en, this message translates to:
  /// **'Enter a payment amount greater than 0'**
  String get lendErrEnterPayment;

  /// No description provided for @lendErrPaymentTooSmall.
  ///
  /// In en, this message translates to:
  /// **'Too small — this payment would never pay off the loan'**
  String get lendErrPaymentTooSmall;

  /// No description provided for @lendToastFailedToAddLoan.
  ///
  /// In en, this message translates to:
  /// **'Failed to add loan'**
  String get lendToastFailedToAddLoan;

  /// No description provided for @lendToastCouldntSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save changes'**
  String get lendToastCouldntSaveChanges;

  /// No description provided for @lendToastScheduleGenerated.
  ///
  /// In en, this message translates to:
  /// **'Schedule generated'**
  String get lendToastScheduleGenerated;

  /// No description provided for @lendToastLoanUpdated.
  ///
  /// In en, this message translates to:
  /// **'Loan updated'**
  String get lendToastLoanUpdated;

  /// No description provided for @lendToastCouldntUpdateStatus.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update status'**
  String get lendToastCouldntUpdateStatus;

  /// No description provided for @lendToastLoanPaidOff.
  ///
  /// In en, this message translates to:
  /// **'Loan paid off'**
  String get lendToastLoanPaidOff;

  /// No description provided for @lendToastCouldntLinkTx.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t link that transaction'**
  String get lendToastCouldntLinkTx;

  /// No description provided for @lendToastCouldntRecordRepayment.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t record that repayment'**
  String get lendToastCouldntRecordRepayment;

  /// No description provided for @lendToastCouldntUnlink.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t unlink'**
  String get lendToastCouldntUnlink;

  /// No description provided for @lendToastCouldntDeleteLoan.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete loan'**
  String get lendToastCouldntDeleteLoan;

  /// No description provided for @lendToastRecordCashPayment.
  ///
  /// In en, this message translates to:
  /// **'Record cash payment'**
  String get lendToastRecordCashPayment;

  /// No description provided for @lendToastCouldntRecordCashPayment.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t record cash payment'**
  String get lendToastCouldntRecordCashPayment;

  /// No description provided for @lendSectionBorrowerAmount.
  ///
  /// In en, this message translates to:
  /// **'Borrower & amount'**
  String get lendSectionBorrowerAmount;

  /// No description provided for @lendSectionHowLoanWorks.
  ///
  /// In en, this message translates to:
  /// **'How the loan works'**
  String get lendSectionHowLoanWorks;

  /// No description provided for @lendSectionExpectedRepayment.
  ///
  /// In en, this message translates to:
  /// **'Expected repayment'**
  String get lendSectionExpectedRepayment;

  /// No description provided for @lendSectionNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get lendSectionNotes;

  /// No description provided for @lendSectionInterestTerms.
  ///
  /// In en, this message translates to:
  /// **'Interest terms'**
  String get lendSectionInterestTerms;

  /// No description provided for @lendSectionDisbursement.
  ///
  /// In en, this message translates to:
  /// **'Disbursement'**
  String get lendSectionDisbursement;

  /// No description provided for @lendSectionRepayments.
  ///
  /// In en, this message translates to:
  /// **'Repayments'**
  String get lendSectionRepayments;

  /// No description provided for @lendSectionPaymentSchedule.
  ///
  /// In en, this message translates to:
  /// **'Payment schedule'**
  String get lendSectionPaymentSchedule;

  /// No description provided for @lendStyleNoInterestDesc.
  ///
  /// In en, this message translates to:
  /// **'They pay back exactly what they borrowed.'**
  String get lendStyleNoInterestDesc;

  /// No description provided for @lendStyleStandardLabel.
  ///
  /// In en, this message translates to:
  /// **'Regular payments with a rate'**
  String get lendStyleStandardLabel;

  /// No description provided for @lendStyleStandardDesc.
  ///
  /// In en, this message translates to:
  /// **'Equal payments over time at an interest rate — like a bank loan.'**
  String get lendStyleStandardDesc;

  /// No description provided for @lendStyleFlatLabel.
  ///
  /// In en, this message translates to:
  /// **'Flat interest'**
  String get lendStyleFlatLabel;

  /// No description provided for @lendStyleFlatDesc.
  ///
  /// In en, this message translates to:
  /// **'A set amount of interest, split evenly across the payments. Enter it as a total amount or a rate.'**
  String get lendStyleFlatDesc;

  /// No description provided for @lendFlatModeAmount.
  ///
  /// In en, this message translates to:
  /// **'Set amount'**
  String get lendFlatModeAmount;

  /// No description provided for @lendFlatModeRate.
  ///
  /// In en, this message translates to:
  /// **'Rate'**
  String get lendFlatModeRate;

  /// No description provided for @lendMoreLoanTypes.
  ///
  /// In en, this message translates to:
  /// **'More loan types'**
  String get lendMoreLoanTypes;

  /// No description provided for @lendFieldAgreedInterest.
  ///
  /// In en, this message translates to:
  /// **'Agreed interest (total)'**
  String get lendFieldAgreedInterest;

  /// No description provided for @lendFieldPaymentAmount.
  ///
  /// In en, this message translates to:
  /// **'Payment amount'**
  String get lendFieldPaymentAmount;

  /// No description provided for @lendStyleInterestOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'Interest now, full amount at the end'**
  String get lendStyleInterestOnlyLabel;

  /// No description provided for @lendStyleInterestOnlyDesc.
  ///
  /// In en, this message translates to:
  /// **'They pay just interest each period, then the whole amount at the end.'**
  String get lendStyleInterestOnlyDesc;

  /// No description provided for @lendStylePayAtEndLabel.
  ///
  /// In en, this message translates to:
  /// **'One payment at the end'**
  String get lendStylePayAtEndLabel;

  /// No description provided for @lendStylePayAtEndDesc.
  ///
  /// In en, this message translates to:
  /// **'Nothing\'s due until the end; interest builds up until then.'**
  String get lendStylePayAtEndDesc;

  /// No description provided for @lendPreviewSinglePayment.
  ///
  /// In en, this message translates to:
  /// **'Single payment'**
  String get lendPreviewSinglePayment;

  /// No description provided for @lendPreviewPayment.
  ///
  /// In en, this message translates to:
  /// **'Payment'**
  String get lendPreviewPayment;

  /// No description provided for @lendPreviewPerPaymentInterest.
  ///
  /// In en, this message translates to:
  /// **'{amount}{cadence} interest  ·  {count, plural, =1{1 payment} other{{count} payments}}'**
  String lendPreviewPerPaymentInterest(
    String amount,
    String cadence,
    int count,
  );

  /// No description provided for @lendPreviewPerPaymentCount.
  ///
  /// In en, this message translates to:
  /// **'{amount}{cadence}  ·  {count, plural, =1{1 payment} other{{count} payments}}'**
  String lendPreviewPerPaymentCount(String amount, String cadence, int count);

  /// No description provided for @lendPreviewPrincipalAtMaturity.
  ///
  /// In en, this message translates to:
  /// **'Principal at maturity'**
  String get lendPreviewPrincipalAtMaturity;

  /// No description provided for @lendPreviewDueWithFinalPayment.
  ///
  /// In en, this message translates to:
  /// **'{amount}  ·  due with final payment'**
  String lendPreviewDueWithFinalPayment(String amount);

  /// No description provided for @lendPreviewEnterPaymentSolve.
  ///
  /// In en, this message translates to:
  /// **'Enter a payment to see how long it takes'**
  String get lendPreviewEnterPaymentSolve;

  /// No description provided for @lendToastEnterPaymentCompute.
  ///
  /// In en, this message translates to:
  /// **'Enter a payment to compute the term'**
  String get lendToastEnterPaymentCompute;

  /// No description provided for @lendEditRatePerPeriod.
  ///
  /// In en, this message translates to:
  /// **'{period, select, monthly{Rate % per month} other{Rate % per year}}'**
  String lendEditRatePerPeriod(String period);

  /// No description provided for @lendTermsSummaryTermMonths.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1-month term} other{{count}-month term}}'**
  String lendTermsSummaryTermMonths(int count);

  /// No description provided for @lendTermsSummaryMonthlyPayments.
  ///
  /// In en, this message translates to:
  /// **'monthly payments'**
  String get lendTermsSummaryMonthlyPayments;

  /// No description provided for @lendTermsSummaryWeeklyPayments.
  ///
  /// In en, this message translates to:
  /// **'weekly payments'**
  String get lendTermsSummaryWeeklyPayments;

  /// No description provided for @lendTermsSummaryLumpSumPayment.
  ///
  /// In en, this message translates to:
  /// **'single lump-sum payment'**
  String get lendTermsSummaryLumpSumPayment;

  /// No description provided for @lendTermsSummaryFixed.
  ///
  /// In en, this message translates to:
  /// **'Term & schedule ({parts}) are fixed — delete and re-add to change them.'**
  String lendTermsSummaryFixed(String parts);

  /// No description provided for @lendNoMatchingOutflow.
  ///
  /// In en, this message translates to:
  /// **'No matching outflow found near the loan date — pick one manually below.'**
  String get lendNoMatchingOutflow;

  /// No description provided for @lendScheduleGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get lendScheduleGenerate;

  /// No description provided for @lendScheduleRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get lendScheduleRegenerate;

  /// No description provided for @lendScheduleEmptyHasTerms.
  ///
  /// In en, this message translates to:
  /// **'No schedule yet. Generate one to see the amortization plan (principal + interest per installment).'**
  String get lendScheduleEmptyHasTerms;

  /// No description provided for @lendScheduleEmptyNoTerms.
  ///
  /// In en, this message translates to:
  /// **'This loan has no term / payment frequency, so there\'s no fixed schedule — record repayments as they come in.'**
  String get lendScheduleEmptyNoTerms;

  /// No description provided for @lendPayBackByWhen.
  ///
  /// In en, this message translates to:
  /// **'Pay back by {date} · {when}'**
  String lendPayBackByWhen(String date, String when);

  /// No description provided for @lendToastUnreconcileFirst.
  ///
  /// In en, this message translates to:
  /// **'Unreconcile payments first to regenerate'**
  String get lendToastUnreconcileFirst;

  /// No description provided for @lendToastCouldntGenerateSchedule.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t generate schedule'**
  String get lendToastCouldntGenerateSchedule;

  /// No description provided for @lendPayoffConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Marks the loan as paid off and clears any remaining scheduled installments. This does not create a repayment — link the actual final transaction from the Repayments list so interest income stays accurate.'**
  String get lendPayoffConfirmBody;

  /// No description provided for @lendToastLoanNoLongerActive.
  ///
  /// In en, this message translates to:
  /// **'Loan is no longer active'**
  String get lendToastLoanNoLongerActive;

  /// No description provided for @lendToastCouldntPayOff.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t pay off loan'**
  String get lendToastCouldntPayOff;

  /// No description provided for @lendDeleteLoanBody.
  ///
  /// In en, this message translates to:
  /// **'This removes the loan and its repayment records. The bank transactions themselves are not deleted.'**
  String get lendDeleteLoanBody;

  /// No description provided for @lendSheetRecordPayment.
  ///
  /// In en, this message translates to:
  /// **'Record a payment'**
  String get lendSheetRecordPayment;

  /// No description provided for @lendSheetLinkDisbursement.
  ///
  /// In en, this message translates to:
  /// **'Link the disbursement'**
  String get lendSheetLinkDisbursement;

  /// No description provided for @lendSearchInflows.
  ///
  /// In en, this message translates to:
  /// **'Search inflows (money received)'**
  String get lendSearchInflows;

  /// No description provided for @lendSearchOutflows.
  ///
  /// In en, this message translates to:
  /// **'Search outflows (money sent)'**
  String get lendSearchOutflows;

  /// No description provided for @lendNoIncomingTx.
  ///
  /// In en, this message translates to:
  /// **'No incoming transactions found. Try the Cash tab to record an off-bank repayment.'**
  String get lendNoIncomingTx;

  /// No description provided for @lendNoOutgoingTx.
  ///
  /// In en, this message translates to:
  /// **'No outgoing transactions found.'**
  String get lendNoOutgoingTx;

  /// No description provided for @lendCashFormHint.
  ///
  /// In en, this message translates to:
  /// **'Record a repayment received in cash — or into an account whose transactions haven\'t been imported yet (e.g. a statement-based account). It reduces the outstanding balance now; when the bank transaction shows up later, attach it from the payment\'s link button.'**
  String get lendCashFormHint;

  /// No description provided for @lendToastTxAlreadyLinked.
  ///
  /// In en, this message translates to:
  /// **'That transaction is already linked'**
  String get lendToastTxAlreadyLinked;

  /// No description provided for @lendToastCouldntRecordThat.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t record that'**
  String get lendToastCouldntRecordThat;

  /// Action on an off-bank (cash-recorded) repayment to attach the real bank inflow once the statement is imported.
  ///
  /// In en, this message translates to:
  /// **'Link bank transaction'**
  String get lendLinkBankTx;

  /// Title of the picker sheet listing candidate bank inflows to attach to an off-bank repayment.
  ///
  /// In en, this message translates to:
  /// **'Link a bank transaction'**
  String get lendLinkBankTxTitle;

  /// Shown in the link-bank-transaction picker when no candidate inflow was found to attach to the off-bank repayment.
  ///
  /// In en, this message translates to:
  /// **'No matching bank transactions found yet — upload your bank statement first.'**
  String get lendLinkBankTxNone;

  /// Toast shown when attaching a bank transaction to an off-bank repayment fails.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t link that bank transaction'**
  String get lendLinkBankTxError;

  /// Zero-result state of the holdings table when an allocation filter or search matched nothing (portfolio is NOT empty).
  ///
  /// In en, this message translates to:
  /// **'No holdings match \"{filter}\"'**
  String pfFilterNoMatches(Object filter);

  /// No description provided for @pfFilterClear.
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get pfFilterClear;

  /// Toolbar counter while an allocation filter or search is active.
  ///
  /// In en, this message translates to:
  /// **'{shown} of {total, plural, =1{1 holding} other{{total} holdings}}'**
  String pfFilterShownOfTotal(int shown, int total);

  /// Filter-chip / zero-result label for the asset:equity canonical key — must echo the allocation band's display name (the backend's asset_class_label mapping), as must the six sibling pfFilterAsset* keys below.
  ///
  /// In en, this message translates to:
  /// **'Stocks & funds'**
  String get pfFilterAssetEquity;

  /// No description provided for @pfFilterAssetBonds.
  ///
  /// In en, this message translates to:
  /// **'Bonds'**
  String get pfFilterAssetBonds;

  /// No description provided for @pfFilterAssetCash.
  ///
  /// In en, this message translates to:
  /// **'Cash'**
  String get pfFilterAssetCash;

  /// No description provided for @pfFilterAssetCrypto.
  ///
  /// In en, this message translates to:
  /// **'Crypto'**
  String get pfFilterAssetCrypto;

  /// No description provided for @pfFilterAssetRealEstate.
  ///
  /// In en, this message translates to:
  /// **'Real estate'**
  String get pfFilterAssetRealEstate;

  /// No description provided for @pfFilterAssetCommodities.
  ///
  /// In en, this message translates to:
  /// **'Commodities'**
  String get pfFilterAssetCommodities;

  /// No description provided for @pfFilterAssetOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get pfFilterAssetOther;

  /// No description provided for @pfDivShowAllPayers.
  ///
  /// In en, this message translates to:
  /// **'Show all ({count})'**
  String pfDivShowAllPayers(int count);

  /// No description provided for @pfDivShowFewerPayers.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get pfDivShowFewerPayers;

  /// No description provided for @pfDivLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load dividend income'**
  String get pfDivLoadError;

  /// No description provided for @pfDivRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get pfDivRetry;

  /// No description provided for @pfDivDetailFreqMonthly.
  ///
  /// In en, this message translates to:
  /// **'Monthly'**
  String get pfDivDetailFreqMonthly;

  /// No description provided for @pfDivDetailFreqQuarterly.
  ///
  /// In en, this message translates to:
  /// **'Quarterly'**
  String get pfDivDetailFreqQuarterly;

  /// No description provided for @pfDivDetailFreqSemiAnnual.
  ///
  /// In en, this message translates to:
  /// **'Semi-annual'**
  String get pfDivDetailFreqSemiAnnual;

  /// No description provided for @pfDivDetailFreqAnnual.
  ///
  /// In en, this message translates to:
  /// **'Annual'**
  String get pfDivDetailFreqAnnual;

  /// No description provided for @pfDivDetailSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Estimated from the recent payment history — actual dates and amounts may vary.'**
  String get pfDivDetailSubtitle;

  /// No description provided for @pfDivDetailShares.
  ///
  /// In en, this message translates to:
  /// **'Shares'**
  String get pfDivDetailShares;

  /// No description provided for @pfDivDetailMarketValue.
  ///
  /// In en, this message translates to:
  /// **'Market value'**
  String get pfDivDetailMarketValue;

  /// No description provided for @pfDivDetailRatePerShare.
  ///
  /// In en, this message translates to:
  /// **'Rate / share (annual)'**
  String get pfDivDetailRatePerShare;

  /// No description provided for @pfDivDetailPerPayment.
  ///
  /// In en, this message translates to:
  /// **'Per payment'**
  String get pfDivDetailPerPayment;

  /// No description provided for @pfDivDetailAnnualIncome.
  ///
  /// In en, this message translates to:
  /// **'Annual income'**
  String get pfDivDetailAnnualIncome;

  /// No description provided for @pfDivDetailYield.
  ///
  /// In en, this message translates to:
  /// **'Yield'**
  String get pfDivDetailYield;

  /// No description provided for @pfDivDetailYieldOnCost.
  ///
  /// In en, this message translates to:
  /// **'Yield on cost'**
  String get pfDivDetailYieldOnCost;

  /// No description provided for @pfDivDetailLastExDate.
  ///
  /// In en, this message translates to:
  /// **'Last ex-date'**
  String get pfDivDetailLastExDate;

  /// No description provided for @pfDivDetailNextExDate.
  ///
  /// In en, this message translates to:
  /// **'Est. next ex-date'**
  String get pfDivDetailNextExDate;

  /// No description provided for @pfDivDetailSchedule.
  ///
  /// In en, this message translates to:
  /// **'Next 12 months'**
  String get pfDivDetailSchedule;

  /// No description provided for @pfDivDetailHistory.
  ///
  /// In en, this message translates to:
  /// **'Payment history'**
  String get pfDivDetailHistory;

  /// No description provided for @pfDivDetailPerShare.
  ///
  /// In en, this message translates to:
  /// **'per share'**
  String get pfDivDetailPerShare;

  /// No description provided for @pfDivDetailAccounts.
  ///
  /// In en, this message translates to:
  /// **'Held in'**
  String get pfDivDetailAccounts;

  /// No description provided for @pfDivDetailTaxAdvantaged.
  ///
  /// In en, this message translates to:
  /// **'Tax-advantaged'**
  String get pfDivDetailTaxAdvantaged;

  /// No description provided for @pfDivDetailNoHistory.
  ///
  /// In en, this message translates to:
  /// **'No dividend history for this symbol yet.'**
  String get pfDivDetailNoHistory;

  /// No description provided for @pfDivDetailLoadError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load dividend details'**
  String get pfDivDetailLoadError;

  /// Expands the realized-gains card's disposal list from the newest 8 rows to every disposal; count is the total number of disposals.
  ///
  /// In en, this message translates to:
  /// **'Show all ({count})'**
  String rgShowAll(int count);

  /// Collapses the expanded realized-gains disposal list back to the newest rows.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get rgShowFewer;

  /// Caption of the realized-gains year-to-date summary tile, naming the calendar year it covers (e.g. "2026"). Was the ambiguous "This year".
  ///
  /// In en, this message translates to:
  /// **'{year}'**
  String rgYearTile(String year);

  /// One-line empty state on the realized-gains card when the user has never sold a security.
  ///
  /// In en, this message translates to:
  /// **'No realized gains yet'**
  String get rgEmpty;

  /// Inline error row on the realized-gains card when the fetch fails; shown next to a Retry button.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load realized gains'**
  String get rgLoadError;

  /// Retry button on the realized-gains card's inline error row.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get rgRetry;

  /// Title of the destructive confirmation dialog shown before deleting a holding; symbol is the ticker (or name) of the holding.
  ///
  /// In en, this message translates to:
  /// **'Delete {symbol}?'**
  String acctDeleteHoldingTitle(String symbol);

  /// Body of the delete-holding confirmation dialog, spelling out the cascade to purchase lots and realized-gain tax records.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes the holding, all of its purchase lots, and its realized-gain (tax) records. This cannot be undone.'**
  String get acctDeleteHoldingBody;

  /// Destructive confirm button of the delete-holding dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get acctDeleteHoldingConfirm;

  /// Always-visible hint in the allocation card telling the user the bands below are tappable filters.
  ///
  /// In en, this message translates to:
  /// **'Tap a band to filter the holdings table'**
  String get allocTapToFilterHint;

  /// Active-filter indicator in the allocation card header; label is the tapped band's display name.
  ///
  /// In en, this message translates to:
  /// **'Filtered: {label}'**
  String allocActiveFilter(String label);

  /// Tooltip/semantics of the inline X next to the allocation card's active-filter indicator.
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get allocClearFilter;

  /// Screen-reader label for an asset-class allocation band: display label, percentage + amount, real holdings count.
  ///
  /// In en, this message translates to:
  /// **'{label}, {value}, {count, plural, one{{count} holding} other{{count} holdings}}'**
  String allocBandSemanticsHoldings(String label, String value, int count);

  /// Screen-reader label for an account-type/institution allocation band: display label, percentage + amount, account count.
  ///
  /// In en, this message translates to:
  /// **'{label}, {value}, {count, plural, one{{count} account} other{{count} accounts}}'**
  String allocBandSemanticsAccounts(String label, String value, int count);

  /// Screen-reader label for an allocation band whose backend row carries no count.
  ///
  /// In en, this message translates to:
  /// **'{label}, {value}'**
  String allocBandSemanticsNoCount(String label, String value);

  /// Suffix appended to a tappable allocation band's screen-reader label, announcing the tap action.
  ///
  /// In en, this message translates to:
  /// **'filters the holdings table'**
  String get allocBandFiltersTable;

  /// Inline error shown in the instrument detail sheet when the fetch fails; paired with a Retry button.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load instrument details'**
  String get insLoadError;

  /// Muted staleness caption next to the instrument sheet's big price when the latest stored close predates today.
  ///
  /// In en, this message translates to:
  /// **'as of {date}'**
  String insAsOf(String date);

  /// Instrument price-chart range chip: one month.
  ///
  /// In en, this message translates to:
  /// **'1M'**
  String get insRange1m;

  /// Instrument price-chart range chip: three months.
  ///
  /// In en, this message translates to:
  /// **'3M'**
  String get insRange3m;

  /// Instrument price-chart range chip: one year.
  ///
  /// In en, this message translates to:
  /// **'1Y'**
  String get insRange1y;

  /// Instrument price-chart range chip: full available history.
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get insRangeMax;

  /// Graceful empty state replacing the price chart for symbols without stored closes (401k trusts, cash sleeves).
  ///
  /// In en, this message translates to:
  /// **'No price history for this holding'**
  String get insNoPriceHistory;

  /// Instrument sheet stat-grid tile: current USD market value of the position.
  ///
  /// In en, this message translates to:
  /// **'Market value'**
  String get insStatMarketValue;

  /// Instrument sheet stat-grid tile: total shares/units held across accounts.
  ///
  /// In en, this message translates to:
  /// **'Quantity'**
  String get insStatQuantity;

  /// Instrument sheet stat-grid tile: total USD cost basis; em-dash when unknown.
  ///
  /// In en, this message translates to:
  /// **'Cost basis'**
  String get insStatCostBasis;

  /// Instrument sheet stat-grid tile: unrealized gain/loss in USD and percent.
  ///
  /// In en, this message translates to:
  /// **'Gain'**
  String get insStatGain;

  /// Instrument sheet stat-grid tile: the position's share of total portfolio value.
  ///
  /// In en, this message translates to:
  /// **'Portfolio weight'**
  String get insStatWeight;

  /// Instrument sheet stat-grid tile: the holding's canonical asset class, shown as a chip.
  ///
  /// In en, this message translates to:
  /// **'Asset class'**
  String get insStatAssetClass;

  /// Instrument sheet section header listing the position's purchase lots.
  ///
  /// In en, this message translates to:
  /// **'Purchase lots'**
  String get insLotsSection;

  /// Purchase-lot row detail: quantity bought at the per-unit price (native currency).
  ///
  /// In en, this message translates to:
  /// **'{qty} shares @ {price}'**
  String insLotQtyAtPrice(String qty, String price);

  /// Label on the purchase-lots totals row (summed quantity + summed USD cost).
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get insLotsTotal;

  /// TextButton in the instrument sheet that opens the per-symbol dividend detail sheet.
  ///
  /// In en, this message translates to:
  /// **'Dividend details'**
  String get insDividendsLink;

  /// Dividend-sheet section header for real dividend payments matched from account transactions (contract C-D).
  ///
  /// In en, this message translates to:
  /// **'Payments received'**
  String get insDivPaymentsSection;

  /// Expander under the dividend payments list when more than 12 payments exist.
  ///
  /// In en, this message translates to:
  /// **'Show all ({count})'**
  String insDivShowAllPayments(int count);

  /// Collapses the dividend payments list back to the first 12 entries.
  ///
  /// In en, this message translates to:
  /// **'Show fewer'**
  String get insDivShowFewerPayments;

  /// Realized-gains year selector: chip that clears the year filter and shows every disposal.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get rgxAllYears;

  /// Realized-gains card: shown instead of the disposal list when the selected year has no disposals.
  ///
  /// In en, this message translates to:
  /// **'No sales in {year}'**
  String rgxNoSalesInYear(String year);

  /// Compact chip on a disposal row marking a sale inside a tax-advantaged account (Roth/IRA/401k/HSA). Keep very short.
  ///
  /// In en, this message translates to:
  /// **'Tax-adv.'**
  String get rgxTaxAdvBadge;

  /// Tooltip explaining the tax-advantaged chip on a disposal row.
  ///
  /// In en, this message translates to:
  /// **'Roth/IRA/401k/HSA — not taxable'**
  String get rgxTaxAdvTooltip;

  /// Realized-gains taxable caption, first fragment. Rendered as: '<prefix> +$X <suffix>' where +$X is the taxable subtotal (bolded in code).
  ///
  /// In en, this message translates to:
  /// **'Taxable'**
  String get rgxTaxableCaptionPrefix;

  /// Realized-gains taxable caption, fragment after the bolded taxable figure. {total} is the shown period's total realized P&L.
  ///
  /// In en, this message translates to:
  /// **'of {total} — the rest is inside tax-advantaged accounts'**
  String rgxTaxableCaptionSuffix(String total);

  /// Tooltip/semantic label for the realized-gains CSV download button.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get rgxExportCsvTooltip;

  /// Caption over the performance card's headline dollar figure (the current portfolio value).
  ///
  /// In en, this message translates to:
  /// **'Portfolio value'**
  String get rgxPerfPortfolioValue;

  /// Hero 'Today' pill next to the all-time gain pill. {change} is the pre-formatted day change, e.g. '+$4,321 (+0.29%)'.
  ///
  /// In en, this message translates to:
  /// **'{change} today'**
  String pfDayPillToday(String change);

  /// Tooltip on the Today pill when day-change coverage is partial or the latest close pre-dates today.
  ///
  /// In en, this message translates to:
  /// **'As of {date} close · covers {coverage}% of portfolio value'**
  String pfDayPillTooltip(String date, String coverage);

  /// Holdings-table column header for the change since the last stored close (contract C-B).
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get pfDayColHeader;

  /// Tooltip on the em dash in the Day column (cash sleeves, opaque symbols, or stale stored closes).
  ///
  /// In en, this message translates to:
  /// **'No recent closing price for this holding'**
  String get pfDayUnavailable;

  /// Screen-reader label for a dividend-card payer row (WS4 a11y).
  ///
  /// In en, this message translates to:
  /// **'{symbol}, {income} per year, opens dividend details'**
  String pfDaySemPayerRow(String symbol, String income);

  /// Screen-reader label for an upcoming ex-date row on the dividend card (WS4 a11y).
  ///
  /// In en, this message translates to:
  /// **'{symbol}, estimated ex-date {date}, expected {amount}'**
  String pfDaySemExDateRow(String symbol, String date, String amount);

  /// Tail of the screen-reader label for a grouped-by-account section header; preceded by the account and institution names (WS4 a11y).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 position} other{{count} positions}}, subtotal {amount}'**
  String pfDaySemPositionsSubtotal(int count, String amount);

  /// Screen-reader label for a compact holding row in the grouped-by-account view. {ret} is the pre-formatted return, e.g. '+12.34%', or an em dash (WS4 a11y).
  ///
  /// In en, this message translates to:
  /// **'{symbol}, {qty} shares, {value}, {ret} return'**
  String pfDaySemHoldingRow(
    String symbol,
    String qty,
    String value,
    String ret,
  );

  /// Tooltip on the holdings-toolbar download menu button (contract C-E).
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get pfCsvExportTooltip;

  /// Export-menu item: download the holdings table as CSV.
  ///
  /// In en, this message translates to:
  /// **'Holdings (CSV)'**
  String get pfCsvHoldings;

  /// Export-menu item: download the purchase lots as CSV.
  ///
  /// In en, this message translates to:
  /// **'Purchase lots (CSV)'**
  String get pfCsvLots;

  /// Screen-reader hint on an Overview account row: activating it opens the account detail panel.
  ///
  /// In en, this message translates to:
  /// **'Opens account details'**
  String get ovwOpensAccountDetails;

  /// Screen-reader fragment for a masked account number (••1234) in an Overview row label.
  ///
  /// In en, this message translates to:
  /// **'ending in {digits}'**
  String ovwEndingIn(String digits);

  /// Tooltip/screen-reader label of the per-account overflow menu on the Overview accounts list.
  ///
  /// In en, this message translates to:
  /// **'Account actions for {name}'**
  String ovwAccountActionsFor(String name);

  /// Label of the muted, non-tappable allocation band for investment accounts that carry a balance but no holdings rows (contract C-G).
  ///
  /// In en, this message translates to:
  /// **'Unclassified (account balance)'**
  String get alloc2UnclassifiedBand;

  /// Tooltip + screen-reader explanation on the Unclassified allocation band.
  ///
  /// In en, this message translates to:
  /// **'Account balance without holdings detail — open the account to see it'**
  String get alloc2UnclassifiedTooltip;

  /// Tooltip / screen-reader hint on the instrument sheet's tappable asset-class tile (round-3 override editor).
  ///
  /// In en, this message translates to:
  /// **'Edit asset class'**
  String get ins3EditAssetClass;

  /// Selector row that clears a manual asset-class override, reverting to the heuristic classification (plain variant, used when the heuristic class is unknown).
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get ins3Automatic;

  /// Selector row that clears a manual asset-class override, naming the heuristic class it reverts to.
  ///
  /// In en, this message translates to:
  /// **'Automatic — {className}'**
  String ins3AutomaticWithClass(String className);

  /// Tiny caption on the asset-class stat tile when the shown class is a user override rather than the heuristic.
  ///
  /// In en, this message translates to:
  /// **'manual'**
  String get ins3ManualCaption;

  /// Snackbar error when saving or clearing an asset-class override fails; the chip reverts to its previous value.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update the asset class'**
  String get ins3UpdateError;

  /// Compact share count on line 1 of the narrow (two-line) lot-breakdown row, e.g. '0.1181 sh'. Fractional quantities keep 4 decimals.
  ///
  /// In en, this message translates to:
  /// **'{qty} sh'**
  String pf3LotQtyShares(String qty);

  /// Current-value fragment on line 2 of the narrow lot row ('@ $88.10 → $1,720.00 now · cost $881.00'). Replaced by an em dash when the holding has no current price.
  ///
  /// In en, this message translates to:
  /// **'{value} now'**
  String pf3LotCurrentNow(String value);

  /// USD-cost fragment on line 2 of the narrow lot row ('@ $88.10 → $1,720.00 now · cost $881.00').
  ///
  /// In en, this message translates to:
  /// **'cost {cost}'**
  String pf3LotCost(String cost);

  /// Reserved caption under the realized-gains summary tiles when the selected period has disposals but none in tax-advantaged accounts — same style and height as the mixed 'Taxable +$X of +$Y…' caption so flipping year chips never shifts the layout.
  ///
  /// In en, this message translates to:
  /// **'All realized gains in this period are taxable.'**
  String get rg3AllTaxable;

  /// Softened round-3 confirm-dialog body for deleting a holding (delete is now undoable for a few seconds, so the round-1 'cannot be undone' copy no longer applies). The undo hint is appended after it.
  ///
  /// In en, this message translates to:
  /// **'This deletes the holding, all of its purchase lots, and its realized-gain (tax) records.'**
  String get acct3DeleteHoldingBody;

  /// Appended to the delete-holding confirm dialog body, announcing the undo snackbar window.
  ///
  /// In en, this message translates to:
  /// **'You can undo for a few seconds after deleting.'**
  String get acct3UndoHint;

  /// Snackbar text shown for ~10 seconds after a holding delete, next to the UNDO action.
  ///
  /// In en, this message translates to:
  /// **'Deleted {symbol}'**
  String acct3DeletedSnack(String symbol);

  /// Action label on the delete-holding snackbar that restores the holding, its lots and its realized-gain records.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get acct3Undo;

  /// Error snackbar when UNDO hits a 404: the soft-deleted holding was already purged (24 h window elapsed or the symbol was re-added), so the deletion can no longer be reversed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t restore — the deletion is already permanent.'**
  String get acct3RestoreGone;

  /// Error snackbar for a transient (non-404) failure of the UNDO restore call.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t restore the holding. Try again.'**
  String get acct3RestoreFailed;

  /// Overview stat-strip tile label: projected annual dividend income (round 3, O1).
  ///
  /// In en, this message translates to:
  /// **'Dividends/yr'**
  String get ovw3DividendsPerYear;

  /// Tooltip on the Overview Dividends/yr stat tile, including the blended yield.
  ///
  /// In en, this message translates to:
  /// **'Projected annual dividend income · blended yield {yieldPct}% — tap to see payers'**
  String ovw3DividendsTooltip(String yieldPct);

  /// Tooltip on the Overview Dividends/yr stat tile when the blended yield is unavailable.
  ///
  /// In en, this message translates to:
  /// **'Projected annual dividend income — tap to see payers'**
  String get ovw3DividendsTooltipNoYield;

  /// Projections advanced toggle: reveals the informational dividend income panel under the chart.
  ///
  /// In en, this message translates to:
  /// **'Show dividend income outlook'**
  String get proj3ShowDividends;

  /// Help caption under the dividend income outlook toggle.
  ///
  /// In en, this message translates to:
  /// **'Adds an informational income panel below the chart — it never changes the projection.'**
  String get proj3ShowDividendsHelp;

  /// Tooltip on the disabled dividend outlook toggle when the portfolio pays no dividends.
  ///
  /// In en, this message translates to:
  /// **'Your portfolio has no projected dividend income'**
  String get proj3ShowDividendsUnavailable;

  /// Title of the informational dividend income panel on the Projections tab.
  ///
  /// In en, this message translates to:
  /// **'Dividend income outlook'**
  String get proj3OutlookTitle;

  /// First row label of the dividend outlook panel: income at today's balance.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get proj3RowToday;

  /// Second row label of the dividend outlook panel: income at the retirement-year median balance.
  ///
  /// In en, this message translates to:
  /// **'At retirement (~{year})'**
  String proj3RowRetirement(String year);

  /// Third row label of the dividend outlook panel: income at the final projected year's median balance.
  ///
  /// In en, this message translates to:
  /// **'At horizon ({year})'**
  String proj3RowHorizon(String year);

  /// Dividend outlook value: exact annual income figure (today row).
  ///
  /// In en, this message translates to:
  /// **'{amount}/yr'**
  String proj3PerYear(String amount);

  /// Dividend outlook value: approximate annual income figure (projected rows).
  ///
  /// In en, this message translates to:
  /// **'≈{amount}/yr'**
  String proj3PerYearApprox(String amount);

  /// Sub-caption on the dividend outlook Today row stating the blended yield used.
  ///
  /// In en, this message translates to:
  /// **'{pct}% blended yield'**
  String proj3BlendedYieldNote(String pct);

  /// Basis caption on the dividend outlook panel when the real-dollars view is active.
  ///
  /// In en, this message translates to:
  /// **'in today\'s dollars'**
  String get proj3InTodaysDollars;

  /// Mandatory honesty disclaimer under the dividend outlook panel.
  ///
  /// In en, this message translates to:
  /// **'Assumes today\'s blended yield holds. Dividends are already part of the expected total return above — this is informational and is not added to growth.'**
  String get proj3DisclaimerBody;

  /// A11y: merged label for the portfolio hero (total value + all-time change pill).
  ///
  /// In en, this message translates to:
  /// **'Portfolio value {value}, all-time {allTime}'**
  String axPortfolioHero(String value, String allTime);

  /// A11y: optional day-change fragment appended to the portfolio hero label.
  ///
  /// In en, this message translates to:
  /// **'today {change}'**
  String axHeroToday(String change);

  /// A11y: label announced for the holdings toolbar's active category-filter chip.
  ///
  /// In en, this message translates to:
  /// **'Active filter: {label}'**
  String axActiveFilter(String label);

  /// A11y: delete-affordance tooltip on the active-filter chip (replaces the bare 'Delete').
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get axClearFilter;

  /// A11y: one-sentence label per lot row in the lot-breakdown dialog.
  ///
  /// In en, this message translates to:
  /// **'Acquired {date}, {qty} shares at {cost}, {term}'**
  String axLotRow(String date, String qty, String cost, String term);

  /// A11y: label for a realized-gains year filter chip.
  ///
  /// In en, this message translates to:
  /// **'Year {year}'**
  String axYearChip(String year);

  /// A11y: label for the realized-gains 'All' year chip.
  ///
  /// In en, this message translates to:
  /// **'All years'**
  String get axAllYears;

  /// A11y: sold-date fragment inside a disposal row's one-sentence label.
  ///
  /// In en, this message translates to:
  /// **'sold {date}'**
  String axSoldOn(String date);

  /// A11y: label for the allocation card's dimension-switcher chips.
  ///
  /// In en, this message translates to:
  /// **'Group by {dimension}'**
  String axGroupBy(String dimension);

  /// A11y: label for a collapsible account-group header (name, count, converted total).
  ///
  /// In en, this message translates to:
  /// **'{name}, {count, plural, =1{1 account} other{{count} accounts}}, {total}'**
  String axGroupAccounts(String name, int count, String total);

  /// A11y: hint on a collapsed group/section toggle.
  ///
  /// In en, this message translates to:
  /// **'Tap to expand'**
  String get axTapToExpand;

  /// A11y: hint on an expanded group/section toggle.
  ///
  /// In en, this message translates to:
  /// **'Tap to collapse'**
  String get axTapToCollapse;

  /// A11y: tooltip/label for the per-holding delete button in the account panel.
  ///
  /// In en, this message translates to:
  /// **'Remove {symbol}'**
  String axRemoveHolding(String symbol);

  /// A11y: tooltip for the account panel's kebab menu, naming the account.
  ///
  /// In en, this message translates to:
  /// **'Account actions for {name}'**
  String axAccountActionsFor(String name);

  /// A11y: dividend-income fragment inside a holding row's one-sentence label.
  ///
  /// In en, this message translates to:
  /// **'dividend {amount} per year'**
  String axDividendPerYear(String amount);

  /// A11y: summary label for the wealth-projection line chart (internals excluded).
  ///
  /// In en, this message translates to:
  /// **'Projected balance from {start} to {end}, median ending {value}'**
  String axProjectionChart(String start, String end, String value);

  /// A11y: hint on the dividend-outlook panel marking it as informational.
  ///
  /// In en, this message translates to:
  /// **'Informational — dividends are already part of the expected total return and are not added to growth'**
  String get axInformational;

  /// Expander label on the dividend-income card revealing the projected 12-month income calendar (C4-B).
  ///
  /// In en, this message translates to:
  /// **'Show 12-month calendar'**
  String get calShowCalendar;

  /// Expander label collapsing the projected 12-month income calendar.
  ///
  /// In en, this message translates to:
  /// **'Hide 12-month calendar'**
  String get calHideCalendar;

  /// Mandatory honesty caption under the dividend calendar: projections, not declared dividends.
  ///
  /// In en, this message translates to:
  /// **'Estimated from each payer\'s current rate and cadence — not announced dates.'**
  String get calEstimateCaption;

  /// A11y hint on a collapsed calendar month row with income: tapping expands the inline per-payer breakdown.
  ///
  /// In en, this message translates to:
  /// **'Show payer breakdown'**
  String get calExpandHint;

  /// A11y hint on an expanded calendar month row: tapping collapses the inline per-payer breakdown.
  ///
  /// In en, this message translates to:
  /// **'Hide payer breakdown'**
  String get calCollapseHint;

  /// Tooltip on a calendar payer chip: the estimated ex-dividend date, e.g. 'Est. ex-date Jul 14, 2026'.
  ///
  /// In en, this message translates to:
  /// **'Est. ex-date {date}'**
  String calEstExDate(String date);

  /// A11y: one-sentence merged label per calendar month cell with income, e.g. 'July 2026, $310 expected, KO, ABBV'.
  ///
  /// In en, this message translates to:
  /// **'{month}, {amount} expected, {symbols}'**
  String calMonthSem(String month, String amount, String symbols);

  /// A11y: merged label for a calendar month cell with zero projected income.
  ///
  /// In en, this message translates to:
  /// **'{month}, no dividends expected'**
  String calMonthSemEmpty(String month);

  /// Tooltip on the dividend detail sheet's refresh button — forces a live re-fetch past the server-side cache (C4-D).
  ///
  /// In en, this message translates to:
  /// **'Refresh dividend data'**
  String get pfDivDetailRefresh;

  /// WS2r4: header of the rebalancing card on the Portfolio tab.
  ///
  /// In en, this message translates to:
  /// **'Target allocation'**
  String get rebCardTitle;

  /// WS2r4: header button opening the targets editor sheet.
  ///
  /// In en, this message translates to:
  /// **'Edit targets'**
  String get rebEditTargets;

  /// WS2r4: one-line setup CTA body shown when no targets are stored yet.
  ///
  /// In en, this message translates to:
  /// **'Set target percentages per asset class to see drift and rebalancing hints'**
  String get rebSetTargetsCta;

  /// WS2r4: button on the setup CTA that opens the targets editor.
  ///
  /// In en, this message translates to:
  /// **'Set targets'**
  String get rebSetTargetsButton;

  /// WS2r4: warning banner when the stored allocation_targets setting violates the C4-A contract.
  ///
  /// In en, this message translates to:
  /// **'Saved targets need attention — they don\'t add up to 100%.'**
  String get rebRepairBanner;

  /// WS2r4: button on the repair state that opens the targets editor.
  ///
  /// In en, this message translates to:
  /// **'Fix targets'**
  String get rebRepairButton;

  /// WS2r4: delta chip text when a class is within 2 pp of its target.
  ///
  /// In en, this message translates to:
  /// **'on target'**
  String get rebOnTargetChip;

  /// WS2r4: delta chip text, e.g. '+8.3 pp' — pp = percentage points.
  ///
  /// In en, this message translates to:
  /// **'{delta} pp'**
  String rebDeltaChip(String delta);

  /// WS2r4 a11y: one-sentence label for a drift row.
  ///
  /// In en, this message translates to:
  /// **'{label}: actual {actual}%, target {target}%, {delta}'**
  String rebRowSemantics(
    String label,
    String actual,
    String target,
    String delta,
  );

  /// WS2r4: muted footnote when unclassified balances are part of the denominator (decision #5).
  ///
  /// In en, this message translates to:
  /// **'Unclassified: {pct} — classify these holdings to include them in targets'**
  String rebUnclassifiedFootnote(String pct);

  /// fix-5: footnote when the unclassified share comes ONLY from balance-only account bands (nothing to classify) — no 'classify these holdings' nudge.
  ///
  /// In en, this message translates to:
  /// **'Unclassified: {pct} — account balances without holdings detail, kept in the totals'**
  String rebUnclassifiedBalanceFootnote(String pct);

  /// WS2r4: section header above the move-guidance lines (sentence case, matching the dividend card's section headers).
  ///
  /// In en, this message translates to:
  /// **'To reach targets'**
  String get rebGuidanceTitle;

  /// WS2r4: one rebalancing suggestion line.
  ///
  /// In en, this message translates to:
  /// **'Move {amount} from {from} to {to}'**
  String rebMoveLine(String amount, String from, String to);

  /// WS2r4: trailing line when move suggestions were truncated (3-line cap / $500 floor).
  ///
  /// In en, this message translates to:
  /// **'…and smaller adjustments'**
  String get rebMoreAdjustments;

  /// WS2r4: positive-toned line when every class drift is inside the ±2 pp band.
  ///
  /// In en, this message translates to:
  /// **'Within 2 pp of every target — no moves needed.'**
  String get rebNoMoves;

  /// WS2r4: muted line when drift exists but every suggested move would be under the $500 floor.
  ///
  /// In en, this message translates to:
  /// **'Remaining drift is under the action floor — no moves suggested.'**
  String get rebBelowFloor;

  /// WS2r4: mandatory tax caveat under the guidance block.
  ///
  /// In en, this message translates to:
  /// **'Guidance only — consider taxes and lot selection before selling.'**
  String get rebTaxCaption;

  /// WS2r4: header of the targets editor bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Edit target allocation'**
  String get rebEditorTitle;

  /// WS2r4: live sum meter in the editor footer; valid only at exactly 100.
  ///
  /// In en, this message translates to:
  /// **'Total: {total} / 100'**
  String rebEditorTotal(String total);

  /// WS2r4: helper button that dumps the residual to 100 into the largest field.
  ///
  /// In en, this message translates to:
  /// **'Distribute remainder'**
  String get rebDistributeRemainder;

  /// WS2r4: destructive action clearing the stored targets (returns the card to its setup CTA).
  ///
  /// In en, this message translates to:
  /// **'Remove targets'**
  String get rebRemoveTargets;

  /// WS2r4: confirm-dialog title for removing targets.
  ///
  /// In en, this message translates to:
  /// **'Remove targets?'**
  String get rebRemoveConfirmTitle;

  /// WS2r4: confirm-dialog body for removing targets.
  ///
  /// In en, this message translates to:
  /// **'The card returns to its setup state. Your holdings are not affected.'**
  String get rebRemoveConfirmBody;

  /// WS2r4: snackbar when the optimistic targets save fails and is reverted.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save targets — try again.'**
  String get rebSaveError;

  /// WS2r4: snackbar when clearing the targets fails and is reverted.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t remove targets — try again.'**
  String get rebRemoveError;

  /// WS-B: label for the since-baseline net-worth movers section under the delta chips; {date} is the baseline snapshot date (e.g. 'Jun 8').
  ///
  /// In en, this message translates to:
  /// **'Since {date}'**
  String nwMoversSince(String date);

  /// WS-B: tooltip / accessibility label on the expandable movers row that reveals the top institution movers.
  ///
  /// In en, this message translates to:
  /// **'What drove this change'**
  String get nwMoversToggleTooltip;

  /// Net-worth attribution: overline title for the FX / market / flows decomposition row under the chart.
  ///
  /// In en, this message translates to:
  /// **'Why it changed'**
  String get nwAttrTitle;

  /// Net-worth attribution: component label for the USD/MXN exchange-rate effect.
  ///
  /// In en, this message translates to:
  /// **'FX'**
  String get nwAttrFx;

  /// Net-worth attribution: component label for native-currency value change net of flows (investment/price movement).
  ///
  /// In en, this message translates to:
  /// **'Market'**
  String get nwAttrMarket;

  /// Net-worth attribution: component label for net external money in/out (transactions).
  ///
  /// In en, this message translates to:
  /// **'Flows'**
  String get nwAttrFlows;

  /// Net-worth attribution: residual bucket label; only shown when nonzero so the decomposition stays honest without cluttering the common case.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get nwAttrOther;

  /// Net-worth attribution: muted inline error when the attribution endpoint fails.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load change attribution'**
  String get nwAttrError;

  /// Net-worth card currency-lens toggle: third segment that revalues MXN balances at the window-start rate (alongside USD and MXN).
  ///
  /// In en, this message translates to:
  /// **'Constant FX'**
  String get nwLensConstantFx;

  /// Caption under the chart while the constant-FX lens is active; {rate} is the window-start USD→MXN rate already formatted for the locale.
  ///
  /// In en, this message translates to:
  /// **'MXN revalued at the window-start rate ({rate} MXN/USD)'**
  String nwLensConstantCaption(String rate);

  /// FX center: appended to the app-bar FX pill tooltip/semantics now that tapping it opens the FX center sheet.
  ///
  /// In en, this message translates to:
  /// **'Tap for rate history & tools'**
  String get fxcPillTapHint;

  /// FX center: appended to the compact combined currency chip tooltip — long-pressing the chip opens the FX center sheet (tap still toggles the display currency).
  ///
  /// In en, this message translates to:
  /// **'Hold for rate history & tools'**
  String get fxcChipHoldHint;

  /// No description provided for @fxcRange30d.
  ///
  /// In en, this message translates to:
  /// **'30 days'**
  String get fxcRange30d;

  /// No description provided for @fxcRange90d.
  ///
  /// In en, this message translates to:
  /// **'90 days'**
  String get fxcRange90d;

  /// No description provided for @fxcNoHistory.
  ///
  /// In en, this message translates to:
  /// **'No rate history yet'**
  String get fxcNoHistory;

  /// No description provided for @fxcHistoryFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load rate history'**
  String get fxcHistoryFailed;

  /// FX center: screen-reader summary mirrored over the pointer-only sparkline. gen-l10n orders placeholders alphabetically: (count, latest, pair).
  ///
  /// In en, this message translates to:
  /// **'{pair} rate history: {count, plural, one{{count} daily point} other{{count} daily points}}, latest {latest}'**
  String fxcChartSemantics(int count, String latest, String pair);

  /// No description provided for @fxcConverterTitle.
  ///
  /// In en, this message translates to:
  /// **'Converter'**
  String get fxcConverterTitle;

  /// No description provided for @fxcAlertTitle.
  ///
  /// In en, this message translates to:
  /// **'Rate alert'**
  String get fxcAlertTitle;

  /// FX center: helper text under the alert-threshold field. Placeholders alphabetical: (base, target).
  ///
  /// In en, this message translates to:
  /// **'Get notified when the {base}/{target} rate crosses this value.'**
  String fxcAlertHint(String base, String target);

  /// FX center: confirmation line shown while an alert threshold is configured.
  ///
  /// In en, this message translates to:
  /// **'Alert set: you\'ll be notified when the rate crosses {threshold}'**
  String fxcAlertActive(String threshold);

  /// No description provided for @fxcAlertClear.
  ///
  /// In en, this message translates to:
  /// **'Remove alert'**
  String get fxcAlertClear;

  /// No description provided for @fxcAlertSaved.
  ///
  /// In en, this message translates to:
  /// **'Rate alert saved'**
  String get fxcAlertSaved;

  /// No description provided for @fxcAlertCleared.
  ///
  /// In en, this message translates to:
  /// **'Rate alert removed'**
  String get fxcAlertCleared;

  /// No description provided for @fxcAlertInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a threshold greater than zero'**
  String get fxcAlertInvalid;

  /// No description provided for @fxcAlertFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the alert'**
  String get fxcAlertFailed;

  /// No description provided for @fxcRefreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t refresh the rate'**
  String get fxcRefreshFailed;

  /// FX center: section title for the annual transfer-cost report (what moving money between currencies cost vs mid-market).
  ///
  /// In en, this message translates to:
  /// **'Transfer costs'**
  String get fxcCostsTitle;

  /// FX center: caveat line under the transfer-cost report; {days} is the backend's spot-lookup tolerance (spot_window_days).
  ///
  /// In en, this message translates to:
  /// **'Total cost vs the mid-market rate — nearest stored rate within ±{days} days of each transfer.'**
  String fxcCostsCaveat(int days);

  /// No description provided for @fxcCostsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No linked transfers yet'**
  String get fxcCostsEmpty;

  /// No description provided for @fxcCostsFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load transfer costs'**
  String get fxcCostsFailed;

  /// No description provided for @fxcCostsUnknownProvider.
  ///
  /// In en, this message translates to:
  /// **'Unknown provider'**
  String get fxcCostsUnknownProvider;

  /// FX center: per-year subtitle in the transfer-cost report. gen-l10n orders placeholders alphabetically: (count, moved).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer · {moved} moved} other{{count} transfers · {moved} moved}}'**
  String fxcCostsYearLine(int count, String moved);

  /// FX center: note when some transfers lacked a nearby spot rate and were left out of the cost figure.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer had no market rate within the window and is excluded from the cost} other{{count} transfers had no market rate within the window and are excluded from the cost}}'**
  String fxcCostsMissingSpot(int count);

  /// No description provided for @recTitle.
  ///
  /// In en, this message translates to:
  /// **'Recurring'**
  String get recTitle;

  /// No description provided for @recExpectedChip.
  ///
  /// In en, this message translates to:
  /// **'Expected'**
  String get recExpectedChip;

  /// No description provided for @recExpectedNote.
  ///
  /// In en, this message translates to:
  /// **'Expected from your recurring rules — not actual transactions.'**
  String get recExpectedNote;

  /// No description provided for @recExpectedIn.
  ///
  /// In en, this message translates to:
  /// **'Expected in'**
  String get recExpectedIn;

  /// No description provided for @recExpectedOut.
  ///
  /// In en, this message translates to:
  /// **'Expected out'**
  String get recExpectedOut;

  /// No description provided for @recManage.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get recManage;

  /// No description provided for @recManageTitle.
  ///
  /// In en, this message translates to:
  /// **'Recurring rules'**
  String get recManageTitle;

  /// No description provided for @recNoRules.
  ///
  /// In en, this message translates to:
  /// **'No recurring rules yet. Use \"Make recurring\" on a transaction, or the Repeats option when adding one.'**
  String get recNoRules;

  /// No description provided for @recNothingUpcoming.
  ///
  /// In en, this message translates to:
  /// **'Nothing more expected this period.'**
  String get recNothingUpcoming;

  /// No description provided for @recPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get recPaused;

  /// No description provided for @recPauseRule.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get recPauseRule;

  /// No description provided for @recResumeRule.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get recResumeRule;

  /// No description provided for @recCadenceWeekly.
  ///
  /// In en, this message translates to:
  /// **'Weekly'**
  String get recCadenceWeekly;

  /// No description provided for @recCadenceBiweekly.
  ///
  /// In en, this message translates to:
  /// **'Every 2 weeks'**
  String get recCadenceBiweekly;

  /// No description provided for @recCadenceMonthly.
  ///
  /// In en, this message translates to:
  /// **'Monthly'**
  String get recCadenceMonthly;

  /// No description provided for @recCadenceYearly.
  ///
  /// In en, this message translates to:
  /// **'Yearly'**
  String get recCadenceYearly;

  /// No description provided for @recNextDue.
  ///
  /// In en, this message translates to:
  /// **'Next: {date}'**
  String recNextDue(Object date);

  /// No description provided for @recMakeRecurring.
  ///
  /// In en, this message translates to:
  /// **'Make recurring'**
  String get recMakeRecurring;

  /// No description provided for @recRuleCreated.
  ///
  /// In en, this message translates to:
  /// **'Recurring rule created'**
  String get recRuleCreated;

  /// No description provided for @recRuleDeleted.
  ///
  /// In en, this message translates to:
  /// **'Recurring rule deleted'**
  String get recRuleDeleted;

  /// No description provided for @recDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete recurring rule?'**
  String get recDeleteConfirmTitle;

  /// No description provided for @recDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'\"{description}\" will no longer appear in expected cash flow. Past transactions are not affected.'**
  String recDeleteConfirmBody(Object description);

  /// No description provided for @recRepeats.
  ///
  /// In en, this message translates to:
  /// **'Repeats'**
  String get recRepeats;

  /// No description provided for @recRepeatsNever.
  ///
  /// In en, this message translates to:
  /// **'Does not repeat'**
  String get recRepeatsNever;

  /// No description provided for @recNextDueDate.
  ///
  /// In en, this message translates to:
  /// **'Next due date'**
  String get recNextDueDate;

  /// No description provided for @recCreateRule.
  ///
  /// In en, this message translates to:
  /// **'Create rule'**
  String get recCreateRule;

  /// No description provided for @projMxToggle.
  ///
  /// In en, this message translates to:
  /// **'Retire in Mexico'**
  String get projMxToggle;

  /// No description provided for @projMxToggleOn.
  ///
  /// In en, this message translates to:
  /// **'Retirement spending is split into a USD portion and an MXN portion, with a long-run FX drift assumption'**
  String get projMxToggleOn;

  /// No description provided for @projMxToggleOff.
  ///
  /// In en, this message translates to:
  /// **'Off — retirement spending is a single figure in dollars'**
  String get projMxToggleOff;

  /// No description provided for @projMxUsdPortion.
  ///
  /// In en, this message translates to:
  /// **'U.S. spending (USD/yr)'**
  String get projMxUsdPortion;

  /// No description provided for @projMxHelpUsdPortion.
  ///
  /// In en, this message translates to:
  /// **'The part of your retirement spending that stays in dollars, in today\'s dollars.'**
  String get projMxHelpUsdPortion;

  /// No description provided for @projMxMxnPortion.
  ///
  /// In en, this message translates to:
  /// **'Mexico spending (MXN/yr)'**
  String get projMxMxnPortion;

  /// No description provided for @projMxHelpMxnPortion.
  ///
  /// In en, this message translates to:
  /// **'The part of your retirement spending in pesos, in today\'s pesos.'**
  String get projMxHelpMxnPortion;

  /// No description provided for @projMxFxDrift.
  ///
  /// In en, this message translates to:
  /// **'Long-run FX drift (USD/MXN)'**
  String get projMxFxDrift;

  /// No description provided for @projMxHelpFxDrift.
  ///
  /// In en, this message translates to:
  /// **'Assumed yearly change in the USD/MXN rate beyond inflation. Positive = the peso weakens, so peso spending costs fewer dollars; 0% = purchasing power parity holds.'**
  String get projMxHelpFxDrift;

  /// No description provided for @projMxPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'Retire in Mexico scenario'**
  String get projMxPanelTitle;

  /// No description provided for @projMxIncomeRow.
  ///
  /// In en, this message translates to:
  /// **'Retirement income (monthly)'**
  String get projMxIncomeRow;

  /// No description provided for @projMxEffectiveSpend.
  ///
  /// In en, this message translates to:
  /// **'Effective annual spending'**
  String get projMxEffectiveSpend;

  /// No description provided for @projMxRateLine.
  ///
  /// In en, this message translates to:
  /// **'USD/MXN {now} today → ≈{retire} at retirement'**
  String projMxRateLine(String now, String retire);

  /// No description provided for @projMxDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'The peso portion is converted at the projected rate at retirement and the model still runs in today\'s U.S. dollars. Peso figures are shown at that same rate.'**
  String get projMxDisclaimer;

  /// No description provided for @bcTitle.
  ///
  /// In en, this message translates to:
  /// **'Bills calendar'**
  String get bcTitle;

  /// No description provided for @bcProjectedBalances.
  ///
  /// In en, this message translates to:
  /// **'Projected balances'**
  String get bcProjectedBalances;

  /// No description provided for @bcProjectedCaption.
  ///
  /// In en, this message translates to:
  /// **'Cash on hand plus expected bills over the next {days} days. Estimates only — nothing posts automatically.'**
  String bcProjectedCaption(int days);

  /// No description provided for @bcStatePaid.
  ///
  /// In en, this message translates to:
  /// **'Paid'**
  String get bcStatePaid;

  /// No description provided for @bcStateUpcoming.
  ///
  /// In en, this message translates to:
  /// **'Upcoming'**
  String get bcStateUpcoming;

  /// No description provided for @bcStateLate.
  ///
  /// In en, this message translates to:
  /// **'Late'**
  String get bcStateLate;

  /// No description provided for @bcStateMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get bcStateMissed;

  /// No description provided for @bcStatePendingImport.
  ///
  /// In en, this message translates to:
  /// **'Pending import'**
  String get bcStatePendingImport;

  /// No description provided for @bcAwaitingImport.
  ///
  /// In en, this message translates to:
  /// **'Awaiting statement import'**
  String get bcAwaitingImport;

  /// No description provided for @bcAwaitingImportHint.
  ///
  /// In en, this message translates to:
  /// **'This account updates by statement import and its newest data doesn\'t cover this due date yet, so the bill isn\'t marked late.'**
  String get bcAwaitingImportHint;

  /// No description provided for @bcNothingDue.
  ///
  /// In en, this message translates to:
  /// **'Nothing due this day.'**
  String get bcNothingDue;

  /// No description provided for @bcLoanRepayment.
  ///
  /// In en, this message translates to:
  /// **'Loan payment — {name}'**
  String bcLoanRepayment(String name);

  /// No description provided for @bcPrevMonth.
  ///
  /// In en, this message translates to:
  /// **'Previous month'**
  String get bcPrevMonth;

  /// No description provided for @bcNextMonth.
  ///
  /// In en, this message translates to:
  /// **'Next month'**
  String get bcNextMonth;

  /// No description provided for @bcFxPrompt.
  ///
  /// In en, this message translates to:
  /// **'Consider moving {surplus} to {deficit} before {date}: projected shortfall of {amount}.'**
  String bcFxPrompt(String surplus, String deficit, String date, String amount);

  /// No description provided for @bcDaySem.
  ///
  /// In en, this message translates to:
  /// **'{date}: {count, plural, =0{nothing due} =1{1 item} other{{count} items}}'**
  String bcDaySem(String date, int count);

  /// No description provided for @bcProjectionSem.
  ///
  /// In en, this message translates to:
  /// **'Projected {currency} balance from {start} today to {end} at the end of the window'**
  String bcProjectionSem(String currency, String start, String end);
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
