import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;
import 'auth_service.dart';

/// Thrown when the server returns 401. The auth gate listens for this
/// indirectly via AuthService.handleUnauthorized().
class UnauthorizedException implements Exception {
  final String message;
  UnauthorizedException([this.message = 'Authentication required']);
  @override
  String toString() => message;
}

class ApiService {
  String get _baseUrl {
    final host = web.window.location.hostname.isEmpty
        ? 'localhost'
        : web.window.location.hostname;
    return 'http://$host:8080/api';
  }

  String get baseUrl => _baseUrl;

  /// Shared credentialed HTTP client. `withCredentials` is required for
  /// the browser to send (and accept) the session cookie on cross-origin
  /// XHRs in development, and is harmless in same-origin production.
  static final BrowserClient _client = BrowserClient()..withCredentials = true;

  Future<http.Response> _get(Uri uri) async {
    final res = await _client.get(uri);
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _post(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.post(uri, body: body, headers: headers);
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _patch(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.patch(uri, body: body, headers: headers);
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _delete(Uri uri) async {
    final res = await _client.delete(uri);
    _maybeUnauthorized(res);
    return res;
  }

  void _maybeUnauthorized(http.Response res) {
    if (res.statusCode == 401) {
      AuthService.instance.handleUnauthorized();
      throw UnauthorizedException();
    }
  }

  // ----- auth -----

  Future<Map<String, dynamic>> authStatus() async {
    final res = await _client.get(Uri.parse('$_baseUrl/auth/status'));
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to load auth status (${res.statusCode})');
  }

  Future<AuthUser> login(String username, String password) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'username': username, 'password': password}),
    );
    if (res.statusCode == 200) {
      return AuthUser.fromJson(json.decode(res.body) as Map<String, dynamic>);
    }
    throw _errorFromBody(res, fallback: 'Login failed');
  }

  Future<AuthUser> bootstrap({
    required String username,
    String? email,
    required String password,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/bootstrap'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'username': username,
        'email': email,
        'password': password,
      }),
    );
    if (res.statusCode == 200) {
      return AuthUser.fromJson(json.decode(res.body) as Map<String, dynamic>);
    }
    throw _errorFromBody(res, fallback: 'Bootstrap failed');
  }

  Future<void> logout() async {
    final res = await _client.post(Uri.parse('$_baseUrl/auth/logout'));
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw _errorFromBody(res, fallback: 'Logout failed');
    }
  }

  Future<void> changePassword(String currentPassword, String newPassword) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/change-password'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'current_password': currentPassword,
        'new_password': newPassword,
      }),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res, fallback: 'Password change failed');
    }
  }

  Exception _errorFromBody(http.Response res, {required String fallback}) {
    try {
      final body = json.decode(res.body);
      if (body is Map && body['error'] is String) {
        return Exception(body['error'] as String);
      }
    } catch (_) {}
    return Exception('$fallback (${res.statusCode})');
  }

  // ----- existing endpoints (now credentialed) -----

  Future<Map<String, dynamic>> getDashboardOverview() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/overview'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load dashboard overview');
  }

  Future<List<dynamic>> getNetWorthHistory() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/net-worth-history'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load net worth history');
  }

  Future<List<dynamic>> getAllocationData() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/allocation'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load allocation data');
  }

  Future<List<dynamic>> getTrendData() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/trends'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load trend data');
  }

  Future<Map<String, dynamic>> getHoldings() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/holdings'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load holdings');
  }

  Future<List<dynamic>> getCreditUtilization() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/credit-utilization'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load credit utilization');
  }

  Future<List<dynamic>> getSyncStatus() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/sync-status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load sync status');
  }

  Future<Map<String, dynamic>> getSetupStatus() async {
    // Setup status is a public endpoint — used by the login screen — so
    // we still send credentials but the server does not require them.
    final response = await _client.get(Uri.parse('$_baseUrl/setup/status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load setup status');
  }

  Future<Map<String, dynamic>> getExchangeRate(
    String base,
    String target,
  ) async {
    final response = await _get(Uri.parse('$_baseUrl/fx/latest/$base/$target'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load exchange rate');
  }

  Future<List<dynamic>> getTransactions() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/transactions'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load transactions');
  }

  Future<List<dynamic>> getAccountTransactions(String accountId) async {
    final response = await _get(
      Uri.parse('$_baseUrl/accounts/$accountId/transactions'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load account transactions');
  }

  Future<void> syncInstitutions() async {
    final response = await _post(Uri.parse('$_baseUrl/institutions/sync'));
    if (response.statusCode != 200) {
      throw Exception('Failed to sync institutions');
    }
  }

  Future<Map<String, dynamic>> getReconnectToken(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/reconnect-token/$institutionId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to retrieve reconnect token');
  }

  Future<void> deleteInstitution(String institutionId) async {
    final response = await _delete(
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
      final streamedResponse = await _client.send(request).timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamedResponse);
      _maybeUnauthorized(response);

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
    final response = await _post(
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
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/$accountId/balance'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'current_balance': balance}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update balance');
    }
  }

  Future<void> deleteAccount(String accountId) async {
    final response = await _delete(Uri.parse('$_baseUrl/accounts/$accountId'));
    if (response.statusCode != 204) {
      throw Exception('Failed to delete account');
    }
  }

  Future<void> updateTransaction(
    String txId, {
    String? userCategory,
    String? userNotes,
  }) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'user_category': userCategory,
        'user_notes': userNotes,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update transaction');
    }
  }

  Future<void> createAccount({
    required String name,
    required String type,
    required String currency,
    required double initialBalance,
  }) async {
    final response = await _post(
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
    final response = await _get(uri);

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
    final response = await _post(
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
    final response = await _get(uri);

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
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load tax transactions');
  }
}
