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
}
