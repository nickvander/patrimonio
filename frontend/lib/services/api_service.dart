import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

class ApiService {
  String get _baseUrl {
    // Dynamically detect host to support VM/Docker test networks correctly
    final host = web.window.location.hostname.isEmpty ? 'localhost' : web.window.location.hostname;
    return 'http://$host:8080/api';
  }

  Future<Map<String, dynamic>> getDashboardOverview() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/overview'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load dashboard overview');
  }

  Future<List<dynamic>> getNetWorthHistory() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/net-worth-history'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load net worth history');
  }

  Future<Map<String, dynamic>> getHoldings() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/holdings'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load holdings');
  }

  Future<List<dynamic>> getCreditUtilization() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/credit-utilization'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load credit utilization');
  }

  Future<List<dynamic>> getSyncStatus() async {
    final response = await http.get(Uri.parse('$_baseUrl/dashboard/sync-status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load sync status');
  }

  Future<Map<String, dynamic>> getExchangeRate(String base, String target) async {
    final response = await http.get(Uri.parse('$_baseUrl/fx/latest/$base/$target'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load exchange rate');
  }

  Future<void> syncInstitutions() async {
    final response = await http.post(Uri.parse('$_baseUrl/institutions/sync'));
    if (response.statusCode != 200) {
      throw Exception('Failed to sync institutions');
    }
  }
}
