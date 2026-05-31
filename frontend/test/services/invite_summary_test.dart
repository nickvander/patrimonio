import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/auth_service.dart';

/// Covers the role wiring added so the Security screen can mint and
/// audit read-only invites. The backend returns `role` on every
/// invite row; older backends that predate the column omit it, so the
/// parser must default to 'owner' (the historical contract).
void main() {
  Map<String, dynamic> base() => {
        'id': 'abc',
        'created_at': '2026-05-30T00:00:00Z',
        'expires_at': '2026-06-30T00:00:00Z',
        'used': false,
      };

  group('InviteSummary.role', () {
    test('parses an explicit read_only role', () {
      final inv = InviteSummary.fromJson({...base(), 'role': 'read_only'});
      expect(inv.role, 'read_only');
      expect(inv.isReadOnly, isTrue);
    });

    test('parses an explicit owner role', () {
      final inv = InviteSummary.fromJson({...base(), 'role': 'owner'});
      expect(inv.role, 'owner');
      expect(inv.isReadOnly, isFalse);
    });

    test('defaults to owner when the backend omits role', () {
      final inv = InviteSummary.fromJson(base());
      expect(inv.role, 'owner');
      expect(inv.isReadOnly, isFalse);
    });
  });
}
