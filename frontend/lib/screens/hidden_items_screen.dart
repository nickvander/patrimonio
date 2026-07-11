import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/currency.dart';
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
  List<dynamic> _dismissedFxPairs = const [];
  List<dynamic> _archivedAccounts = const [];
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
      // Run both lookups concurrently — they're independent and one
      // taking longer shouldn't block the other from rendering.
      final results = await Future.wait([
        _api.getIgnoredSubscriptions(),
        _api.getDismissedFxPairs(),
        _api.getArchivedAccounts(),
      ]);
      if (!mounted) return;
      setState(() {
        _ignoredSubs = results[0];
        _dismissedFxPairs = results[1];
        _archivedAccounts = results[2];
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
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.hiddenRestoredMerchant(merchantKey))),
      );
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.hiddenRestoreFailed(e.toString()))),
      );
    }
  }

  void _restoreSinceLastLoginBanner() {
    Preferences.clearSinceLastLoginDismissal();
    setState(() => _sinceLastLoginAnchor = null);
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l.hiddenBannerWillReappear)),
    );
  }

  Future<void> _restoreFxPair(String id, String summary) async {
    try {
      await _api.restoreDismissedFxPair(id);
      if (!mounted) return;
      setState(() {
        _dismissedFxPairs = _dismissedFxPairs
            .where((row) => (row as Map)['id'] != id)
            .toList();
      });
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.hiddenFxPairRestored(summary)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.hiddenRestoreFailed(e.toString()))),
      );
    }
  }

  Future<void> _restoreAccount(String id, String label) async {
    try {
      await _api.restoreAccount(id);
      if (!mounted) return;
      setState(() {
        _archivedAccounts = _archivedAccounts
            .where((row) => (row as Map)['id'].toString() != id)
            .toList();
      });
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.accountRestored(label))),
      );
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.hiddenRestoreFailed(e.toString()))),
      );
    }
  }

  Future<void> _deleteAccountPermanently(String id, String label) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.accountDeleteConfirmTitle),
        content: Text(l.accountDeleteConfirmBody(label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.accountDeletePermanently),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteAccount(id);
      if (!mounted) return;
      setState(() {
        _archivedAccounts = _archivedAccounts
            .where((row) => (row as Map)['id'].toString() != id)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.accountDeleted(label))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.hiddenRestoreFailed(e.toString()))),
      );
    }
  }

  String _formatClosedDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    return DateFormat.yMMMd().format(dt.toLocal());
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
    final l = AppLocalizations.of(context);
    final hasDismissedSinceLastLogin =
        (_sinceLastLoginAnchor ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(l.hiddenTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 16),
                  children: [
                    Text(
                      l.hiddenIntro,
                      style: TextStyle(
                        color: context.textSubtle,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _sectionHeader(
                      icon: Icons.autorenew_rounded,
                      title: l.hiddenRecurringCharges,
                      count: _ignoredSubs.length,
                    ),
                    if (_ignoredSubs.isEmpty)
                      _emptyTile(
                        l.hiddenNoSubscriptions,
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
                      title: l.hiddenBanners,
                      count: hasDismissedSinceLastLogin ? 1 : 0,
                    ),
                    if (!hasDismissedSinceLastLogin)
                      _emptyTile(
                        l.hiddenNoBanners,
                      )
                    else
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.history_outlined),
                          title: Text(l.hiddenSinceLastLogin),
                          subtitle: Text(
                            l.hiddenHiddenForVisit(
                                _formatAnchor(_sinceLastLoginAnchor!)),
                            style: TextStyle(
                              color: context.textSubtle,
                              fontSize: 12,
                            ),
                          ),
                          trailing: TextButton.icon(
                            onPressed: _restoreSinceLastLoginBanner,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: Text(l.hiddenShowAgain),
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    _sectionHeader(
                      icon: Icons.swap_horiz_outlined,
                      title: l.hiddenFxTransferPairs,
                      count: _dismissedFxPairs.length,
                    ),
                    if (_dismissedFxPairs.isEmpty)
                      _emptyTile(
                        l.hiddenNoFxPairs,
                      )
                    else
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < _dismissedFxPairs.length; i++) ...[
                              if (i > 0)
                                Divider(height: 1, color: context.hairline),
                              _dismissedFxTile(
                                _dismissedFxPairs[i] as Map<String, dynamic>,
                              ),
                            ],
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),
                    _sectionHeader(
                      icon: Icons.account_balance_outlined,
                      title: l.hiddenClosedAccounts,
                      count: _archivedAccounts.length,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        l.hiddenClosedAccountsIntro,
                        style: TextStyle(
                          color: context.textSubtle,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (_archivedAccounts.isEmpty)
                      _emptyTile(
                        l.hiddenNoClosedAccounts,
                      )
                    else
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0;
                                i < _archivedAccounts.length;
                                i++) ...[
                              if (i > 0)
                                Divider(height: 1, color: context.hairline),
                              _archivedAccountTile(
                                _archivedAccounts[i] as Map<String, dynamic>,
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _archivedAccountTile(Map<String, dynamic> row) {
    final l = AppLocalizations.of(context);
    final id = (row['id'] ?? '').toString();
    final institution = (row['institution_name'] ?? '').toString();
    final nickname = (row['nickname'] ?? '').toString();
    final name = (row['name'] ?? '').toString();
    // Mirror COALESCE(nickname, name): a user-set nickname wins.
    final displayName = nickname.isNotEmpty ? nickname : name;
    final accountType = (row['account_type'] ?? '').toString();
    final currency = (row['currency'] ?? 'USD').toString();
    final balance = (row['current_balance'] as num?)?.toDouble() ?? 0.0;
    final archivedAt = (row['archived_at'] ?? '').toString();

    final title = institution.isEmpty
        ? displayName
        : '$institution · $displayName';
    final metaParts = <String>[
      if (accountType.isNotEmpty) accountType,
      displayCurrencyWithCode(balance, currency),
      if (archivedAt.isNotEmpty)
        l.accountClosedOn(_formatClosedDate(archivedAt)),
    ];

    return ListTile(
      dense: true,
      leading: const Icon(Icons.account_balance_outlined, size: 18),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: metaParts.isEmpty
          ? null
          : Text(
              metaParts.join(' · '),
              style: TextStyle(color: context.textSubtle, fontSize: 11),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: () => _restoreAccount(id, displayName),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(l.accountRestore),
          ),
          IconButton(
            tooltip: l.accountDeletePermanently,
            onPressed: () => _deleteAccountPermanently(id, displayName),
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: context.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dismissedFxTile(Map<String, dynamic> row) {
    final l = AppLocalizations.of(context);
    final id = (row['id'] ?? '').toString();
    final srcLabel = (row['source_label'] ?? '—').toString();
    final dstLabel = (row['dest_label'] ?? '—').toString();
    final srcCcy = (row['source_currency'] ?? '').toString();
    final dstCcy = (row['dest_currency'] ?? '').toString();
    final srcAmt = (row['source_amount'] as num?)?.toDouble().abs() ?? 0.0;
    final dstAmt = (row['dest_amount'] as num?)?.toDouble().abs() ?? 0.0;
    final dismissedAt = (row['dismissed_at'] ?? '').toString();
    final srcFmt = NumberFormat.currency(name: srcCcy, symbol: '$srcCcy ');
    final dstFmt = NumberFormat.currency(name: dstCcy, symbol: '$dstCcy ');
    final summary = '$srcLabel → $dstLabel';
    return ListTile(
      dense: true,
      leading: const Icon(Icons.swap_horiz, size: 18),
      title: Text(summary, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        '${srcFmt.format(srcAmt)} → ${dstFmt.format(dstAmt)}'
        '${dismissedAt.isEmpty ? '' : ' · ${l.hiddenDismissedAt(_formatIgnoredAt(dismissedAt))}'}',
        style: TextStyle(color: context.textSubtle, fontSize: 11),
      ),
      trailing: TextButton.icon(
        onPressed: () => _restoreFxPair(id, summary),
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(l.hiddenRestore),
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
    final l = AppLocalizations.of(context);
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
              l.hiddenDismissedAt(_formatIgnoredAt(at)),
              style: TextStyle(color: context.textSubtle, fontSize: 11),
            ),
      trailing: TextButton.icon(
        onPressed: () => _unignoreSub(key),
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(l.hiddenRestore),
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
