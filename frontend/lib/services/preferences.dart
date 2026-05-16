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
}
