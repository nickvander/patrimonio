import 'package:web/web.dart' as web;

/// Thin wrapper around `window.localStorage` for user preferences that
/// should survive a page refresh — reporting currency, last selected tab,
/// chart date range, the flat-vs-grouped toggle on the portfolio, etc.
///
/// All values are strings on the wire; callers convert via the typed
/// helpers below. Keys are namespaced with `patrimonio:` so we don't
/// collide with other apps if this site is ever served behind a path.
class Preferences {
  static const _prefix = 'patrimonio:';

  static String? _read(String key) {
    try {
      return web.window.localStorage.getItem('$_prefix$key');
    } catch (_) {
      // Private-browsing modes can throw on localStorage reads.
      return null;
    }
  }

  static void _write(String key, String value) {
    try {
      web.window.localStorage.setItem('$_prefix$key', value);
    } catch (_) {/* swallow */}
  }

  // -- Typed accessors ---------------------------------------------------

  /// Reporting currency the user last picked from the app-bar toggle.
  /// Defaults to USD when nothing is stored.
  static String getCurrency() => _read('currency') ?? 'USD';
  static void setCurrency(String code) => _write('currency', code);

  /// Last-active tab index (0..5). Defaults to Overview (0) if unset
  /// or out of range — callers should clamp before using.
  static int getLastTab() {
    final raw = _read('lastTab');
    final n = int.tryParse(raw ?? '');
    return n ?? 0;
  }

  static void setLastTab(int index) => _write('lastTab', index.toString());

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
}
