import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/backend_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('BackendConfig.normalize', () {
    test('strips trailing slashes', () {
      expect(
        BackendConfig.normalize('https://x.example.com/'),
        'https://x.example.com',
      );
      expect(
        BackendConfig.normalize('https://x.example.com///'),
        'https://x.example.com',
      );
    });

    test('strips an accidentally pasted /api suffix', () {
      expect(
        BackendConfig.normalize('https://x.example.com/api'),
        'https://x.example.com',
      );
      expect(
        BackendConfig.normalize('https://x.example.com/api/'),
        'https://x.example.com',
      );
    });

    test('keeps ports and non-/api paths', () {
      expect(
        BackendConfig.normalize('https://x.example.com:8443'),
        'https://x.example.com:8443',
      );
      expect(
        BackendConfig.normalize('https://x.example.com/patrimonio'),
        'https://x.example.com/patrimonio',
      );
    });
  });

  group('BackendConfig.validationError', () {
    test('accepts http and https URLs', () {
      expect(BackendConfig.validationError('https://x.example.com'), isNull);
      expect(BackendConfig.validationError('http://10.0.0.5:8080'), isNull);
    });

    test('rejects missing scheme, bad scheme, and empty host', () {
      expect(BackendConfig.validationError('x.example.com'), isNotNull);
      expect(BackendConfig.validationError('ftp://x.example.com'), isNotNull);
      expect(BackendConfig.validationError(''), isNotNull);
    });
  });

  group('BackendConfig persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await BackendConfig.clear();
    });

    test('save + load round-trips the URL and CF Access token', () async {
      await BackendConfig.save(
        'https://x.example.com/',
        cfClientId: 'id.access',
        cfClientSecret: 's3cret',
      );
      expect(BackendConfig.baseUrl, 'https://x.example.com');
      expect(BackendConfig.hasCfAccessToken, isTrue);

      // Wipe the in-memory state, then reload from the (mock) store.
      BackendConfig.cfAccessClientId = null;
      BackendConfig.cfAccessClientSecret = null;
      await BackendConfig.load();
      expect(BackendConfig.cfAccessClientId, 'id.access');
      expect(BackendConfig.cfAccessClientSecret, 's3cret');
    });

    test('saving without a token clears a previously stored one', () async {
      await BackendConfig.save(
        'https://x.example.com',
        cfClientId: 'id.access',
        cfClientSecret: 's3cret',
      );
      await BackendConfig.save('https://x.example.com');
      expect(BackendConfig.hasCfAccessToken, isFalse);
      await BackendConfig.load();
      expect(BackendConfig.cfAccessClientId, isNull);
    });

    test('a half-entered token pair does not count as configured', () {
      BackendConfig.cfAccessClientId = 'id.access';
      BackendConfig.cfAccessClientSecret = '';
      expect(BackendConfig.hasCfAccessToken, isFalse);
    });

    test('clear removes URL and token', () async {
      await BackendConfig.save(
        'https://x.example.com',
        cfClientId: 'id.access',
        cfClientSecret: 's3cret',
      );
      await BackendConfig.clear();
      expect(BackendConfig.baseUrl, isNull);
      expect(BackendConfig.hasCfAccessToken, isFalse);
    });
  });
}
