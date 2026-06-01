// VM/non-web implementation of the [ApiService] platform seam. Used under
// `flutter test`, where there is no browser. These values are only ever
// reached if a test exercises the real network path (it shouldn't —
// tests inject fakes), so a plain client + localhost host suffice.
import 'package:http/http.dart' as http;

String currentHost() => 'localhost';

// VM stubs — never used against a real server (tests inject fakes).
String apiBaseUrl() => 'http://localhost:3000/api';

String apiWsUrl() => 'ws://localhost:3000/api/realtime/ws';

Map<String, String> apiExtraHeaders() => const {};

http.Client createApiClient() => http.Client();
