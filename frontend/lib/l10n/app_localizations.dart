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
