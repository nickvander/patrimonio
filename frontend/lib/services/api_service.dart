import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

class ApiService {
  String get _baseUrl {
    // Dynamically detect host to support VM/Docker test networks correctly
    final host = web.window.location.hostname.isEmpty
        ? 'localhost'
        : web.window.location.hostname;
    return 'http://$host:8080/api';
  }

  String get baseUrl => _baseUrl;

  Future<Map<String, dynamic>> getDashboardOverview() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/overview'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load dashboard overview');
  }

  Future<List<dynamic>> getNetWorthHistory() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/dashboard/net-worth-history'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load net worth history');
  }

  Future<List<dynamic>> getAllocationData() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/dashboard/allocation'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load allocation data');
  }

  Future<List<dynamic>> getTrendData() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/trends'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load trend data');
  }

  Future<Map<String, dynamic>> getHoldings() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/holdings'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load holdings');
  }

  Future<List<dynamic>> getCreditUtilization() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/dashboard/credit-utilization'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load credit utilization');
  }

  Future<List<dynamic>> getSyncStatus() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/dashboard/sync-status'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load sync status');
  }

  Future<Map<String, dynamic>> getSetupStatus() async {
    final response = await http.get(Uri.parse('$_baseUrl/setup/status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load setup status');
  }

  Future<Map<String, dynamic>> getExchangeRate(
    String base,
    String target, {
    bool force = false,
  }) async {
    final query = force ? '?force=true' : '';
    final response = await http.get(
      Uri.parse('$_baseUrl/fx/latest/$base/$target$query'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load exchange rate');
  }

  Future<List<dynamic>> getTransactions({int limit = 50, int offset = 0}) async {
    final response = await http.get(
      Uri.parse(
          '$_baseUrl/dashboard/transactions?limit=$limit&offset=$offset'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load transactions');
  }

  Future<List<dynamic>> getAccountTransactions(String accountId) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/accounts/$accountId/transactions'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load account transactions');
  }

  Future<void> syncInstitutions() async {
    final response = await http.post(Uri.parse('$_baseUrl/institutions/sync'));
    if (response.statusCode != 200) {
      throw Exception('Failed to sync institutions');
    }
  }

  Future<Map<String, dynamic>> getReconnectToken(String institutionId) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/institutions/reconnect-token/$institutionId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to retrieve reconnect token');
  }

  Future<void> deleteInstitution(String institutionId) async {
    final response = await http.delete(
      Uri.parse('$_baseUrl/institutions/$institutionId'),
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete institution');
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
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception(
          'Server returned ${response.statusCode}: ${response.body}',
        );
      }
    } on http.ClientException catch (e) {
      throw Exception(
        'Network error during upload. Please check your connection and try again. ($e)',
      );
    } catch (e) {
      throw Exception('Upload failed: $e');
    }
  }

  Future<Map<String, dynamic>> confirmImport(
    String accountId,
    List<dynamic> transactions,
  ) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/imports/confirm'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'account_id': accountId,
        'transactions': transactions,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Confirmation failed: ${response.body}');
    }
  }

  Future<void> updateAccountBalance(String accountId, double balance) async {
    final response = await http.patch(
      Uri.parse('$_baseUrl/accounts/$accountId/balance'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'current_balance': balance}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update balance');
    }
  }

  Future<void> deleteAccount(String accountId) async {
    final response = await http.delete(Uri.parse('$_baseUrl/accounts/$accountId'));
    if (response.statusCode != 204) {
      throw Exception('Failed to delete account');
    }
  }

  /// Set or clear a user-defined nickname for an account. An empty
  /// nickname clears the override so display falls back to the
  /// bank-supplied name.
  Future<void> renameAccount(String accountId, String nickname) async {
    final response = await http.patch(
      Uri.parse('$_baseUrl/accounts/$accountId/nickname'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'nickname': nickname}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to rename account');
    }
  }

  Future<void> updateTransaction(
    String txId, {
    String? userCategory,
    String? userNotes,
    String? accountId,
  }) async {
    final body = <String, dynamic>{};
    if (userCategory != null) body['user_category'] = userCategory;
    if (userNotes != null) body['user_notes'] = userNotes;
    if (accountId != null) body['account_id'] = accountId;

    final response = await http.patch(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update transaction');
    }
  }

  /// URL of the CSV export endpoint. We hand this to the browser via an
  /// anchor click rather than fetching + blobbing in Dart — the backend
  /// returns Content-Disposition: attachment so the browser downloads
  /// directly without using extra memory.
  String exportTransactionsCsvUrl() => '$_baseUrl/dashboard/transactions/export';

  /// Insert a manually-entered transaction. Positive amount = expense /
  /// outflow, negative = income / inflow (same convention as Plaid).
  Future<void> createManualTransaction({
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
      'date': '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
      'description': description,
      'amount': amount,
      'currency': currency,
      if (category != null && category.isNotEmpty) 'category': category,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };
    final response = await http.post(
      Uri.parse('$_baseUrl/dashboard/transactions/manual'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode == 409) {
      throw Exception('Already added — same date / amount / description.');
    }
    if (response.statusCode != 201) {
      throw Exception('Failed to add transaction: ${response.body}');
    }
  }

  Future<void> deleteTransaction(String txId) async {
    final response = await http.delete(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception('Failed to delete transaction (${response.statusCode})');
    }
  }

  Future<void> createAccount({
    required String name,
    required String type,
    required String currency,
    required double initialBalance,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/accounts'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'name': name,
        'account_type': type,
        'currency': currency,
        'initial_balance': initialBalance,
      }),
    );
    if (response.statusCode != 201) {
      throw Exception('Failed to create account: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getWealthProjection({
    required double startBalance,
    required double monthlyContribution,
    required double annualReturnRate,
    required double annualExpenses,
    required double withdrawalRate,
    int years = 30,
  }) async {
    final queryParams = {
      'start_balance': startBalance.toString(),
      'monthly_contribution': monthlyContribution.toString(),
      'annual_return_rate': annualReturnRate.toString(),
      'annual_expenses': annualExpenses.toString(),
      'withdrawal_rate': withdrawalRate.toString(),
      'years': years.toString(),
    };

    final uri = Uri.parse(
      '$_baseUrl/projections/calculate',
    ).replace(queryParameters: queryParams);
    final response = await http.get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load wealth projection');
  }

  Future<void> linkCryptoInstitution({
    required String name,
    required String integrationType,
    required String apiKey,
    required String apiSecret,
    String? apiPass,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/institutions/crypto'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'name': name,
        'integration_type': integrationType,
        'api_key': apiKey,
        'api_secret': apiSecret,
        'api_pass': apiPass,
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception('Failed to link crypto: ${response.body}');
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
    final response = await http.get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load tax summary');
  }

  Future<List<dynamic>> getTaxTransactions({int? year}) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();

    final uri = Uri.parse(
      '$_baseUrl/tax/transactions',
    ).replace(queryParameters: queryParams);
    final response = await http.get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load tax transactions');
  }

  /// Generic app-setting store. The backend returns JSON null when the
  /// key has never been written; callers should treat that as "absent".
  /// Sync a single institution. Cheaper than the global sync when only
  /// one or two institutions are stuck.
  Future<void> syncInstitution(String institutionId) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/institutions/$institutionId/sync'),
    );
    if (response.statusCode != 200) {
      throw Exception('Sync failed: ${response.statusCode}');
    }
  }

  /// Sync an arbitrary set of institutions in one round-trip. Replaces
  /// the client-side loop the "Retry N failed" shortcut used to do.
  Future<void> syncInstitutionsBatch(List<String> institutionIds) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/institutions/sync'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'ids': institutionIds}),
    );
    if (response.statusCode != 200) {
      throw Exception('Batched sync failed: ${response.statusCode}');
    }
  }

  Future<dynamic> getSetting(String key) async {
    final response =
        await http.get(Uri.parse('$_baseUrl/settings/$key'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load setting $key');
  }

  Future<void> putSetting(String key, dynamic value) async {
    final response = await http.put(
      Uri.parse('$_baseUrl/settings/$key'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(value),
    );
    if (response.statusCode != 200) {
      throw Exception(
          'Failed to save setting $key (${response.statusCode})');
    }
  }
}
