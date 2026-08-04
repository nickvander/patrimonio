part of '../api_service.dart';

/// Recurring rules, transaction reads/mutations (manual entries,
/// splits, batch ops), institutions link/sync, and the statement
/// import pipeline.
///
/// One of the five domain mixins split out of the ApiService
/// god-file — method bodies are byte-identical moves, with one
/// forced exception: the multipart upload path bypasses the verb
/// wrappers by design (streaming progress), so its cache resets
/// call `ApiService.clearDashboardCache()` with the class prefix —
/// statics don't resolve unqualified inside a mixin. See
/// `_ApiServiceBase` in api_service.dart for the design.
mixin _TxApi on _ApiServiceBase {
  // --- Recurring & scheduled transactions (expected-only MVP) ----------

  /// The management list: every recurring rule (active and paused).
  /// Rows carry `effective_next_due` — the first occurrence on/after
  /// today — which is what the UI should display as "next".
  Future<List<dynamic>> getRecurringRules({bool forceRefresh = false}) {
    return _cachedGet('recurring/rules', () async {
      final response = await _get(Uri.parse('$_baseUrl/recurring'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to load recurring rules',
          'No se pudieron cargar las reglas recurrentes',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Expected occurrences from active rules. Default window (no args) is
  /// [today, end of the current month] — "what's still expected this
  /// period". Display-only: the backend never posts these.
  Future<Map<String, dynamic>> getUpcomingRecurring({
    bool forceRefresh = false,
  }) {
    return _cachedGet('recurring/upcoming', () async {
      final response = await _get(Uri.parse('$_baseUrl/recurring/upcoming'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to load expected transactions',
          'No se pudieron cargar las transacciones previstas',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Bills calendar + projected balances: expected occurrences (recurring
  /// rules + loan schedule dues) in [today−days, today+days] with a
  /// paid / upcoming / late / missed / pending_import state each, the
  /// per-currency projected cash curve over [today, today+days], and an
  /// optional `fx_transfer_suggestion` when one currency is projected to
  /// run dry while the other stays positive. [days] is clamped 1..90
  /// server-side. Display-only: the backend never posts anything.
  Future<Map<String, dynamic>> getRecurringCalendar({
    int days = 30,
    bool forceRefresh = false,
  }) {
    return _cachedGet('recurring/calendar/$days', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/recurring/calendar?days=$days'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to load bills calendar',
          'No se pudo cargar el calendario de recibos',
        ),
      );
    }, forceRefresh: forceRefresh);
  }

  /// Create a recurring rule. [amount] is signed like transactions:
  /// negative = expected outflow. [anchorDay] defaults server-side to
  /// [nextDueDate]'s day-of-month.
  Future<Map<String, dynamic>> createRecurringRule({
    required String accountId,
    required String description,
    required double amount,
    required String currency,
    required String cadence,
    required DateTime nextDueDate,
    String? category,
    int? anchorDay,
  }) async {
    final body = <String, dynamic>{
      'account_id': accountId,
      'description': description,
      'amount': amount,
      'currency': currency,
      'cadence': cadence,
      'next_due_date':
          '${nextDueDate.year.toString().padLeft(4, '0')}-'
          '${nextDueDate.month.toString().padLeft(2, '0')}-'
          '${nextDueDate.day.toString().padLeft(2, '0')}',
      if (category != null && category.isNotEmpty) 'category': category,
      'anchor_day': ?anchorDay,
    };
    final response = await _post(
      Uri.parse('$_baseUrl/recurring'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode != 201) {
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to create recurring rule',
          'No se pudo crear la regla recurrente',
        ),
      );
    }
    return json.decode(response.body) as Map<String, dynamic>;
  }

  /// Pause/resume a rule. Paused rules stay listed but stop contributing
  /// to expected cash flow.
  Future<void> setRecurringRuleActive(String id, bool active) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/recurring/$id'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'active': active}),
    );
    if (response.statusCode != 200) {
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to update recurring rule',
          'No se pudo actualizar la regla recurrente',
        ),
      );
    }
  }

  /// Delete a rule. Idempotent — 204 either way.
  Future<void> deleteRecurringRule(String id) async {
    final response = await _delete(Uri.parse('$_baseUrl/recurring/$id'));
    if (response.statusCode != 204) {
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to delete recurring rule',
          'No se pudo eliminar la regla recurrente',
        ),
      );
    }
  }

  /// One newest-first page of transactions across all accounts. The
  /// optional [currency], [sign] (`'inflow'` / `'outflow'`), and [query]
  /// filters are applied server-side over the WHOLE table — the loan
  /// payment picker uses them so it can find a match that's older than one
  /// page and never surfaces a foreign-currency inflow.
  Future<TxPage> getTransactions({
    int limit = 50,
    int offset = 0,
    String? currency,
    String? sign,
    String? query,
    bool excludeLinked = false,
  }) async {
    final params = <String>[
      'limit=$limit',
      'offset=$offset',
      if (currency != null && currency.isNotEmpty)
        'currency=${Uri.encodeQueryComponent(currency)}',
      if (sign != null && sign.isNotEmpty) 'sign=$sign',
      if (query != null && query.trim().isNotEmpty)
        'q=${Uri.encodeQueryComponent(query.trim())}',
      if (excludeLinked) 'exclude_linked=true',
    ];
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/transactions?${params.join('&')}'),
    );
    if (response.statusCode == 200) {
      // Rows decode exactly as before; the whole-table match count rides
      // in the X-Total-Count header (absent on older backends → null,
      // callers keep their heuristics). See TxPage.
      return TxPage(
        rows: json.decode(response.body),
        totalCount: TxPage.totalFromHeaders(response.headers),
      );
    }
    throw Exception(
      _t(
        'Failed to load transactions',
        'No se pudieron cargar los movimientos',
      ),
    );
  }

  /// One newest-first page of a single account's transactions. With no
  /// [limit] the backend keeps its legacy single-shot behavior (up to
  /// 1,000 rows); an explicit limit is clamped server-side to ≤500 per
  /// request (same cap as `/dashboard/transactions`, see
  /// [kTxBackendMaxPageSize] in transaction_mutation_refresh.dart).
  Future<TxPage> getAccountTransactions(
    String accountId, {
    int? limit,
    int? offset,
  }) async {
    final params = <String>[
      if (limit != null) 'limit=$limit',
      if (offset != null) 'offset=$offset',
    ];
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    final response = await _get(
      Uri.parse('$_baseUrl/accounts/$accountId/transactions$query'),
    );
    if (response.statusCode == 200) {
      return TxPage(
        rows: json.decode(response.body),
        totalCount: TxPage.totalFromHeaders(response.headers),
      );
    }
    throw Exception(
      _t(
        'Failed to load account transactions',
        'No se pudieron cargar los movimientos de la cuenta',
      ),
    );
  }

  /// Kick off a sync of all the caller's institutions. The backend now runs
  /// the sync as a detached task and returns 202 immediately (it used to run
  /// the whole sync inline and return 200 only when done); the caller watches
  /// [getSyncStatus] for progress and completion. 200 is still accepted for
  /// backward compatibility with an older backend.
  Future<void> syncInstitutions() async {
    // Send an explicit empty-JSON body. With no body/headers the browser
    // stamps its own Content-Type (text/plain) on the POST, and a backend
    // whose optional-body extractor is strict about media types answers
    // 415 Unsupported Media Type — which is exactly how "Sync now" broke
    // on web. An explicit application/json '{}' is unambiguous everywhere.
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/sync'),
      headers: const {'Content-Type': 'application/json'},
      body: '{}',
    );
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception(
        _t(
          'Failed to sync institutions',
          'No se pudieron sincronizar las instituciones',
        ),
      );
    }
  }

  Future<Map<String, dynamic>> getReconnectToken(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/reconnect-token/$institutionId'),
      headers: {'Content-Type': 'application/json'},
      // Same platform hint as the new-link flow: Android OAuth must return
      // in-app via android_package_name, not the web redirect_uri.
      body: json.encode({
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(
      _t(
        'Failed to retrieve reconnect token',
        'No se pudo obtener el token de reconexión',
      ),
    );
  }

  /// Swap a Plaid public token (from a completed Link session) for a stored
  /// access token, creating the institution. Used by the OAuth-redirect resume
  /// path; the in-tab connect flow calls the same endpoint directly.
  Future<void> exchangePublicToken(
    String publicToken,
    String institutionName, {
    String institutionType = 'banking',
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/exchange-token'),
      body: json.encode({
        'public_token': publicToken,
        'institution_name': institutionName,
        'institution_type': institutionType,
      }),
      headers: const {'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to exchange public token',
          'No se pudo intercambiar el token público',
        ),
      );
    }
  }

  Future<void> deleteInstitution(String institutionId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/institutions/$institutionId'),
    );
    if (response.statusCode != 204) {
      throw Exception(
        _t(
          'Failed to delete institution',
          'No se pudo eliminar la institución',
        ),
      );
    }
  }

  /// Multi-file batch wrapper around /imports/upload. The server
  /// returns one `ImportResponse` JSON object per request (the
  /// shape `{status, message, transactions_count, transactions}`).
  ///
  /// Per-file progress: when `onProgress` is supplied, the client
  /// generates a UUID and sends it as the `X-Upload-Job-Id` header.
  /// While the upload POST is in flight, a parallel polling loop
  /// hits `GET /imports/progress/{job_id}` every 250 ms; each
  /// snapshot fires `onProgress`. The progress channel is fully
  /// independent of the upload connection — that avoids the
  /// ERR_CONNECTION_RESET the earlier bidirectional-stream design
  /// caused (response chunks flushing while the upload body was
  /// still arriving made Chromium abort).
  Future<Map<String, dynamic>> uploadStatements(
    List<PlatformFile> files, {
    String? password,
    ImportProgressCallback? onProgress,
    int? maxBatchBytes,
  }) async {
    final usable = files.where((f) => f.bytes != null).toList();
    if (usable.isEmpty) {
      throw Exception(_t('No files to upload', 'No hay archivos para subir'));
    }

    // Split into batches that each stay under the server's body limit,
    // so a big multi-year drop doesn't bounce off the 100 MB cap — the
    // user no longer has to split by hand. Null = one batch (callers
    // that don't care about the cap, e.g. a single small CSV).
    final batches = maxBatchBytes == null
        ? [usable]
        : _packIntoBatches(usable, maxBatchBytes);

    // The full checklist, in submission order, seeded as 'waiting'.
    final order = usable.map((f) => f.name).toList();
    final status = <String, ImportFileStatus>{
      for (final f in usable) f.name: ImportFileStatus(f.name, 'waiting'),
    };
    void emit() {
      if (onProgress == null) return;
      final list = [for (final n in order) status[n]!];
      onProgress(
        files: list,
        done: list.where((s) => s.isDone).length,
        total: list.length,
      );
    }

    emit(); // initial all-waiting render

    final merged = <dynamic>[];
    // Account metadata (CLABE, holder, suggested name + balance) from the
    // newest statement across all batches — the batch wrapper must carry this
    // through or the preview can't pre-fill / match an account.
    Map<String, dynamic>? accountInfo;
    var sawSuccess = false;
    for (final batch in batches) {
      // Files in the in-flight batch all start at once on the server's
      // blocking pool — show them as 'parsing'; later batches stay
      // 'waiting'.
      for (final f in batch) {
        final s = status[f.name];
        if (s != null && !s.isDone) {
          status[f.name] = s.copyWith(status: 'parsing');
        }
      }
      emit();

      final resp = await _uploadOneBatch(
        batch,
        password,
        onProgress == null
            ? null
            : (completed) {
                for (final c in completed) {
                  if (status.containsKey(c.name)) status[c.name] = c;
                }
                emit();
              },
      );

      // One password covers the whole set — surface immediately so the
      // user re-enters it and retries everything (mirrors the old
      // single-request semantics).
      if (resp['status']?.toString() == 'password_required') {
        return resp;
      }
      final txs = resp['transactions'];
      if (txs is List) {
        merged.addAll(txs);
        if (txs.isNotEmpty) sawSuccess = true;
      }
      final ai = resp['account_info'];
      if (ai is Map<String, dynamic>) {
        final curEnd = accountInfo?['period_end']?.toString();
        final newEnd = ai['period_end']?.toString();
        if (accountInfo == null ||
            (newEnd != null &&
                (curEnd == null || newEnd.compareTo(curEnd) > 0))) {
          accountInfo = ai;
        }
      }
    }

    // Resolve anything the server never reported (older API without the
    // per-file channel, or a missed final poll) so no row hangs on
    // 'parsing'.
    for (final n in order) {
      final s = status[n]!;
      if (!s.isDone) status[n] = s.copyWith(status: 'ok');
    }
    emit();

    final fileCount = usable.length;
    final plural = fileCount == 1 ? '' : 's';
    final String message;
    if (sawSuccess) {
      message = _t(
        'Parsed ${merged.length} transactions from $fileCount file$plural.',
        'Se procesaron ${merged.length} transacciones de $fileCount '
            'archivo$plural.',
      );
    } else {
      // Nothing parsed. Summarise concisely from the checklist (the
      // backend's all-failed message is a long per-file dump) and point
      // at the likely cause.
      final failed = status.values.where((s) => s.status == 'failed').length;
      if (failed > 0) {
        message = _t(
          'No transactions found. $failed of $fileCount file$plural '
              "couldn't be read — make sure each is a Nu, Banamex, or "
              'CetesDirecto statement (PDF or CSV).',
          'No se encontraron transacciones. No se pudieron leer $failed de '
              '$fileCount archivo$plural: asegúrate de que cada uno sea un '
              'estado de cuenta de Nu, Banamex o CetesDirecto (PDF o CSV).',
        );
      } else {
        message = _t(
          'No transactions found in the selected file$plural.',
          'No se encontraron transacciones en '
              '${fileCount == 1 ? 'el archivo seleccionado' : 'los archivos seleccionados'}.',
        );
      }
    }
    return {
      'status': sawSuccess ? 'success' : 'error',
      'message': message,
      'transactions_count': merged.length,
      'transactions': merged,
      'account_info': ?accountInfo,
    };
  }

  /// Greedy bin-pack: walk the files in order, starting a new batch
  /// whenever adding the next would push the running total over
  /// [maxBytes]. A single file larger than [maxBytes] still lands alone
  /// in its own batch (the caller pre-screens for files over the hard
  /// server cap).
  List<List<PlatformFile>> _packIntoBatches(
    List<PlatformFile> files,
    int maxBytes,
  ) {
    final batches = <List<PlatformFile>>[];
    var current = <PlatformFile>[];
    var currentBytes = 0;
    for (final f in files) {
      final sz = f.size;
      if (current.isNotEmpty && currentBytes + sz > maxBytes) {
        batches.add(current);
        current = <PlatformFile>[];
        currentBytes = 0;
      }
      current.add(f);
      currentBytes += sz;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Upload ONE batch (single multipart POST) and return its
  /// `ImportResponse` JSON. When [onFiles] is supplied, a job-id is sent
  /// and a parallel poller reports each file's completion as it parses;
  /// a final reconcile fetch guarantees the terminal per-file state is
  /// delivered even if the background poller exited first.
  Future<Map<String, dynamic>> _uploadOneBatch(
    List<PlatformFile> files,
    String? password,
    void Function(List<ImportFileStatus> completed)? onFiles,
  ) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/imports/upload'),
    );
    // Mirror the protected router's CSRF guard. The multipart helper
    // bypasses our _post wrapper, so attach the header by hand.
    request.headers['X-Requested-With'] = 'fetch';

    final String? jobId = onFiles != null ? _generateJobId() : null;
    if (jobId != null) {
      request.headers['X-Upload-Job-Id'] = jobId;
    }

    for (final f in files) {
      if (f.bytes == null) continue;
      request.files.add(
        http.MultipartFile.fromBytes('file', f.bytes!, filename: f.name),
      );
    }
    if (password != null && password.isNotEmpty) {
      request.fields['password'] = password;
    }

    bool uploadComplete = false;
    Future<void>? pollerFuture;
    if (jobId != null && onFiles != null) {
      pollerFuture = _pollUploadProgress(jobId, onFiles, () => uploadComplete);
    }

    try {
      // 600s (10 min) timeout. The backend parallelises PDF parsing
      // across the blocking pool, but each file is still CPU-bound for
      // several seconds (qpdf decrypt + lopdf extract + table recovery).
      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: 600));
      _maybeUnauthorizedStreamed(streamedResponse);

      final response = await http.Response.fromStream(streamedResponse);
      // The import endpoint returns an ImportResponse JSON on 200
      // (success / password_required) AND on 422 (every file failed or
      // yielded 0 transactions). Treat both as a valid result so an
      // all-skipped batch surfaces its per-file outcome + message instead
      // of throwing — only genuine transport/size failures below become
      // exceptions.
      if (response.statusCode == 200 || response.statusCode == 422) {
        Map<String, dynamic>? decoded;
        try {
          final body = json.decode(response.body);
          if (body is Map<String, dynamic> && body.containsKey('status')) {
            decoded = body;
          }
        } catch (_) {
          // Non-JSON body (e.g. a multipart read error) — fall through to
          // the size/transport handling below.
        }
        if (decoded != null) {
          // Multipart upload bypasses the _post/_patch verb wrappers, so
          // the central post-mutation invalidation doesn't fire here —
          // clear by hand, but only when something was actually imported.
          if (decoded['status'] == 'success') ApiService.clearDashboardCache();
          // Final reconcile: the background poller may have exited before
          // the terminal snapshot, so fetch it once to ensure every
          // file's final state reaches the checklist.
          if (jobId != null && onFiles != null) {
            await _fetchFinalProgress(jobId, onFiles);
          }
          return decoded;
        }
      }
      // Payload-too-large surfaces as a real 413 OR (more often through
      // the axum multipart stack) as a truncated body that makes parsing
      // fail with 4xx/5xx. With auto-batching this should be rare, but
      // keep the specific hint for the no-batch path.
      if (response.statusCode == 413 ||
          response.body.contains('failed to read stream') ||
          response.body.contains('body limit exceeded')) {
        final totalMb =
            files
                .map((f) => (f.bytes?.length ?? 0))
                .fold<int>(0, (a, b) => a + b) /
            (1024 * 1024);
        throw Exception(
          _t(
            'Upload too large (${totalMb.toStringAsFixed(1)} MB across '
                '${files.length} file${files.length == 1 ? '' : 's'}). '
                'Try splitting into smaller batches.',
            'La carga es demasiado grande (${totalMb.toStringAsFixed(1)} MB en '
                '${files.length} archivo${files.length == 1 ? '' : 's'}). '
                'Intenta dividirla en lotes más pequeños.',
          ),
        );
      }
      throw Exception(
        _t(
          'Server returned ${response.statusCode}: ${response.body}',
          'El servidor respondió ${response.statusCode}: ${response.body}',
        ),
      );
    } on TimeoutException catch (_) {
      throw Exception(
        _t(
          'Upload timed out after 10 minutes. '
              'Try splitting the batch into smaller groups (e.g. 6 PDFs at a time) '
              'or check that the API container is still running.',
          'La carga agotó el tiempo de espera tras 10 minutos. '
              'Intenta dividir el lote en grupos más pequeños (p. ej. 6 PDF a la vez) '
              'o verifica que el contenedor de la API siga en ejecución.',
        ),
      );
    } on http.ClientException catch (e) {
      throw Exception(
        _t(
          'Network error during upload. Please check your connection and try again. ($e)',
          'Error de red durante la carga. Revisa tu conexión e inténtalo de nuevo. ($e)',
        ),
      );
    } finally {
      uploadComplete = true;
      // ignore: unawaited_futures
      pollerFuture;
    }
  }

  /// Decode a progress snapshot's `files` array into completed statuses.
  List<ImportFileStatus> _parseProgressFiles(Map<String, dynamic> snap) {
    final raw = snap['files'];
    final out = <ImportFileStatus>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final name = e['name']?.toString() ?? '';
          final ok = e['ok'] as bool? ?? true;
          final count = (e['count'] as num?)?.toInt() ?? 0;
          if (name.isNotEmpty) {
            out.add(ImportFileStatus(name, ok ? 'ok' : 'failed', count));
          }
        }
      }
    }
    return out;
  }

  /// One-shot fetch of the terminal snapshot, used to reconcile the
  /// checklist after the POST returns (the background poller may have
  /// stopped before observing the terminal state).
  Future<void> _fetchFinalProgress(
    String jobId,
    void Function(List<ImportFileStatus>) onFiles,
  ) async {
    try {
      final res = await _get(Uri.parse('$_baseUrl/imports/progress/$jobId'));
      if (res.statusCode == 200) {
        final snap = json.decode(res.body) as Map<String, dynamic>;
        onFiles(_parseProgressFiles(snap));
      }
    } catch (_) {
      // Best-effort; the merged response is still authoritative.
    }
  }

  /// Generate a job-id for the upload progress side-channel. Format
  /// is a 36-char UUID-shaped string so the backend's `Uuid::parse_str`
  /// accepts it cleanly. Not cryptographically random — the only
  /// requirement is uniqueness across concurrent uploads from the
  /// same browser tab.
  String _generateJobId() {
    final r = math.Random.secure();
    String hex(int n) {
      final buf = StringBuffer();
      for (int i = 0; i < n; i++) {
        buf.write(r.nextInt(16).toRadixString(16));
      }
      return buf.toString();
    }

    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  /// Poll `/imports/progress/{jobId}` every 250 ms until the server
  /// returns a terminal snapshot OR the upload completes (signalled
  /// by `done()` returning true). Each snapshot fires `onProgress`.
  /// Errors are swallowed — the upload itself is the authoritative
  /// channel, so a transient 404/500 on the polling side shouldn't
  /// surface as a user-visible failure.
  Future<void> _pollUploadProgress(
    String jobId,
    void Function(List<ImportFileStatus> completed) onFiles,
    bool Function() done,
  ) async {
    const interval = Duration(milliseconds: 250);
    int lastDone = -1;
    while (!done()) {
      await Future.delayed(interval);
      try {
        final res = await _get(Uri.parse('$_baseUrl/imports/progress/$jobId'));
        if (res.statusCode == 200) {
          final snap = json.decode(res.body) as Map<String, dynamic>;
          final d = (snap['done'] as num?)?.toInt() ?? 0;
          final terminal = snap['terminal'] as bool? ?? false;
          // Only fire when the snapshot actually moved — saves the
          // import screen from rebuilding 4× per second when nothing's
          // changed.
          if (d != lastDone || terminal) {
            lastDone = d;
            onFiles(_parseProgressFiles(snap));
          }
          if (terminal) return;
        }
        // 404 means the job entry hasn't been registered yet (we
        // raced the upload handler) or has been evicted. Keep
        // polling — eventually `done()` will flip.
      } catch (_) {
        // Best-effort. Continue.
      }
    }
  }

  Future<Map<String, dynamic>> uploadStatement(
    String fileName,
    Uint8List bytes, {
    String? password,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/imports/upload'),
    );
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: fileName),
    );
    if (password != null && password.isNotEmpty) {
      request.fields['password'] = password;
    }

    try {
      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);
      _maybeUnauthorized(response);

      if (response.statusCode == 200) {
        // See uploadStatements: multipart bypasses the verb wrappers.
        ApiService.clearDashboardCache();
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception(
          _t(
            'Server returned ${response.statusCode}: ${response.body}',
            'El servidor respondió ${response.statusCode}: ${response.body}',
          ),
        );
      }
    } on http.ClientException catch (e) {
      throw Exception(
        _t(
          'Network error during upload. Please check your connection and try again. ($e)',
          'Error de red durante la carga. Revisa tu conexión e inténtalo de nuevo. ($e)',
        ),
      );
    } catch (e) {
      throw Exception(_t('Upload failed: $e', 'La carga falló: $e'));
    }
  }

  Future<Map<String, dynamic>> confirmImport(
    String accountId,
    List<dynamic> transactions,
  ) async {
    final response = await _post(
      Uri.parse('$_baseUrl/imports/confirm'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'account_id': accountId,
        'transactions': transactions,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(
        _t(
          'Confirmation failed: ${response.body}',
          'La confirmación falló: ${response.body}',
        ),
      );
    }
  }

  /// Attach statement-derived holdings (e.g. an HSA's invested fund + cash
  /// sleeve) to a manual account. Each [holdings] entry is a map
  /// {symbol, name?, quantity, value?, cash?}; same-symbol rows are replaced,
  /// then the account balance is recomputed from its holdings. Best-effort —
  /// a non-manual target returns 403, which the caller can ignore.
  Future<void> importHoldings(String accountId, List<dynamic> holdings) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/import'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'holdings': holdings}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Holdings import failed: ${response.body}',
          'La importación de posiciones falló: ${response.body}',
        ),
      );
    }
  }

  /// Recent import batches (newest first): each is
  /// {batch_id, account_id, account_name, txn_count, from_date, to_date,
  /// imported_at, files[]}.
  Future<List<dynamic>> getImportBatches() async {
    final res = await _get(Uri.parse('$_baseUrl/imports/batches'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['batches'] as List?) ?? const [];
    }
    return const [];
  }

  /// Per-account statement-continuity status over the whole imported
  /// history: each is {account_id, account_name, institution_name,
  /// statement_count, warnings[]}. Empty `warnings` = no detected gaps.
  Future<List<dynamic>> getImportContinuity() async {
    final res = await _get(Uri.parse('$_baseUrl/imports/continuity'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['accounts'] as List?) ?? const [];
    }
    return const [];
  }

  /// Per-account statement coverage: how far each account's imported
  /// statements reach. Each entry is {account_id, account_name,
  /// institution_name, currency, last_covered_date (YYYY-MM-DD),
  /// last_imported_at (ISO8601), batch_count, last_import_file}, ordered by
  /// last_covered_date descending. Only accounts with statement-imported
  /// transactions appear; archived accounts are excluded. Best-effort —
  /// returns an empty list on any non-200 or if the key is missing.
  Future<List<dynamic>> getImportCoverage() async {
    final res = await _get(Uri.parse('$_baseUrl/imports/coverage'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['coverage'] as List?) ?? const [];
    }
    return const [];
  }

  /// Undo an import — delete every transaction it created. Returns the
  /// number removed.
  Future<int> undoImportBatch(String batchId) async {
    final res = await _delete(Uri.parse('$_baseUrl/imports/batches/$batchId'));
    if (res.statusCode == 200) {
      ApiService.clearDashboardCache();
      return ((json.decode(res.body) as Map)['deleted'] as num?)?.toInt() ?? 0;
    }
    throw Exception(
      _t('Failed to undo import', 'No se pudo deshacer la importación'),
    );
  }

  /// Bulk-delete transactions in an account + inclusive date range. With
  /// [dryRun] true, returns the count that WOULD be deleted (for a confirm
  /// preview); otherwise deletes and returns the number removed.
  /// [importedOnly] limits it to statement-imported rows.
  Future<int> bulkDeleteTransactions({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    required bool importedOnly,
    required bool dryRun,
  }) async {
    final res = await _post(
      Uri.parse('$_baseUrl/imports/transactions/bulk-delete'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'account_id': accountId,
        'date_from': dateFrom,
        'date_to': dateTo,
        'imported_only': importedOnly,
        'dry_run': dryRun,
      }),
    );
    if (res.statusCode == 200) {
      if (!dryRun) ApiService.clearDashboardCache();
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body[dryRun ? 'count' : 'deleted'] as num?)?.toInt() ?? 0;
    }
    throw Exception(_t('Bulk delete failed', 'La eliminación masiva falló'));
  }

  /// Preview-time duplicate check: returns the indices (into
  /// [transactions]) that are already imported in [accountId], by the same
  /// signature confirm dedups on. Best-effort — returns an empty set on
  /// any error so the preview still works.
  Future<Set<int>> checkImportDuplicates(
    String accountId,
    List<dynamic> transactions,
  ) async {
    try {
      final response = await _post(
        Uri.parse('$_baseUrl/imports/check-duplicates'),
        headers: _withCsrf({'Content-Type': 'application/json'}),
        body: json.encode({
          'account_id': accountId,
          'transactions': transactions,
        }),
      );
      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final idx = (body['duplicate_indices'] as List?) ?? const [];
        return idx.map((e) => (e as num).toInt()).toSet();
      }
    } catch (_) {
      // Best-effort; fall through to "no duplicates known".
    }
    return <int>{};
  }

  /// Preview-time statement reconciliation: for each destination account,
  /// ask the backend whether every statement in the batch balances against
  /// the bank's own closing SALDO once this import lands, and which stored
  /// transactions explain a gap when one exists.
  ///
  /// [transactionsByAccount] maps an account id to the preview rows destined
  /// for it (the same raw rows `confirmImport` posts, including
  /// `source_file` — the backend groups one result per statement file).
  ///
  /// Read-only and **advisory**: the backend writes nothing and confirm is
  /// unchanged. Best-effort like [checkImportDuplicates] — any failure
  /// returns an empty list so the import flow keeps working.
  Future<List<AccountReconciliation>> reconcileImport(
    Map<String, List<dynamic>> transactionsByAccount,
  ) async {
    if (transactionsByAccount.isEmpty) return const [];
    try {
      final response = await _post(
        Uri.parse('$_baseUrl/imports/reconcile'),
        headers: _withCsrf({'Content-Type': 'application/json'}),
        body: json.encode({
          'accounts': [
            for (final entry in transactionsByAccount.entries)
              {'account_id': entry.key, 'transactions': entry.value},
          ],
        }),
      );
      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final accounts = (body['accounts'] as List?) ?? const [];
        return accounts
            .whereType<Map>()
            .map(
              (a) => AccountReconciliation.fromJson(a.cast<String, dynamic>()),
            )
            .toList();
      }
    } catch (_) {
      // Best-effort; a reconciliation we couldn't fetch simply isn't shown.
    }
    return const [];
  }

  /// Bump an account's `current_balance` and write a `balance_snapshots`
  /// row. `notes` (when set) is stored alongside the snapshot — used by
  /// manual-asset revaluations to capture "why this value moved" without
  /// stomping previous notes.
  Future<void> updateAccountBalance(
    String accountId,
    double balance, {
    String? notes,
  }) async {
    final body = <String, dynamic>{'current_balance': balance};
    if (notes != null && notes.trim().isNotEmpty) {
      body['notes'] = notes.trim();
    }
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/$accountId/balance'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t('Failed to update balance', 'No se pudo actualizar el saldo'),
      );
    }
  }

  Future<void> deleteAccount(String accountId) async {
    final response = await _delete(Uri.parse('$_baseUrl/accounts/$accountId'));
    if (response.statusCode != 204) {
      throw Exception(
        _t('Failed to delete account', 'No se pudo eliminar la cuenta'),
      );
    }
  }

  /// Set or clear a user-defined nickname for an account. An empty
  /// nickname clears the override so display falls back to the
  /// bank-supplied name.
  Future<void> renameAccount(String accountId, String nickname) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/$accountId/nickname'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'nickname': nickname}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t('Failed to rename account', 'No se pudo renombrar la cuenta'),
      );
    }
  }

  Future<void> updateTransaction(
    String txId, {
    String? userCategory,
    String? userNotes,
    String? accountId,
    // `userDescription` semantics: null = leave alone, empty string =
    // clear the override (revert to the auto-picked label), any other
    // value = set the display override to that string.
    String? userDescription,
  }) async {
    final body = <String, dynamic>{};
    if (userCategory != null) body['user_category'] = userCategory;
    if (userNotes != null) body['user_notes'] = userNotes;
    if (accountId != null) body['account_id'] = accountId;
    if (userDescription != null) body['user_description'] = userDescription;

    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to update transaction',
          'No se pudo actualizar el movimiento',
        ),
      );
    }
  }

  /// Apply the same change (category and/or account move) to many
  /// transactions in ONE request — used by the bulk-action toolbar so a
  /// 40-row selection is a single round-trip, not 40 PATCHes. Only the
  /// non-null fields are sent (COALESCE semantics on the server: an
  /// absent field leaves that column alone). Returns the number of rows
  /// the server actually updated (ids the user doesn't own are filtered
  /// out by the `user_id` predicate and never counted). The `_patch`
  /// wrapper invalidates the dashboard cache on success, like every
  /// other mutation here.
  Future<int> batchUpdateTransactions(
    List<String> ids, {
    String? category,
    String? accountId,
    String? description,
  }) async {
    final body = <String, dynamic>{
      'ids': ids,
      'user_category': ?category,
      'account_id': ?accountId,
      'user_description': ?description,
    };
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/transactions/batch'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to batch-update transactions',
          'No se pudieron actualizar los movimientos en lote',
        ),
      );
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    return (decoded['updated'] as num).toInt();
  }

  /// Delete many transactions in ONE request — used by the bulk-action
  /// toolbar so a multi-row selection is a single round-trip, not N
  /// DELETEs. Posts to `/accounts/transactions/batch-delete` (POST, not
  /// DELETE, since it carries an ids body). Returns the number of rows
  /// the server actually deleted (ids the user doesn't own are filtered
  /// out by the `user_id` predicate and never counted). Split parents
  /// cascade to their children server-side, same as the single delete.
  /// The `_post` wrapper invalidates the dashboard cache on success,
  /// like every other mutation here.
  Future<int> batchDeleteTransactions(List<String> ids) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts/transactions/batch-delete'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'ids': ids}),
    );
    if (response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to batch-delete transactions',
          'No se pudieron eliminar los movimientos en lote',
        ),
      );
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    return (decoded['deleted'] as num).toInt();
  }

  /// URL of the CSV export endpoint. We hand this to the browser via an
  /// anchor click rather than fetching + blobbing in Dart — the backend
  /// returns Content-Disposition: attachment so the browser downloads
  /// directly without using extra memory.
  String exportTransactionsCsvUrl() =>
      '$_baseUrl/dashboard/transactions/export';

  /// Insert a manually-entered transaction. App convention: NEGATIVE
  /// amount = expense / outflow, positive = income / inflow — the add
  /// dialog signs the value before calling (add_transaction_dialog.dart).
  /// This is the OPPOSITE of Plaid's raw sign; rows are normalized to the
  /// app convention before this layer. (The old comment here claimed the
  /// Plaid convention and misled a 2026-08-03 walkthrough into seeding an
  /// expense as an inflow.)
  Future<void> createManualTransaction({
    required String accountId,
    required DateTime date,
    required String description,
    required double amount,
    required String currency,
    String? category,
    String? notes,
  }) async {
    await createManualTransactionReturningId(
      accountId: accountId,
      date: date,
      description: description,
      amount: amount,
      currency: currency,
      category: category,
      notes: notes,
    );
  }

  /// Same POST as [createManualTransaction] — identical body, identical
  /// sign convention (NEGATIVE = outflow) — but hands back the id of the
  /// row the server created (`201 {"id": …}`), so a caller can offer an
  /// Undo that deletes exactly the row it just wrote instead of guessing
  /// which of the user's transactions was the new one.
  ///
  /// Returns null when the response carries no parseable id: the write
  /// still SUCCEEDED, only the undo handle is unavailable, and callers
  /// must degrade by hiding the Undo affordance rather than treating it
  /// as a failure. [createManualTransaction] is the thin void wrapper
  /// over this, kept so existing call sites and the `extends ApiService`
  /// test fakes that override it are untouched.
  Future<String?> createManualTransactionReturningId({
    required String accountId,
    required DateTime date,
    required String description,
    required double amount,
    required String currency,
    String? category,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'account_id': accountId,
      'date':
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
      'description': description,
      'amount': amount,
      'currency': currency,
      if (category != null && category.isNotEmpty) 'category': category,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };
    final response = await _post(
      Uri.parse('$_baseUrl/dashboard/transactions/manual'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 409) {
      throw Exception(
        _t(
          'Already added — same date / amount / description.',
          'Ya se agregó — misma fecha / monto / descripción.',
        ),
      );
    }
    if (response.statusCode != 201) {
      throw Exception(
        _t(
          'Failed to add transaction: ${response.body}',
          'No se pudo agregar el movimiento: ${response.body}',
        ),
      );
    }
    // The row is committed at this point; a body we can't read costs the
    // caller its Undo handle, never the transaction.
    try {
      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) {
        final id = decoded['id']?.toString();
        if (id != null && id.isNotEmpty) return id;
      }
    } catch (_) {
      /* fall through to null — the write already succeeded */
    }
    return null;
  }

  /// Full edit of a manually-entered transaction — same field set as
  /// [createManualTransaction], PUT against the existing row. Only
  /// `source == 'manual'` rows are editable: the server answers 403 for
  /// synced/imported rows (their facts belong to the bank) and 404 for
  /// rows or target accounts the caller doesn't own.
  Future<void> updateManualTransaction({
    required String id,
    required String accountId,
    required DateTime date,
    required String description,
    required double amount,
    required String currency,
    String? category,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'account_id': accountId,
      'date':
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
      'description': description,
      'amount': amount,
      'currency': currency,
      // Absent keys deserialize to None server-side and CLEAR the
      // column — deliberate for an edit (blanking the category field
      // must actually remove the category, unlike the create where
      // absent just means "none yet").
      if (category != null && category.isNotEmpty) 'category': category,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };
    final response = await _put(
      Uri.parse('$_baseUrl/accounts/transactions/$id'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 409) {
      // Either the edited values now collide with another manual entry
      // (dedup signature) or the row is part of a split — surface the
      // server's message, which distinguishes the two.
      throw _errorFromBody(
        response,
        fallback: _t(
          'Conflicting manual transaction',
          'Movimiento manual en conflicto',
        ),
      );
    }
    if (response.statusCode != 200) {
      throw _errorFromBody(
        response,
        fallback: _t(
          'Failed to update transaction',
          'No se pudo actualizar el movimiento',
        ),
      );
    }
  }

  /// Split a transaction into [splits] children. Each split is
  /// `{description, amount, [category]}`. The original parent stays
  /// in the DB for audit but is hidden from every list view.
  Future<void> splitTransaction(
    String txId,
    List<Map<String, dynamic>> splits,
  ) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts/transactions/$txId/splits'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'splits': splits}),
    );
    if (response.statusCode != 201) {
      // Surface the server's reason (422 with `error` field) so the
      // dialog can show "Split total doesn't match" etc. exactly as
      // the server saw it.
      throw _errorFromBody(
        response,
        fallback: _t('Split failed', 'No se pudo dividir el movimiento'),
      );
    }
  }

  /// Replace the children of an already-split parent in one atomic
  /// round-trip. Used by the "Edit split" flow — superior to
  /// unsplit-then-resplit because there's no window where a concurrent
  /// dashboard read sees the parent restored without children. The
  /// payload shape matches `splitTransaction`.
  Future<void> replaceSplits(
    String txId,
    List<Map<String, dynamic>> splits,
  ) async {
    final response = await _put(
      Uri.parse('$_baseUrl/accounts/transactions/$txId/splits'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'splits': splits}),
    );
    if (response.statusCode != 200) {
      throw _errorFromBody(
        response,
        fallback: _t('Edit split failed', 'No se pudo editar la división'),
      );
    }
  }

  /// Delete every child of a split parent — un-splits the transaction.
  /// The parent re-emerges in the list.
  Future<void> unsplitTransaction(String parentTxId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/accounts/transactions/$parentTxId/splits'),
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw _errorFromBody(
        response,
        fallback: _t('Unsplit failed', 'No se pudo deshacer la división'),
      );
    }
  }

  Future<void> deleteTransaction(String txId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception(
        _t(
          'Failed to delete transaction (${response.statusCode})',
          'No se pudo eliminar el movimiento (${response.statusCode})',
        ),
      );
    }
  }

  Future<void> createAccount({
    required String name,
    required String type,
    required String currency,
    required double initialBalance,
    String? clabe,
    String? holderName,
    String? institutionName,
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'name': name,
        'account_type': type,
        'currency': currency,
        'initial_balance': initialBalance,
        if (clabe != null && clabe.isNotEmpty) 'clabe': clabe,
        if (holderName != null && holderName.isNotEmpty)
          'holder_name': holderName,
        if (institutionName != null && institutionName.isNotEmpty)
          'institution_name': institutionName,
      }),
    );
    if (response.statusCode != 201) {
      throw Exception(
        _t(
          'Failed to create account: ${response.body}',
          'No se pudo crear la cuenta: ${response.body}',
        ),
      );
    }
  }
}

// --- Statement reconciliation (POST /imports/reconcile) -----------------
//
// A typed model rather than the stringly-typed maps most endpoints use:
// the response is a closed vocabulary the UI switches on, and getting
// "we couldn't check this" confused with "it balances" is exactly the
// failure this feature exists to prevent.

/// Outcome of reconciling ONE statement (and, rolled up worst-of, of an
/// account). Mirrors the backend's `ReconcileStatus`.
enum ReconcileStatus {
  /// Balances to the centavo and every incoming row is new.
  reconciled,

  /// Balances, but only because some incoming rows are already stored and
  /// confirm will skip them.
  reconciledAfterDuplicateSkip,

  /// There is a gap and specific stored transactions sum to exactly it.
  explainedByExistingTransactions,

  /// There is a gap and nothing on file explains it.
  unexplained,

  /// The statement could not be checked at all. NEVER a stand-in for
  /// "it reconciles" — see `unavailableReason`.
  unavailable,
}

/// Why a statement could not be checked. `null` when the backend sent a
/// reason this client doesn't know (forward compatibility) — the UI then
/// says only that it couldn't check.
enum ReconcileUnavailableReason {
  /// No row in the statement carries a running balance.
  noRunningBalance,

  /// The only balance-bearing row is a period-total marker, so there is no
  /// opening balance to anchor on.
  balanceMarkerOnly,

  /// The statement (or the account's rows in its period) spans more than
  /// one currency; summing across currencies is banned here.
  mixedCurrency,
}

/// How a candidate transaction would explain the gap.
enum ReconcileCandidateKind {
  /// Inside the period and not on the statement — a likely double entry.
  doubleEntryInPeriod,

  /// Just outside the period — a likely misdated row.
  misdatedNearPeriod,
}

/// A stored transaction offered as an explanation for a statement's gap.
class ReconcileCandidate {
  const ReconcileCandidate({
    required this.transactionId,
    required this.date,
    required this.description,
    required this.amount,
    required this.kind,
  });

  factory ReconcileCandidate.fromJson(Map<String, dynamic> j) =>
      ReconcileCandidate(
        transactionId: (j['transaction_id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        amount: _reconMoney(j['amount']) ?? 0,
        kind: switch ((j['kind'] ?? '').toString()) {
          'misdated_near_period' => ReconcileCandidateKind.misdatedNearPeriod,
          _ => ReconcileCandidateKind.doubleEntryInPeriod,
        },
      );

  final String transactionId;

  /// ISO `YYYY-MM-DD`, as the backend sends it.
  final String date;
  final String description;
  final double amount;
  final ReconcileCandidateKind kind;
}

/// One statement file's reconciliation result. Every money field is
/// nullable because the backend serializes them explicitly as `null` when
/// it has no value — an absent closing balance must not read as 0.
class StatementReconciliation {
  const StatementReconciliation({
    required this.file,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    this.currency,
    this.unavailableReason,
    this.statementOpeningBalance,
    this.statementClosingBalance,
    this.computedClosingBalance,
    this.difference,
    this.incomingRows = 0,
    this.duplicateRows = 0,
    this.existingRowsInPeriod = 0,
    this.candidates = const [],
  });

  factory StatementReconciliation.fromJson(Map<String, dynamic> j) =>
      StatementReconciliation(
        file: (j['file'] ?? '').toString(),
        periodStart: (j['period_start'] ?? '').toString(),
        periodEnd: (j['period_end'] ?? '').toString(),
        currency: j['currency']?.toString(),
        status: reconcileStatusFromWire(j['status']),
        unavailableReason: switch ((j['unavailable_reason'] ?? '').toString()) {
          'no_running_balance' => ReconcileUnavailableReason.noRunningBalance,
          'balance_marker_only' => ReconcileUnavailableReason.balanceMarkerOnly,
          'mixed_currency' => ReconcileUnavailableReason.mixedCurrency,
          _ => null,
        },
        statementOpeningBalance: _reconMoney(j['statement_opening_balance']),
        statementClosingBalance: _reconMoney(j['statement_closing_balance']),
        computedClosingBalance: _reconMoney(j['computed_closing_balance']),
        difference: _reconMoney(j['difference']),
        incomingRows: (j['incoming_rows'] as num?)?.toInt() ?? 0,
        duplicateRows: (j['duplicate_rows'] as num?)?.toInt() ?? 0,
        existingRowsInPeriod:
            (j['existing_rows_in_period'] as num?)?.toInt() ?? 0,
        candidates: ((j['candidates'] as List?) ?? const [])
            .whereType<Map>()
            .map((c) => ReconcileCandidate.fromJson(c.cast<String, dynamic>()))
            .toList(),
      );

  final String file;

  /// ISO `YYYY-MM-DD` bounds of the rows in this file.
  final String periodStart;
  final String periodEnd;

  /// The statement's single currency, or null when its rows disagree.
  final String? currency;
  final ReconcileStatus status;
  final ReconcileUnavailableReason? unavailableReason;
  final double? statementOpeningBalance;
  final double? statementClosingBalance;
  final double? computedClosingBalance;

  /// `statementClosingBalance − computedClosingBalance`. Positive means the
  /// app is SHORT of the bank.
  final double? difference;
  final int incomingRows;
  final int duplicateRows;
  final int existingRowsInPeriod;
  final List<ReconcileCandidate> candidates;
}

/// Per-account roll-up: one entry per statement file plus a worst-of
/// verdict (the backend ranks `unavailable` ABOVE both green states).
class AccountReconciliation {
  const AccountReconciliation({
    required this.accountId,
    required this.accountName,
    required this.currency,
    required this.status,
    this.statements = const [],
  });

  factory AccountReconciliation.fromJson(Map<String, dynamic> j) =>
      AccountReconciliation(
        accountId: (j['account_id'] ?? '').toString(),
        accountName: (j['account_name'] ?? '').toString(),
        currency: (j['currency'] ?? '').toString(),
        status: reconcileStatusFromWire(j['status']),
        statements: ((j['statements'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (s) =>
                  StatementReconciliation.fromJson(s.cast<String, dynamic>()),
            )
            .toList(),
      );

  final String accountId;
  final String accountName;
  final String currency;
  final ReconcileStatus status;
  final List<StatementReconciliation> statements;
}

/// Wire (`snake_case`) → [ReconcileStatus]. An unrecognized value falls
/// back to [ReconcileStatus.unavailable] — "we can't say" — never to a
/// green state.
ReconcileStatus reconcileStatusFromWire(Object? wire) =>
    switch ((wire ?? '').toString()) {
      'reconciled' => ReconcileStatus.reconciled,
      'reconciled_after_duplicate_skip' =>
        ReconcileStatus.reconciledAfterDuplicateSkip,
      'explained_by_existing_transactions' =>
        ReconcileStatus.explainedByExistingTransactions,
      'unexplained' => ReconcileStatus.unexplained,
      _ => ReconcileStatus.unavailable,
    };

/// Money off the wire. `rust_decimal` is built with `serde-float` so these
/// arrive as JSON numbers, but a string is accepted too rather than
/// silently reading as null.
double? _reconMoney(Object? v) => switch (v) {
  final num n => n.toDouble(),
  final String s => double.tryParse(s),
  _ => null,
};
