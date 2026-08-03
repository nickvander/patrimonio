part of '../api_service.dart';

/// Personal lending: loans CRUD, schedules, disbursement and
/// repayment reconciliation, reminders, and the interest-income
/// report/CSV/print URLs.
///
/// One of the five domain mixins split out of the ApiService
/// god-file — method bodies are byte-identical moves. See
/// `_ApiServiceBase` in api_service.dart for the design.
mixin _LendingApi on _ApiServiceBase {
  // ---------- Personal lending ----------

  Future<List<dynamic>> getLoans() async {
    // No trailing slash: axum 0.8 nest("/api/loans") + inner "/" route
    // matches /api/loans but NOT /api/loans/ (the latter 404s).
    final response = await _get(Uri.parse('$_baseUrl/loans'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(
      _t('Failed to load loans', 'No se pudieron cargar los préstamos'),
    );
  }

  Future<Map<String, dynamic>> getLoansSummary({bool forceRefresh = false}) {
    return _cachedGet('loans/summary', () async {
      final response = await _get(Uri.parse('$_baseUrl/loans/summary'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load loans summary',
          'No se pudo cargar el resumen de préstamos',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getLoanPeople() async {
    final response = await _get(Uri.parse('$_baseUrl/loans/people'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(
      _t('Failed to load people', 'No se pudieron cargar las personas'),
    );
  }

  Future<Map<String, dynamic>> createLoan({
    required String borrowerName,
    required double principal,
    required String currency,
    required DateTime originationDate,
    double interestRate = 0,
    String interestType = 'none',
    String ratePeriod = 'annual',
    int? termMonths,
    String? paymentFrequency,
    String? notes,
    String? personId,
    DateTime? expectedRepaymentDate,
  }) async {
    final body = <String, dynamic>{
      'borrower_name': borrowerName,
      'principal': principal,
      'currency': currency,
      'origination_date': _isoDate(originationDate),
      'interest_rate': interestRate,
      'interest_type': interestType,
      'rate_period': ratePeriod,
      'term_months': ?termMonths,
      'payment_frequency': ?paymentFrequency,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      'person_id': ?personId,
      if (expectedRepaymentDate != null)
        'expected_repayment_date': _isoDate(expectedRepaymentDate),
    };
    final response = await _post(
      // No trailing slash — see getLoans (axum nest routing).
      Uri.parse('$_baseUrl/loans'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'Failed to create loan (${response.statusCode})',
        'No se pudo crear el préstamo (${response.statusCode})',
      ),
    );
  }

  /// Patch a loan. The status-only call sites pass `{'status': ...}`
  /// positionally; the edit dialog passes the full editable field set
  /// (borrower_name / principal / interest_rate / interest_type / notes)
  /// in [changes], and may additionally set any of the optional named
  /// params, which are merged into the body when non-null (taking
  /// precedence over the same key in [changes]). interest_rate must
  /// already be a fraction (percent ÷ 100), mirroring createLoan.
  ///
  /// A parallel backend change may now regenerate the schedule when
  /// principal/rate/interest_type change and reject term changes on a
  /// reconciled loan with 409 — surfaced here as [LoanTermsLockedException]
  /// so the caller can show the server's message instead of crashing.
  Future<void> updateLoan(
    String id,
    Map<String, dynamic> changes, {
    String? borrowerName,
    double? principal,
    double? interestRate,
    String? interestType,
    String? notes,
    DateTime? expectedRepaymentDate,
  }) async {
    final body = <String, dynamic>{
      ...changes,
      'borrower_name': ?borrowerName,
      'principal': ?principal,
      'interest_rate': ?interestRate,
      'interest_type': ?interestType,
      'notes': ?notes,
      if (expectedRepaymentDate != null)
        'expected_repayment_date': _isoDate(expectedRepaymentDate),
    };
    final response = await _patch(
      Uri.parse('$_baseUrl/loans/$id'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 409) {
      throw LoanTermsLockedException(_loanErrorText(response));
    }
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to update loan (${response.statusCode})',
          'No se pudo actualizar el préstamo (${response.statusCode})',
        ),
      );
    }
  }

  /// Pull a human-readable message out of a loan error response: the
  /// backend returns either a bare string body or a `{error: "..."}`
  /// JSON object depending on the path. Falls back to a generic message.
  String _loanErrorText(http.Response res) {
    final body = res.body.trim();
    if (body.isEmpty) {
      return _t(
        'This change isn\'t allowed.',
        'Este cambio no está permitido.',
      );
    }
    try {
      final decoded = json.decode(body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Not JSON — the backend often returns a plain-text reason.
    }
    return body;
  }

  Future<void> deleteLoan(String id) async {
    final response = await _delete(Uri.parse('$_baseUrl/loans/$id'));
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Failed to delete loan (${response.statusCode})',
          'No se pudo eliminar el préstamo (${response.statusCode})',
        ),
      );
    }
  }

  Future<List<dynamic>> getLoanPayments(String loanId) async {
    final response = await _get(Uri.parse('$_baseUrl/loans/$loanId/payments'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(
      _t(
        'Failed to load loan payments',
        'No se pudieron cargar los pagos del préstamo',
      ),
    );
  }

  /// Replace a loan's payment schedule with an explicit, irregular set of
  /// installments (used by the "Custom schedule" loan style). Each row is
  /// `{"due_date": "YYYY-MM-DD", "amount": <double>}`. The backend recomputes
  /// the running balance; the sum of amounts should equal the principal for
  /// the balance to close to 0. Surfaces the server's message on non-2xx.
  Future<void> setCustomSchedule(
    String loanId,
    List<Map<String, dynamic>> rows,
  ) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/schedule/custom'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'rows': rows}),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception(
        response.body.isNotEmpty
            ? response.body
            : _t(
                'Failed to save custom schedule (${response.statusCode})',
                'No se pudo guardar el calendario personalizado (${response.statusCode})',
              ),
      );
    }
  }

  Future<void> linkDisbursement(String loanId, String transactionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/disbursement'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'transaction_id': transactionId}),
    );
    if (response.statusCode == 409) {
      // The tx already funds another loan — let the caller roll back.
      throw DisbursementConflictException(_loanErrorText(response));
    }
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to link disbursement (${response.statusCode})',
          'No se pudo vincular el desembolso (${response.statusCode})',
        ),
      );
    }
  }

  /// Record a repayment. Pass [transactionId] to designate a bank inflow,
  /// or omit it for a cash/off-bank payment (then [amount] is required).
  /// [paidDate] is an ISO yyyy-MM-dd string; defaults server-side to the
  /// tx date (linked) or today (cash).
  Future<void> recordRepayment(
    String loanId, {
    String? transactionId,
    double? amount,
    String? paidDate,
  }) async {
    final body = <String, dynamic>{};
    if (transactionId != null) body['transaction_id'] = transactionId;
    if (amount != null) body['amount'] = amount;
    if (paidDate != null) body['paid_date'] = paidDate;
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/payments'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 201) {
      throw Exception(
        response.body.isNotEmpty
            ? response.body
            : _t(
                'Failed to record repayment (${response.statusCode})',
                'No se pudo registrar el pago (${response.statusCode})',
              ),
      );
    }
  }

  /// Attach a real bank inflow to an installment already paid OFF-BANK
  /// (recorded amount, no linked tx). Upgrades that same row in place —
  /// keeps its recorded amount/split and only sets actual_tx_id + date, so
  /// the deposit is excluded from cash flow without double-counting.
  /// Surfaces the server's message on 409 (e.g. the tx already links to
  /// another payment).
  Future<void> attachTransactionToPayment(
    String loanId,
    String paymentId,
    String transactionId,
  ) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/payments/$paymentId/attach-tx'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'transaction_id': transactionId}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        response.body.isNotEmpty
            ? response.body
            : _t(
                'Failed to link bank transaction (${response.statusCode})',
                'No se pudo vincular la transacción bancaria (${response.statusCode})',
              ),
      );
    }
  }

  /// (Re)generate a loan's amortization schedule. 409 if any payment is
  /// already reconciled; 422 if the loan is open-ended (no term/freq).
  Future<void> generateLoanSchedule(String loanId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/schedule'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({}),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      // Surface the server's human message (409/422 carry useful text).
      throw Exception(
        response.body.isNotEmpty
            ? response.body
            : _t(
                'Failed to generate schedule (${response.statusCode})',
                'No se pudo generar el calendario de pagos (${response.statusCode})',
              ),
      );
    }
  }

  /// Administrative early/full payoff: closes the loan (status →
  /// paid_off) and voids the remaining unpaid scheduled installments.
  /// Does NOT create a payment — the user reconciles the real final
  /// transaction through the normal repayment flow (cash-basis interest
  /// income only counts money that actually arrived). 409 if the loan
  /// isn't active.
  Future<void> payoffLoan(String loanId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/payoff'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        response.body.isNotEmpty
            ? response.body
            : _t(
                'Failed to pay off loan (${response.statusCode})',
                'No se pudo liquidar el préstamo (${response.statusCode})',
              ),
      );
    }
  }

  /// Interest-income report (cash basis). `year` optional. Returns
  /// {year, total_interest, total_principal, by_loan[], by_month[]}.
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async {
    final q = year != null ? '?year=$year' : '';
    final response = await _get(Uri.parse('$_baseUrl/loans/interest-income$q'));
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'Failed to load interest income',
        'No se pudieron cargar los ingresos por intereses',
      ),
    );
  }

  /// Direct download URL for the loan-interest CSV (opened in the
  /// browser so the cookie auth rides along, like the tx export).
  String interestIncomeCsvUrl({int? year}) {
    final q = year != null ? '?year=$year' : '';
    return '$_baseUrl/loans/interest-income/export$q';
  }

  /// Per-borrower per-year interest totals CSV (Schedule-B style).
  String interestSummaryCsvUrl() => '$_baseUrl/loans/interest-income/summary';

  /// Printable promissory-note / agreement HTML for a loan (opened in
  /// a new tab; the user prints to PDF from the browser).
  String loanAgreementUrl(String loanId, {String lang = 'en'}) =>
      '$_baseUrl/loans/$loanId/agreement?lang=$lang';

  /// Borrower-facing printable payment plan (HTML → browser PDF): the
  /// schedule with a running balance, friendlier than the legal
  /// agreement. Opened in a new tab so cookie auth rides along.
  String loanPaymentPlanUrl(String loanId) => '$_baseUrl/loans/$loanId/plan';

  /// The payment plan as a CSV that opens directly in Google Sheets /
  /// Excel (installment, due date, principal/interest split, balance
  /// remaining). Opened in a new tab to trigger the download.
  String loanScheduleCsvUrl(String loanId) =>
      '$_baseUrl/loans/$loanId/schedule.csv';

  /// Upcoming + overdue installments for the notifications bell. Each
  /// item: {loan_id, payment_id, borrower_name, amount, currency,
  /// due_date, installment_number, days_until, days_overdue}.
  Future<List<dynamic>> getLoanReminders({bool forceRefresh = false}) {
    return _cachedGet('loans/reminders', () async {
      final response = await _get(Uri.parse('$_baseUrl/loans/reminders'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(
        _t(
          'Failed to load loan reminders',
          'No se pudieron cargar los recordatorios de préstamos',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Unlink (un-reconcile) a recorded repayment. The bank transaction
  /// itself is untouched; only the loan_payments row is removed.
  Future<void> deleteLoanPayment(String paymentId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/loans/payments/$paymentId'),
    );
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Failed to unlink payment (${response.statusCode})',
          'No se pudo desvincular el pago (${response.statusCode})',
        ),
      );
    }
  }

  /// Auto-suggest reconciliation candidates. `kind` is 'disbursement'
  /// or 'repayment'. Each item: {transaction_id, date, amount, currency,
  /// description, confidence, name_matched}.
  Future<List<dynamic>> getLoanSuggestions(String loanId, String kind) async {
    final response = await _get(
      Uri.parse('$_baseUrl/loans/$loanId/suggestions/$kind'),
    );
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(
      _t('Failed to load suggestions', 'No se pudieron cargar las sugerencias'),
    );
  }

  /// Date as YYYY-MM-DD (the backend's NaiveDate format).
  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
