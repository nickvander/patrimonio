part of '../api_service.dart';

/// Dashboard reads (overview, histories, insights, subscriptions,
/// notifications), the FX center (rates, alerts, transfer links),
/// and account archive/restore + setup status.
///
/// One of the five domain mixins split out of the ApiService
/// god-file — method bodies are byte-identical moves. See
/// `_ApiServiceBase` in api_service.dart for the design.
mixin _DashboardApi on _ApiServiceBase {
  // ----- existing endpoints (now credentialed) -----

  Future<Map<String, dynamic>> getDashboardOverview({
    bool forceRefresh = false,
  }) {
    return _cachedGet('overview', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/overview'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load dashboard overview',
          'No se pudo cargar el resumen del panel',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getNetWorthHistory({bool forceRefresh = false}) {
    return _cachedGet('net-worth-history', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/net-worth-history'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load net worth history',
          'No se pudo cargar el historial de patrimonio neto',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getAllocationData({bool forceRefresh = false}) {
    return _cachedGet('allocation', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/allocation'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load allocation data',
          'No se pudieron cargar los datos de distribución',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Monthly income/spending trends. [months] sets the trailing
  /// calendar-month window (clamped 1..=24 server-side); omit it for the
  /// historical 12-month default. The cache key folds in [months] so the
  /// Cash Flow tab's period selector refetches a tighter window instead of
  /// returning the stale 12-month series.
  Future<List<dynamic>> getTrendData({int? months, bool forceRefresh = false}) {
    final query = months == null ? '' : '?months=$months';
    final cacheKey = months == null ? 'trends' : 'trends-$months';
    return _cachedGet(cacheKey, () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/trends$query'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load trend data',
          'No se pudieron cargar los datos de tendencias',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Per-category spending over the trailing [months] months. Returns the
  /// `{months: [...], categories: [...]}` shape from the backend, with the
  /// top categories kept verbatim and the rest folded into "OTHER".
  Future<Map<String, dynamic>> getSpendingByCategory({
    int months = 6,
    int top = 6,
    bool forceRefresh = false,
  }) {
    return _cachedGet('spending-by-category-$months-$top', () async {
      final response = await _get(
        Uri.parse(
          '$_baseUrl/dashboard/spending-by-category?months=$months&top=$top',
        ),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load spending by category',
          'No se pudo cargar el gasto por categoría',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Per-category month-over-month-vs-trailing-average spend deltas. Returns
  /// the `{recent_month, lookback, categories:[{user_category, category_detailed,
  /// category, recent, previous_avg, trailing_avg}]}` shape. Powers the
  /// spending-insight notifications and the budget auto-suggestions.
  Future<Map<String, dynamic>> getSpendingInsights({
    int lookback = 3,
    bool forceRefresh = false,
  }) {
    return _cachedGet('spending-insights-$lookback', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/spending-insights?lookback=$lookback'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load spending insights',
          'No se pudieron cargar los análisis de gasto',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Investment portfolio value over time: `[{date, value_usd}]` (USD), from
  /// balance snapshots of accounts that hold investments. Powers the
  /// performance chart. Empty list on error so the card simply hides.
  Future<List<dynamic>> getPortfolioValueHistory({bool forceRefresh = false}) {
    return _cachedGet('portfolio-value-history', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/portfolio-value-history'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load portfolio value history',
          'No se pudo cargar el historial de valor del portafolio',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// S&P 500 daily closes (for the net-worth-vs-market overlay). [from] is an
  /// ISO date string. Returns the `{symbol, points:[{date,close}]}` shape;
  /// empty list on any error so the card simply hides.
  Future<Map<String, dynamic>?> getBenchmarkSeries({String? from}) async {
    try {
      final q = from != null ? '?from=$from' : '';
      final r = await _get(Uri.parse('$_baseUrl/dashboard/benchmark$q'));
      if (r.statusCode == 200) {
        final decoded = json.decode(r.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {
      // best-effort; card hides
    }
    return null;
  }

  /// Contribution-weighted "you vs the chosen benchmark" over tracked holding
  /// lots. [benchmark] is the index key (e.g. 'SP500', 'NDX'); omitted →
  /// defaults to the S&P 500 server-side.
  /// Returns {invested_usd, your_value_usd, benchmark_value_usd, lot_count}.
  Future<Map<String, dynamic>?> getBenchmarkComparison({
    String? benchmark,
  }) async {
    try {
      final q = benchmark != null ? '?benchmark=$benchmark' : '';
      final r = await _get(
        Uri.parse('$_baseUrl/dashboard/benchmark-comparison$q'),
      );
      if (r.statusCode == 200) {
        final decoded = json.decode(r.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {}
    return null;
  }

  /// True time-weighted return: daily growth index of the portfolio (cashflows
  /// divided out) + the chosen benchmark over the same dates, plus
  /// `coverage_pct`. [benchmark] is the index key (e.g. 'SP500', 'NDX');
  /// omitted → defaults to the S&P 500 server-side.
  /// Returns the `{start_date, end_date, coverage_pct, your_twr, sp_twr,
  /// points:[{date, twr, sp}], ...}` shape; null on any error so the card
  /// falls back to the dollar-value line.
  Future<Map<String, dynamic>?> getPortfolioTwr({String? benchmark}) async {
    try {
      final q = benchmark != null ? '?benchmark=$benchmark' : '';
      final r = await _get(Uri.parse('$_baseUrl/dashboard/portfolio-twr$q'));
      if (r.statusCode == 200) {
        final decoded = json.decode(r.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {}
    return null;
  }

  /// Emergency-fund runway: liquid cash / trailing monthly spend (USD).
  Future<Map<String, dynamic>> getEmergencyFund({bool forceRefresh = false}) {
    return _cachedGet('emergency-fund', () async {
      final r = await _get(Uri.parse('$_baseUrl/dashboard/emergency-fund'));
      if (r.statusCode == 200) {
        return json.decode(r.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load emergency fund',
          'No se pudo cargar el fondo de emergencia',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Monthly closing balances for one account (native currency), derived from
  /// the persisted statement `balance_after`. Empty for Plaid-only accounts.
  Future<List<dynamic>> getAccountBalanceHistory(String accountId) async {
    try {
      final response = await _get(
        Uri.parse(
          '$_baseUrl/dashboard/account-balance-history?account_id=$accountId',
        ),
      );
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        return decoded is List ? decoded : const [];
      }
    } catch (_) {
      // Best-effort; the chart simply won't render.
    }
    return const [];
  }

  /// Realized capital gains/losses from lot disposals. Optional [year]
  /// narrows the disposal list; the summary + by-year always cover history.
  Future<Map<String, dynamic>> getRealizedGains({
    int? year,
    bool forceRefresh = false,
  }) {
    return _cachedGet('realized-gains-${year ?? 'all'}', () async {
      final q = year != null ? '?year=$year' : '';
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/realized-gains$q'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load realized gains',
          'No se pudieron cargar las ganancias realizadas',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  Future<Map<String, dynamic>> getHoldings({bool forceRefresh = false}) {
    return _cachedGet('holdings', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/holdings'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t('Failed to load holdings', 'No se pudieron cargar las posiciones'),
      );
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getCreditUtilization({bool forceRefresh = false}) {
    return _cachedGet('credit-utilization', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/credit-utilization'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load credit utilization',
          'No se pudo cargar el uso de crédito',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getSyncStatus({bool forceRefresh = false}) {
    return _cachedGet('sync-status', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/sync-status'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load sync status',
          'No se pudo cargar el estado de sincronización',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Summary of "what changed since your previous login" — used by the
  /// dismissible Overview banner. Returns null when the user has no
  /// previous login (first session ever), so the caller can skip rendering.
  Future<Map<String, dynamic>?> getSinceLastLogin({bool forceRefresh = false}) {
    return _cachedGet('since-last-login', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/since-last-login'),
      );
      if (response.statusCode != 200) return null;
      final body = json.decode(response.body) as Map<String, dynamic>;
      // Backend signals "no previous login" by omitting `previous_login_at`.
      if (body['previous_login_at'] == null) return null;
      return body;
    }, forceRefresh: forceRefresh);
  }

  /// Unified notifications inbox for the bell: every stored
  /// `user_notifications` row (FX alerts, import staleness, loan due
  /// reminders — generated server-side on read) plus the true unread
  /// count for the badge. Shape:
  /// `{notifications: [{id, kind, title, body, created_at, read_at,
  /// link_kind, link_id}], unread_count}`.
  Future<Map<String, dynamic>?> getNotifications({bool forceRefresh = false}) {
    return _cachedGet('notifications', () async {
      final response = await _get(Uri.parse('$_baseUrl/notifications'));
      if (response.statusCode != 200) return null;
      return json.decode(response.body) as Map<String, dynamic>;
    }, forceRefresh: forceRefresh);
  }

  /// Server-side read state: mark specific inbox ids — or with [all],
  /// the whole inbox — as read. Fire-and-forget friendly: callers that
  /// only care about the optimistic local state can ignore the result.
  Future<void> markNotificationsRead({
    List<String> ids = const [],
    bool all = false,
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/notifications/read'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'ids': ids, 'all': all}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to update notifications',
          'No se pudieron actualizar las notificaciones',
        ),
      );
    }
  }

  /// List every dismissed subscription merchant. Returned shape:
  /// `[{merchant_key, ignored_at}, ...]`.
  Future<List<dynamic>> getIgnoredSubscriptions({bool forceRefresh = false}) {
    return _cachedGet('subscriptions/ignored', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/subscriptions/ignored'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load ignored subscriptions',
          'No se pudieron cargar las suscripciones ignoradas',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Un-ignore: lets the detector resurface this merchant on the
  /// next run. Idempotent — 204 either way.
  Future<void> unignoreSubscription(String merchantKey) async {
    final response = await _delete(
      Uri.parse(
        '$_baseUrl/dashboard/subscriptions/ignored/${Uri.encodeComponent(merchantKey)}',
      ),
    );
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Failed to un-ignore subscription',
          'No se pudo dejar de ignorar la suscripción',
        ),
      );
    }
  }

  /// Mark a detected subscription cluster as "not actually a
  /// subscription" — the detector skips this merchant on future runs.
  Future<void> ignoreSubscription(String merchant) async {
    final response = await _post(
      Uri.parse('$_baseUrl/dashboard/subscriptions/ignore'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'merchant': merchant}),
    );
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Failed to dismiss subscription',
          'No se pudo descartar la suscripción',
        ),
      );
    }
  }

  /// Detected recurring outflows (subscriptions, bills, gym, etc.).
  /// See `dashboard.rs::detected_subscriptions` for the heuristic.
  Future<List<dynamic>> getSubscriptions({bool forceRefresh = false}) {
    return _cachedGet('subscriptions', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/subscriptions'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load subscriptions',
          'No se pudieron cargar las suscripciones',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Linked cross-currency cash transfers. Each row pairs a USD-out
  /// with an MXN-in (or reverse) plus the implied FX rate Wise/Remitly
  /// gave the user.
  Future<List<dynamic>> getFxTransfers({bool forceRefresh = false}) {
    return _cachedGet('fx-transfers', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/fx-transfers'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load FX transfers',
          'No se pudieron cargar las transferencias de divisas',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Run a detection pass on the server. Returns
  /// `{checked, inserted}` so the UI can say "added N new links".
  Future<Map<String, dynamic>> detectFxTransfers() async {
    final response = await _post(Uri.parse('$_baseUrl/dashboard/fx-transfers'));
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'FX detection failed',
        'No se pudo detectar transferencias de divisas',
      ),
    );
  }

  Future<void> confirmFxTransfer(String id) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/$id'),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Confirm failed (${response.statusCode})',
          'No se pudo confirmar (${response.statusCode})',
        ),
      );
    }
  }

  Future<void> unlinkFxTransfer(String id) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/$id'),
    );
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Unlink failed (${response.statusCode})',
          'No se pudo desvincular (${response.statusCode})',
        ),
      );
    }
  }

  /// List FX pairs the user has permanently dismissed. Each row is
  /// `{ id, source_label, dest_label, source_date, dest_date,
  /// source_amount, source_currency, dest_amount, dest_currency,
  /// dismissed_at }`. Used by the Hidden Items screen.
  Future<List<dynamic>> getDismissedFxPairs() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/dismissed'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load dismissed FX pairs',
        'No se pudieron cargar los pares de divisas descartados',
      ),
    );
  }

  /// Restore a dismissed FX pair so the detector can re-propose it
  /// on the next run. Idempotent — 204 even if already gone.
  Future<void> restoreDismissedFxPair(String dismissalId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/dismissed/$dismissalId'),
    );
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Restore failed (${response.statusCode})',
          'No se pudo restaurar (${response.statusCode})',
        ),
      );
    }
  }

  /// Accounts the backend auto-archived because they were closed/removed
  /// at the bank (e.g. a deleted SoFi vault). Surfaced in the
  /// "Closed accounts" management section so the user can restore them.
  /// Not cached — the list is small and we want it fresh on open.
  Future<List<dynamic>> getArchivedAccounts() async {
    final response = await _get(Uri.parse('$_baseUrl/accounts/archived'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load closed accounts',
        'No se pudieron cargar las cuentas cerradas',
      ),
    );
  }

  /// Restore an auto-archived account so it counts toward net worth again.
  Future<void> restoreAccount(String accountId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/restore'),
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception(
        _t('Failed to restore account', 'No se pudo restaurar la cuenta'),
      );
    }
  }

  Future<Map<String, dynamic>> getSetupStatus() async {
    // Setup status is a public endpoint — used by the login screen — so
    // we still send credentials but the server does not require them.
    final response = await _client.get(Uri.parse('$_baseUrl/setup/status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load setup status',
        'No se pudo cargar el estado de configuración',
      ),
    );
  }

  Future<Map<String, dynamic>> getExchangeRate(
    String base,
    String target, {
    bool force = false,
  }) async {
    final query = force ? '?force=true' : '';
    final response = await _get(
      Uri.parse('$_baseUrl/fx/latest/$base/$target$query'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t('Failed to load exchange rate', 'No se pudo cargar el tipo de cambio'),
    );
  }

  /// Record a user-entered FX override (source='manual'), which the backend
  /// prefers over the automated open.er-api.com rows. Returns the stored rate.
  Future<Map<String, dynamic>> postManualExchangeRate({
    required String base,
    required String target,
    required double rate,
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/fx/manual'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'base': base, 'target': target, 'rate': rate}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to save exchange rate',
        'No se pudo guardar el tipo de cambio',
      ),
    );
  }

  /// Historical rate points for the FX center sparkline. [days] windows
  /// the series server-side (30/90 in the UI) so the payload stays small.
  Future<List<dynamic>> getExchangeRateHistory(
    String base,
    String target, {
    int days = 90,
  }) async {
    final response = await _get(
      Uri.parse('$_baseUrl/fx/history/$base/$target?days=$days'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw _errorFromBody(
      response,
      fallback: _t(
        'Failed to load rate history',
        'No se pudo cargar el historial del tipo de cambio',
      ),
    );
  }

  /// The caller's FX alert threshold for the pair, or null when none is
  /// configured (server returns an explicit `{"alert": null}`).
  Future<Map<String, dynamic>?> getFxAlert(String base, String target) async {
    final response = await _get(Uri.parse('$_baseUrl/fx/alert/$base/$target'));
    if (response.statusCode == 200) {
      final body = json.decode(response.body);
      return (body is Map && body['alert'] is Map)
          ? Map<String, dynamic>.from(body['alert'] as Map)
          : null;
    }
    throw _errorFromBody(
      response,
      fallback: _t(
        'Failed to load FX alert',
        'No se pudo cargar la alerta de tipo de cambio',
      ),
    );
  }

  /// Upserts the caller's FX alert threshold ("notify me when the rate
  /// crosses X"); returns the stored alert.
  Future<Map<String, dynamic>> putFxAlert({
    required String base,
    required String target,
    required double threshold,
  }) async {
    final response = await _put(
      Uri.parse('$_baseUrl/fx/alert/$base/$target'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'threshold': threshold}),
    );
    if (response.statusCode == 200) {
      final body = json.decode(response.body);
      return Map<String, dynamic>.from(body['alert'] as Map);
    }
    throw _errorFromBody(
      response,
      fallback: _t(
        'Failed to save FX alert',
        'No se pudo guardar la alerta de tipo de cambio',
      ),
    );
  }

  /// Printable household continuity dossier (bilingual HTML → browser
  /// print-to-PDF, like the loan agreement / FBAR worksheet). Opened in
  /// a browser tab so cookie auth rides along.
  String continuityDossierUrl({required String lang}) =>
      '$_baseUrl/exports/continuity-dossier?lang=$lang';

  /// Removes the caller's FX alert for the pair. Idempotent server-side.
  Future<void> deleteFxAlert(String base, String target) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/fx/alert/$base/$target'),
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to remove FX alert',
          'No se pudo eliminar la alerta de tipo de cambio',
        ),
      );
    }
  }
}
