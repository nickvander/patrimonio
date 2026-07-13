import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/api_platform_io.dart';

// Serialization halves of the native session-persistence path (the keystore
// I/O itself is plugin-backed and inert under the test VM — see
// initSessionPersistence's init()-gating). Pinned here: the Max-Age→absolute
// expiry conversion (the backend's session cookie carries Max-Age only) and
// the restore-side dropping of expired/malformed entries, so an app relaunch
// can never resurrect a cookie the server would reject on age.

void main() {
  group('encodeJarCookies', () {
    test('round-trips name/value and keeps an absolute expiry', () {
      final expiry = DateTime.utc(2026, 8, 12, 5);
      final cookie = Cookie('patrimonio_session', 'tok-123')..expires = expiry;

      final decoded =
          decodePersistedCookies(encodeJarCookies([cookie]), DateTime(2026, 7, 13));

      expect(decoded, hasLength(1));
      expect(decoded.single.name, 'patrimonio_session');
      expect(decoded.single.value, 'tok-123');
      expect(decoded.single.expires, expiry);
    });

    test('converts Max-Age-only cookies to an absolute expiry', () {
      // The backend's build_session_cookie sets Max-Age (30d), not Expires.
      final cookie = Cookie('patrimonio_session', 'tok-456')
        ..maxAge = 30 * 24 * 3600;

      final payload = encodeJarCookies([cookie]);
      final entry = (jsonDecode(payload) as List).single as Map;
      final stamped = DateTime.parse(entry['expires'] as String);

      final expectedMin = DateTime.now().toUtc().add(const Duration(days: 29));
      expect(stamped.isAfter(expectedMin), isTrue,
          reason: 'Max-Age should become now + 30d');
    });
  });

  group('decodePersistedCookies', () {
    test('drops entries already expired at restore time', () {
      final live = Cookie('a', '1')..expires = DateTime.utc(2026, 12, 1);
      final dead = Cookie('b', '2')..expires = DateTime.utc(2026, 1, 1);

      final decoded = decodePersistedCookies(
          encodeJarCookies([live, dead]), DateTime.utc(2026, 7, 13));

      expect(decoded.map((c) => c.name), ['a']);
    });

    test('survives malformed payloads without throwing', () {
      expect(decodePersistedCookies('not json at all…', DateTime(2026)),
          isEmpty);
      expect(decodePersistedCookies('{"a":1}', DateTime(2026)), isEmpty);
      expect(
          decodePersistedCookies(
              '[{"name":"","value":"x"},{"value":"no-name"},42]',
              DateTime(2026)),
          isEmpty);
    });
  });
}
