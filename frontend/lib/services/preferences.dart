// Raw storage backend behind a conditional import: the real localStorage on
// web, a no-op stub everywhere else. This keeps `package:web` out of the test
// VM — importing Preferences in a widget test no longer drags package:web in
// (mirrors account_alerts_cache). The web impl already swallows localStorage
// exceptions (private-browsing), so _read/_write don't re-wrap.
import 'dart:convert';

import 'preferences_storage_stub.dart'
    if (dart.library.js_interop) 'preferences_storage_web.dart'
    if (dart.library.io) 'preferences_storage_io.dart';

/// Thin wrapper around `window.localStorage` for user preferences that
/// should survive a page refresh — reporting currency, last selected tab,
/// chart date range, the flat-vs-grouped toggle on the portfolio, etc.
///
/// All values are strings on the wire; callers convert via the typed
/// helpers below. Keys are namespaced with `patrimonio:` so we don't
/// collide with other apps if this site is ever served behind a path.
class Preferences {
  static const _prefix = 'patrimonio:';

  /// Preload the persistent store. No-op on web (localStorage is synchronous);
  /// on native it hydrates the in-memory cache from shared_preferences. Must be
  /// awaited in `main()` before any preference is read.
  static Future<void> init() => initPrefsStorage();

  static String? _read(String key) => prefsRead('$_prefix$key');

  static void _write(String key, String value) =>
      prefsWrite('$_prefix$key', value);

  // -- Typed accessors ---------------------------------------------------

  /// Reporting currency the user last picked from the app-bar toggle.
  /// Defaults to USD when nothing is stored.
  static String getCurrency() => _read('currency') ?? 'USD';
  static void setCurrency(String code) => _write('currency', code);

  /// UI language as a locale code ('en' / 'es'). Null/empty = follow the
  /// device locale (among the app's supported locales).
  static String? getLocale() {
    final v = _read('locale');
    return (v == null || v.isEmpty) ? null : v;
  }

  static void setLocale(String? code) => _write('locale', code ?? '');

  /// Last-active navigation section, stored as the NavId's `name` so it
  /// survives section reordering and the conditional Lending section
  /// (mirrors how the date-range pref is stored). Null when unset — the
  /// caller resolves it to an index and defaults to Overview.
  static String? getLastSection() => _read('lastSection');
  static void setLastSection(String id) => _write('lastSection', id);

  /// The DateRange enum value the user last selected on the net-worth
  /// chart. Stored as the enum's `name` so it survives across reorders.
  static String? getDateRange() => _read('dateRange');
  static void setDateRange(String name) => _write('dateRange', name);

  /// Whether the portfolio "Flat" vs "By account" toggle was on
  /// (`true` = grouped by account).
  static bool getGroupByAccount() => _read('groupByAccount') == 'true';
  static void setGroupByAccount(bool v) =>
      _write('groupByAccount', v.toString());

  /// Whether the net-worth chart shows stacked-by-institution bands
  /// (`true` = detailed). Default is the cleaner single-line view.
  static bool getNetWorthDetailed() => _read('netWorthDetailed') == 'true';
  static void setNetWorthDetailed(bool v) =>
      _write('netWorthDetailed', v.toString());

  /// Optional FIRE / net-worth goal — target amount in USD (the backend
  /// unit) and a target year. Returns null when the user hasn't set one.
  static double? getGoalAmountUsd() {
    final raw = _read('goalAmountUsd');
    return raw == null ? null : double.tryParse(raw);
  }

  static void setGoalAmountUsd(double? v) {
    if (v == null) {
      _write('goalAmountUsd', '');
    } else {
      _write('goalAmountUsd', v.toString());
    }
  }

  static int? getGoalYear() {
    final raw = _read('goalYear');
    return raw == null ? null : int.tryParse(raw);
  }

  static void setGoalYear(int? v) {
    if (v == null) {
      _write('goalYear', '');
    } else {
      _write('goalYear', v.toString());
    }
  }

  /// Theme mode: 'system' / 'light' / 'dark'. Default is 'dark' because
  /// the app's color palette was originally tuned for a dark surface.
  static String getThemeMode() => _read('themeMode') ?? 'dark';
  static void setThemeMode(String mode) => _write('themeMode', mode);

  /// Dismiss state for the "since last login" banner. Keyed on the
  /// previous-login timestamp so dismissing today's banner doesn't
  /// suppress the one that should appear after the next login.
  static bool getSinceLastLoginDismissedFor(String anchorIso) =>
      _read('sinceLastLoginDismissed') == anchorIso;

  static void dismissSinceLastLoginFor(String anchorIso) =>
      _write('sinceLastLoginDismissed', anchorIso);

  /// The anchor a since-last-login dismissal is currently bound to, or
  /// null when the banner isn't dismissed. Used by the "Manage hidden
  /// items" panel to show the user what anchor they suppressed.
  static String? getSinceLastLoginDismissalAnchor() {
    final raw = _read('sinceLastLoginDismissed');
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  /// Clear the since-last-login dismissal so the banner reappears on
  /// the next dashboard refresh.
  static void clearSinceLastLoginDismissal() =>
      _write('sinceLastLoginDismissed', '');

  /// Stable ids of notifications the user has marked as read (the bell-icon
  /// badge only lights for ids NOT in this set). Stored newline-delimited —
  /// notification ids can contain ':' but never a newline. "Mark all read"
  /// replaces the set with exactly the currently-shown ids, so the set stays
  /// bounded and a condition that clears then recurs re-alerts.
  static Set<String> getDismissedNotifications() {
    final raw = _read('dismissed_notifications');
    if (raw == null || raw.isEmpty) return <String>{};
    return raw.split('\n').where((s) => s.isNotEmpty).toSet();
  }

  static void setDismissedNotifications(Set<String> ids) =>
      _write('dismissed_notifications', ids.join('\n'));

  /// Whether the mobile Overview "Details" disclosure (stat strip, goal,
  /// emergency fund) is expanded. Default collapsed for a calm Glance view.
  static bool getOverviewDetailsExpanded() =>
      _read('overviewDetailsExpanded') == 'true';
  static void setOverviewDetailsExpanded(bool v) =>
      _write('overviewDetailsExpanded', v.toString());

  /// Whether the mobile Settings "Connections & sync" disclosure (sync-all
  /// button, sync-status card, FX rate, modules) is expanded. Default
  /// collapsed so the phone Settings view stays focused on data sources.
  static bool getManagementDetailsExpanded() =>
      _read('managementDetailsExpanded') == 'true';
  static void setManagementDetailsExpanded(bool v) =>
      _write('managementDetailsExpanded', v.toString());

  /// Whether the bills calendar shows detector-inferred recurring charges
  /// (`source: "detected"`) alongside explicit rules and loan dues.
  /// **Defaults to ON** — the owner's calendar was near-empty without them —
  /// so an absent/garbage value reads as true and only the literal 'false'
  /// hides them.
  static bool getBillsShowDetected() => _read('billsShowDetected') != 'false';
  static void setBillsShowDetected(bool v) =>
      _write('billsShowDetected', v.toString());

  /// Per-category monthly budgets, stored as a JSON object on the wire:
  /// {"Restaurants": 500.0, "Groceries": 800.0, ...}. Values are in USD
  /// (the backend storage unit); the UI converts for display.
  static Map<String, double> getBudgets() {
    final raw = _read('budgets');
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = raw.startsWith('{') ? raw : '{}';
      // Lightweight parser — we control both ends. Avoids pulling in a
      // dart:convert import just for this since the stored shape is flat.
      final map = <String, double>{};
      final inner = decoded.substring(1, decoded.length - 1);
      if (inner.isEmpty) return const {};
      for (final entry in inner.split(',')) {
        final parts = entry.split(':');
        if (parts.length != 2) continue;
        final key = parts[0].trim().replaceAll('"', '');
        final value = double.tryParse(parts[1].trim());
        if (key.isNotEmpty && value != null) map[key] = value;
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  static void setBudgets(Map<String, double> budgets) {
    if (budgets.isEmpty) {
      _write('budgets', '{}');
      return;
    }
    final parts = budgets.entries
        .map((e) => '"${e.key.replaceAll('"', '')}": ${e.value}')
        .join(', ');
    _write('budgets', '{$parts}');
  }

  /// Per-account low-balance alert thresholds, keyed by account id, in the
  /// account's native currency (same units as current_balance). Same flat-JSON
  /// encoding as budgets (account ids are UUIDs — no `:` / `,`).
  static Map<String, double> getAccountAlerts() {
    final raw = _read('account_balance_alerts');
    if (raw == null || raw.isEmpty || !raw.startsWith('{')) return const {};
    try {
      final map = <String, double>{};
      final inner = raw.substring(1, raw.length - 1);
      if (inner.isEmpty) return const {};
      for (final entry in inner.split(',')) {
        final parts = entry.split(':');
        if (parts.length != 2) continue;
        final key = parts[0].trim().replaceAll('"', '');
        final value = double.tryParse(parts[1].trim());
        if (key.isNotEmpty && value != null) map[key] = value;
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  static void setAccountAlerts(Map<String, double> alerts) {
    if (alerts.isEmpty) {
      _write('account_balance_alerts', '{}');
      return;
    }
    final parts = alerts.entries
        .map((e) => '"${e.key.replaceAll('"', '')}": ${e.value}')
        .join(', ');
    _write('account_balance_alerts', '{$parts}');
  }

  /// Per-account interest rates (account id -> annual APR as a decimal, e.g.
  /// 0.1999), for the debt-payoff simulator. Same flat-JSON encoding.
  static Map<String, double> getAccountAprs() {
    final raw = _read('account_aprs');
    if (raw == null || raw.isEmpty || !raw.startsWith('{')) return const {};
    try {
      final map = <String, double>{};
      final inner = raw.substring(1, raw.length - 1);
      if (inner.isEmpty) return const {};
      for (final entry in inner.split(',')) {
        final parts = entry.split(':');
        if (parts.length != 2) continue;
        final key = parts[0].trim().replaceAll('"', '');
        final value = double.tryParse(parts[1].trim());
        if (key.isNotEmpty && value != null) map[key] = value;
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  static void setAccountAprs(Map<String, double> aprs) {
    if (aprs.isEmpty) {
      _write('account_aprs', '{}');
      return;
    }
    final parts = aprs.entries
        .map((e) => '"${e.key.replaceAll('"', '')}": ${e.value}')
        .join(', ');
    _write('account_aprs', '{$parts}');
  }

  /// Per-account manual card terms (statement balance / minimum payment / due
  /// date), keyed by account id. Same `app_settings` pattern as account_aprs,
  /// but the value is a nested object `{statement_balance, minimum_payment,
  /// due_date}` so this uses jsonDecode/jsonEncode rather than the flat parser.
  static Map<String, dynamic> getCardTerms() {
    final raw = _read('card_terms');
    if (raw == null || raw.isEmpty) return const {};
    try {
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : const {};
    } catch (_) {
      return const {};
    }
  }

  static void setCardTerms(Map<String, dynamic> terms) =>
      _write('card_terms', jsonEncode(terms));
}
