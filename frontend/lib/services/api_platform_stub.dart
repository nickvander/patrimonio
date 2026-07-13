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

Map<String, String> wsHandshakeHeaders() => const {};

http.Client createApiClient() => http.Client();

/// Session persistence is a native concern (in-memory jar + keystore); the
/// VM stub has no session to persist.
Future<void> initSessionPersistence() async {}

Future<void> clearPersistedSession() async {}
