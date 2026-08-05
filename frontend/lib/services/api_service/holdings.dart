part of '../api_service.dart';

/// The "Manual holdings" fence: ticker/quantity holdings CRUD and
/// pricing, dividend + instrument detail, and the tail the fence
/// accreted — wealth projections, tax reads, per-institution sync,
/// and the generic settings store.
///
/// One of the five domain mixins split out of the ApiService
/// god-file — method bodies are byte-identical moves, kept in the
/// fence's original order. See `_ApiServiceBase` in
/// api_service.dart for the design.
mixin _HoldingsApi on _ApiServiceBase {
  // --- Manual holdings (ticker + share quantity, live-priced) ---------------

  Future<List<dynamic>> getAccountHoldings(String accountId) async {
    final res = await _get(Uri.parse('$_baseUrl/accounts/$accountId/holdings'));
    if (res.statusCode != 200) return const [];
    final body = json.decode(res.body);
    return body is List ? body : const [];
  }

  Future<Map<String, dynamic>> createHolding(
    String accountId, {
    required String symbol,
    required double quantity,
    String? name,
    double? costBasis,
  }) async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'symbol': symbol,
        'quantity': quantity,
        if (name != null && name.isNotEmpty) 'name': name,
        'cost_basis': ?costBasis,
      }),
    );
    if (res.statusCode != 201) {
      throw Exception(
        _t(
          'Failed to add holding: ${res.body}',
          'No se pudo agregar la posición: ${res.body}',
        ),
      );
    }
    return json.decode(res.body) as Map<String, dynamic>;
  }

  Future<void> deleteHolding(String accountId, String holdingId) async {
    final res = await _delete(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/$holdingId'),
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception(
        _t('Failed to remove holding', 'No se pudo eliminar la posición'),
      );
    }
  }

  Future<List<dynamic>> refreshHoldings(String accountId) async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/refresh'),
      headers: _withCsrf({}),
    );
    if (res.statusCode != 200) return const [];
    final body = json.decode(res.body);
    return body is List ? body : const [];
  }

  /// Re-price every manual stock holding the user has (across all manual
  /// accounts) from the live quote cache. Returns counts; best-effort.
  Future<Map<String, dynamic>> refreshAllStockPrices() async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/holdings/refresh-all'),
      headers: _withCsrf({}),
    );
    if (res.statusCode != 200) return const {};
    final body = json.decode(res.body);
    return body is Map<String, dynamic> ? body : const {};
  }

  /// Per-holding dividend info (annual rate, yield, est. next ex-date,
  /// projected annual income). Best-effort — empty on failure.
  Future<List<dynamic>> getHoldingsDividends(String accountId) async {
    final res = await _get(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/dividends'),
    );
    if (res.statusCode != 200) return const [];
    final body = json.decode(res.body);
    return body is List ? body : const [];
  }

  /// Portfolio-wide dividend income aggregated across every active account:
  /// projected annual income (USD), blended yield-on-value, per-symbol
  /// contributions, and the soonest estimated ex-dates. Best-effort — null on
  /// failure so the card can simply hide.
  Future<Map<String, dynamic>?> getPortfolioDividends() async {
    try {
      final res = await _get(
        Uri.parse('$_baseUrl/dashboard/holdings/dividends'),
      );
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {}
    return null;
  }

  /// Per-symbol dividend detail for the click-through sheet: aggregates
  /// (rate, frequency, income, yields), per-account quantities, the parsed
  /// ~2y payment history, and a next-12-months schedule projection. Throws
  /// on failure so the sheet can render its own error + retry state.
  ///
  /// [refresh] appends `?refresh=true` (contract C4-D), telling the server
  /// to bypass its fresh-cache window and re-fetch live — for when the owner
  /// knows a dividend just changed. No client-side cache interaction: this
  /// call is uncached by design either way.
  Future<Map<String, dynamic>> getDividendDetail(
    String symbol, {
    bool refresh = false,
  }) async {
    final response = await _get(
      Uri.parse(
        '$_baseUrl/dashboard/dividends/${Uri.encodeComponent(symbol)}'
        '${refresh ? '?refresh=true' : ''}',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'Failed to load dividend detail',
        'No se pudo cargar el detalle de dividendos',
      ),
    );
  }

  /// Per-holding instrument detail for the click-through sheet (contract
  /// C-A): position aggregates (value, basis, gain, weight, day change),
  /// per-account quantities, purchase lots, and the stored daily-close
  /// series for the requested range (`1m|3m|1y|max`). Uncached — this is
  /// an always-fresh detail view, like the dividend detail. Throws a
  /// localized error on non-200 so the sheet owns its error + retry state.
  Future<Map<String, dynamic>> getInstrumentDetail(
    String symbol, {
    String range = '1y',
  }) async {
    final response = await _get(
      Uri.parse(
        '$_baseUrl/dashboard/instruments/${Uri.encodeComponent(symbol)}'
        '?range=${Uri.encodeComponent(range)}',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'Failed to load instrument detail',
        'No se pudo cargar el detalle del instrumento',
      ),
    );
  }

  /// Sets (or, with [assetClass] == null, clears) the user's per-symbol
  /// asset-class override (contracts C3-A / C3-E). Returns the server's
  /// authoritative `{symbol, asset_class, asset_class_source}` — after a
  /// clear, `asset_class` is the heuristic result. Throws a localized error
  /// on non-200 (same convention as [getInstrumentDetail]).
  ///
  /// Cache invalidation (C3-E): going through [_put] means a successful call
  /// clears the whole `dash:` cache family via [_invalidateAfterMutation] —
  /// `holdings`, `realized-gains-*`, and `allocation` included — so the next
  /// dashboard read is fresh even without `forceRefresh`.
  Future<Map<String, dynamic>> setAssetClassOverride(
    String symbol,
    String? assetClass,
  ) async {
    final res = await _put(
      Uri.parse(
        '$_baseUrl/dashboard/instruments/'
        '${Uri.encodeComponent(symbol)}/asset-class',
      ),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      // json.encode keeps the explicit `"asset_class": null` clear-payload.
      body: json.encode({'asset_class': assetClass}),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'Failed to update asset class',
        'No se pudo actualizar la clase de activo',
      ),
    );
  }

  /// Un-deletes a soft-deleted holding inside the undo window (contracts
  /// C3-B / C3-E). 200 → the restored holding row (create-holding readback
  /// shape). 404 → the ghost is already purged: throws the typed
  /// [HoldingRestoreGoneException] so the undo snackbar can say "permanent"
  /// instead of a generic failure. Any other non-200 throws a localized
  /// error. Successful calls invalidate the dashboard cache via [_post]'s
  /// [_invalidateAfterMutation], same as [deleteHolding] via [_delete].
  Future<Map<String, dynamic>> restoreHolding(
    String accountId,
    String holdingId,
  ) async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/$holdingId/restore'),
      headers: _withCsrf({}),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    if (res.statusCode == 404) {
      throw HoldingRestoreGoneException(
        _t('Nothing to restore', 'No hay nada que restaurar'),
      );
    }
    throw Exception(
      _t('Failed to restore holding', 'No se pudo restaurar la posición'),
    );
  }

  Future<Map<String, dynamic>> getWealthProjection({
    required double startBalance,
    required double monthlyContribution,
    required double annualReturnRate,
    required double annualExpenses,
    required double withdrawalRate,
    int years = 30,
    double annualInflationRate = 0.03,
    double returnVolatility = 0.13,
    int? yearsToRetirement,
    int monteCarloTrials = 1000,
    double baristaMonthlyIncome = 0.0,
    double annualTaxDrag = 0.0,
    bool withdrawalGuardrails = false,
    bool mxScenario = false,
    double expensesUsdPortion = 0.0,
    double expensesMxnPortion = 0.0,
    double fxAnnualDrift = 0.0,
    double? usdMxnRate,
  }) async {
    final queryParams = {
      'start_balance': startBalance.toString(),
      'monthly_contribution': monthlyContribution.toString(),
      'annual_return_rate': annualReturnRate.toString(),
      'annual_expenses': annualExpenses.toString(),
      'withdrawal_rate': withdrawalRate.toString(),
      'years': years.toString(),
      'annual_inflation_rate': annualInflationRate.toString(),
      'return_volatility': returnVolatility.toString(),
      'monte_carlo_trials': monteCarloTrials.toString(),
      'barista_monthly_income': baristaMonthlyIncome.toString(),
      'annual_tax_drag': annualTaxDrag.toString(),
      'withdrawal_guardrails': withdrawalGuardrails.toString(),
      if (yearsToRetirement != null)
        'years_to_retirement': yearsToRetirement.toString(),
      // "Retire in Mexico" scenario. Appended only when the toggle is on so
      // the canonical param string — and therefore the derived mc_seed —
      // stays byte-identical for every pre-existing request.
      if (mxScenario) ...{
        'mx_scenario': 'true',
        'annual_expenses_usd_portion': expensesUsdPortion.toString(),
        'annual_expenses_mxn_portion': expensesMxnPortion.toString(),
        'fx_annual_drift': fxAnnualDrift.toString(),
        // Send the live rate the UI already displays so the backend's
        // scenario math matches the FX pill; omitted → the backend uses its
        // latest stored rate.
        if (usdMxnRate != null && usdMxnRate > 0)
          'usd_mxn_rate': usdMxnRate.toString(),
      },
    };

    // F4: deterministic Monte Carlo — a stable seed derived from the
    // canonical parameter string, so identical inputs always return the
    // identical fan (map literals preserve insertion order, making the
    // joined string canonical).
    queryParams['mc_seed'] = projectionSeed(
      queryParams.entries.map((e) => '${e.key}=${e.value}').join('&'),
    ).toString();

    final uri = Uri.parse(
      '$_baseUrl/projections/calculate',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load wealth projection',
        'No se pudo cargar la proyección de patrimonio',
      ),
    );
  }

  /// Projection inputs derived from the user's tracked cash flow (USD).
  /// Returns null on any error so the screen falls back to static defaults.
  Future<Map<String, dynamic>?> getProjectionDefaults() async {
    try {
      final response = await _get(Uri.parse('$_baseUrl/projections/defaults'));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {
      // Best-effort prefill; the screen has sensible static defaults.
    }
    return null;
  }

  Future<void> linkCryptoInstitution({
    required String name,
    required String integrationType,
    required String apiKey,
    required String apiSecret,
    String? apiPass,
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/crypto'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'name': name,
        'integration_type': integrationType,
        'api_key': apiKey,
        'api_secret': apiSecret,
        'api_pass': apiPass,
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to link crypto: ${response.body}',
          'No se pudo vincular el exchange de cripto: ${response.body}',
        ),
      );
    }
  }

  Future<Map<String, dynamic>> getTaxSummary({
    int? year,
    String? status,
  }) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();
    if (status != null) queryParams['status'] = status;

    final uri = Uri.parse(
      '$_baseUrl/tax/summary',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t('Failed to load tax summary', 'No se pudo cargar el resumen fiscal'),
    );
  }

  Future<List<dynamic>> getTaxTransactions({int? year}) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();

    final uri = Uri.parse(
      '$_baseUrl/tax/transactions',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load tax transactions',
        'No se pudieron cargar los movimientos fiscales',
      ),
    );
  }

  /// Realized capital-gains disposals (Form 8949-style detail) behind the
  /// summary's ST/LT figures, newest sell date first. Each row carries its
  /// `tax_advantaged` flag so the screen can split or badge wrapper-account
  /// disposals separately. Returns the raw decoded JSON list.
  Future<List<dynamic>> getTaxDisposals(int year) async {
    final uri = Uri.parse(
      '$_baseUrl/tax/disposals',
    ).replace(queryParameters: {'year': year.toString()});
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load realized gains',
        'No se pudieron cargar las ganancias realizadas',
      ),
    );
  }

  /// Unrealized per-lot "what if I sell" view for taxable accounts (T11):
  /// per-lot signed USD gain/loss, short/long-term term with
  /// `days_until_long_term`, and loss-harvest candidates carrying an
  /// `estimated_tax_savings_usd` and a forward-looking `wash_sale_risk` guard.
  /// The savings and marginal rates ride the UNVERIFIED constant tables, so
  /// the response's `constants_verified` flag must gate how authoritative the
  /// figures are shown. `status` is optional; the backend falls back to the
  /// persisted filing status. Returns the raw decoded JSON map (`lots` plus
  /// ST/LT subtotals, marginal rates, and the verification context).
  Future<Map<String, dynamic>> getUnrealizedLots({
    int? year,
    String? status,
  }) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();
    if (status != null) queryParams['status'] = status;

    final uri = Uri.parse(
      '$_baseUrl/tax/unrealized',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load unrealized positions',
        'No se pudieron cargar las posiciones no realizadas',
      ),
    );
  }

  /// FBAR/FATCA threshold monitor for a year (T13): the peak aggregate USD
  /// balance across foreign accounts, the $10,000 threshold, an `exceeded`
  /// flag, the peak date, and the foreign accounts involved. Informational
  /// only — the `constants_verified` flag gates how authoritative the
  /// threshold copy is shown. Returns the raw decoded JSON map.
  Future<Map<String, dynamic>> getFbarStatus(int year) async {
    final uri = Uri.parse(
      '$_baseUrl/tax/fbar',
    ).replace(queryParameters: {'year': year.toString()});
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t('Failed to load FBAR status', 'No se pudo cargar el estado FBAR'),
    );
  }

  /// YTD retirement contributions vs annual limits (T15): per account-type
  /// group (401k, IRA, HSA), the YTD contributions, the year's base limit +
  /// catch-up, remaining room, the contribution deadline, and a
  /// `match_rollover_caveat` flag. Limits ride the UNVERIFIED constant tables,
  /// so the response's `constants_verified` flag must gate how authoritative
  /// the figures are shown. Returns the raw decoded JSON map.
  Future<Map<String, dynamic>> getRetirementContributions(int year) async {
    final uri = Uri.parse(
      '$_baseUrl/tax/contributions',
    ).replace(queryParameters: {'year': year.toString()});
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load retirement contributions',
        'No se pudieron cargar las aportaciones de retiro',
      ),
    );
  }

  /// Sync a single institution. Cheaper than the global sync when only
  /// one or two institutions are stuck.
  Future<void> syncInstitution(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/$institutionId/sync'),
    );
    // 202 = accepted (detached sync started); 200 = older synchronous backend.
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception(
        _t(
          'Sync failed: ${response.statusCode}',
          'La sincronización falló: ${response.statusCode}',
        ),
      );
    }
  }

  /// Full-history re-pull for ONE Plaid institution. The backend clears the
  /// item's `/transactions/sync` cursor and then runs the same detached sync
  /// [syncInstitution] triggers, so Plaid replays everything it currently
  /// holds for the item as `added` — recovering any row the incremental
  /// cursor never delivered.
  ///
  /// Returns as soon as the backend accepts (202); the re-pull runs detached
  /// like every other sync trigger, and progress/completion are watched
  /// through [getSyncStatus] — there is no second progress channel.
  ///
  /// Errors carry a server `{"error": ...}` message worth showing verbatim:
  /// 400 for a manual/CSV institution (which has no Plaid cursor to clear)
  /// and 404 for an unknown or foreign id. Hence [_errorFromBody] rather
  /// than a flat status-code `Exception` — "Full re-pull is only available
  /// for Plaid institutions" tells the user what to do; "failed: 400" does not.
  Future<void> resyncInstitutionFullHistory(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/$institutionId/resync'),
    );
    // 202 = accepted (cursor cleared, detached re-pull started).
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw _errorFromBody(
        response,
        fallback: _t(
          'Full re-check failed: ${response.statusCode}',
          'La consulta completa falló: ${response.statusCode}',
        ),
      );
    }
  }

  /// Push the currently-configured PLAID_WEBHOOK_URL onto every Plaid
  /// item the caller owns via Plaid's /item/webhook/update. Used after
  /// the operator first sets the env var on a deployment that already
  /// has linked items — Plaid binds the webhook URL at link-time, so
  /// pre-existing items keep polling forever unless either re-linked
  /// or pointed at the new URL via this endpoint.
  ///
  /// Returns `{ "updated": int, "failed": int, "webhook_url": str,
  /// "results": [{ "id", "name", "ok", "reason"? }] }`.
  Future<Map<String, dynamic>> updateWebhooks() async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/update-webhook'),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Update webhook failed (${response.statusCode}): ${response.body}',
          'No se pudo actualizar el webhook (${response.statusCode}): ${response.body}',
        ),
      );
    }
    return json.decode(response.body);
  }

  /// Sync an arbitrary set of institutions in one round-trip. Replaces
  /// the client-side loop the "Retry N failed" shortcut used to do.
  Future<void> syncInstitutionsBatch(List<String> institutionIds) async {
    // An empty batch matches zero rows server-side (a silent no-op) — don't
    // fire it.
    if (institutionIds.isEmpty) return;
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/sync'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'ids': institutionIds}),
    );
    // 202 = accepted (detached sync started); 200 = older synchronous backend.
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception(
        _t(
          'Batched sync failed: ${response.statusCode}',
          'La sincronización en lote falló: ${response.statusCode}',
        ),
      );
    }
  }

  /// Generic app-setting store. The backend returns JSON null when the
  /// key has never been written; callers should treat that as "absent".
  Future<dynamic> getSetting(String key) async {
    final response = await _get(Uri.parse('$_baseUrl/settings/$key'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to load setting $key',
        'No se pudo cargar la configuración $key',
      ),
    );
  }

  Future<void> putSetting(String key, dynamic value) async {
    final response = await _put(
      Uri.parse('$_baseUrl/settings/$key'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(value),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to save setting $key (${response.statusCode})',
          'No se pudo guardar la configuración $key (${response.statusCode})',
        ),
      );
    }
  }
}
