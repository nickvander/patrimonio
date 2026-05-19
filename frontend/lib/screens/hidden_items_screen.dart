import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/theme_colors.dart';

/// Unified panel for everything the user has dismissed across the app —
/// "ignored" subscriptions, the since-last-login banner suppression, etc.
/// Each section exposes per-row un-dismiss actions and an empty state.
///
/// Reached from the dashboard's app-bar visibility icon next to Security.
///
/// V1 scope:
/// * Ignored subscription merchants (backed by
///   `ignored_subscription_merchants` server-side).
/// * Since-last-login banner (single-row, stored in localStorage).
///
/// FX-transfer "never re-suggest this pair" is not surfaced here — today
/// the detector just doesn't have a permanent-ignore concept; the
/// existing per-pair unlink button on the dashboard is enough. See
/// `work/FUTURE.md` section D.
class HiddenItemsScreen extends StatefulWidget {
  const HiddenItemsScreen({super.key});

  @override
  State<HiddenItemsScreen> createState() => _HiddenItemsScreenState();
}

class _HiddenItemsScreenState extends State<HiddenItemsScreen> {
  final _api = ApiService();
  bool _loading = true;
  String? _error;
  List<dynamic> _ignoredSubs = const [];
  String? _sinceLastLoginAnchor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ignored = await _api.getIgnoredSubscriptions();
      if (!mounted) return;
      setState(() {
        _ignoredSubs = ignored;
        _sinceLastLoginAnchor =
            Preferences.getSinceLastLoginDismissalAnchor();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unignoreSub(String merchantKey) async {
    try {
      await _api.unignoreSubscription(merchantKey);
      if (!mounted) return;
      setState(() {
        _ignoredSubs = _ignoredSubs
            .where((row) => (row as Map)['merchant_key'] != merchantKey)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restored "$merchantKey"')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restore: $e')),
      );
    }
  }

  void _restoreSinceLastLoginBanner() {
    Preferences.clearSinceLastLoginDismissal();
    setState(() => _sinceLastLoginAnchor = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Since-last-login banner will reappear.')),
    );
  }

  String _formatIgnoredAt(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    return DateFormat.yMMMd().add_jm().format(dt.toLocal());
  }

  String _formatAnchor(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMMMd().add_jm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final hasDismissedSinceLastLogin =
        (_sinceLastLoginAnchor ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Hidden items')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 16),
                  children: [
                    Text(
                      'Things you told Patrimonio to stop showing. '
                      'Restoring a row brings it back where it normally lives.',
                      style: TextStyle(
                        color: context.textSubtle,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _sectionHeader(
                      icon: Icons.autorenew_rounded,
                      title: 'Recurring charges',
                      count: _ignoredSubs.length,
                    ),
                    if (_ignoredSubs.isEmpty)
                      _emptyTile(
                        'No subscriptions are currently hidden. '
                        'When you dismiss a row with × on the Recurring '
                        'charges card it shows up here.',
                      )
                    else
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < _ignoredSubs.length; i++) ...[
                              if (i > 0)
                                Divider(height: 1, color: context.hairline),
                              _ignoredSubTile(
                                _ignoredSubs[i] as Map<String, dynamic>,
                              ),
                            ],
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),
                    _sectionHeader(
                      icon: Icons.notifications_off_outlined,
                      title: 'Banners',
                      count: hasDismissedSinceLastLogin ? 1 : 0,
                    ),
                    if (!hasDismissedSinceLastLogin)
                      _emptyTile(
                        'No banners are currently dismissed.',
                      )
                    else
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.history_outlined),
                          title: const Text('Since last login'),
                          subtitle: Text(
                            'Hidden for the visit starting '
                            '${_formatAnchor(_sinceLastLoginAnchor!)}',
                            style: TextStyle(
                              color: context.textSubtle,
                              fontSize: 12,
                            ),
                          ),
                          trailing: TextButton.icon(
                            onPressed: _restoreSinceLastLoginBanner,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Show again'),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _sectionHeader({
    required IconData icon,
    required String title,
    required int count,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.textMuted),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '($count)',
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
        ],
      ),
    );
  }

  Widget _emptyTile(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        message,
        style: TextStyle(color: context.textSubtle, fontSize: 12),
      ),
    );
  }

  Widget _ignoredSubTile(Map<String, dynamic> row) {
    final key = (row['merchant_key'] ?? '').toString();
    final at = (row['ignored_at'] ?? '').toString();
    return ListTile(
      dense: true,
      leading: const Icon(Icons.visibility_off_outlined, size: 18),
      title: Text(
        // merchant_key is stored lowercased so the detector can match
        // case-insensitively; display it title-cased so the row looks
        // less like a database dump. First-letter-of-each-word is fine
        // for the Latin merchant strings we see in practice.
        _toTitleCase(key),
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: at.isEmpty
          ? null
          : Text(
              'Dismissed ${_formatIgnoredAt(at)}',
              style: TextStyle(color: context.textSubtle, fontSize: 11),
            ),
      trailing: TextButton.icon(
        onPressed: () => _unignoreSub(key),
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Restore'),
      ),
    );
  }

  String _toTitleCase(String s) {
    if (s.isEmpty) return s;
    return s
        .split(' ')
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}
