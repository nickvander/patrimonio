import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AccountsBreakdownCard extends StatelessWidget {
  final List<dynamic> typeBreakdown;
  final List<dynamic> institutionBreakdown;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const AccountsBreakdownCard({
    super.key,
    required this.typeBreakdown,
    required this.institutionBreakdown,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Asset breakdown',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            LayoutBuilder(
              builder: (context, constraints) {
                // Stack vertically when there isn't enough room to give
                // each section a readable amount of space side-by-side.
                final isNarrow = constraints.maxWidth < 560;
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTypeSection(),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12, height: 1),
                      const SizedBox(height: 24),
                      _buildInstitutionSection(),
                    ],
                  );
                }
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildTypeSection()),
                      const VerticalDivider(width: 32, color: Colors.white12),
                      Expanded(child: _buildInstitutionSection()),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Convert raw account_type strings like "checking" / "credit_card" /
  /// "investment" into a clean sentence-case display value.
  String _prettyType(String raw) {
    if (raw.isEmpty) return 'Other';
    final normalised = raw.replaceAll('_', ' ').replaceAll('-', ' ').trim();
    return normalised
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) {
      // ETFs / IRAs stay uppercase. Everything else: sentence case.
      final upper = p.toUpperCase();
      if (upper == p && p.length <= 4) return p; // already an acronym
      return p[0].toUpperCase() + p.substring(1).toLowerCase();
    }).join(' ');
  }

  Widget _sectionLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        color: Colors.white54,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }

  Widget _breakdownRow(String label, double valueInUsd) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            currencyFormat.format(valueInUsd * conversionFactor),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('By type'),
        const SizedBox(height: 16),
        ...typeBreakdown.map((item) {
          final total = ((item['total_usd'] ?? item['total'] ?? 0.0) as num)
              .toDouble();
          final type = (item['account_type'] ?? 'Other').toString();
          return _breakdownRow(_prettyType(type), total);
        }),
      ],
    );
  }

  Widget _buildInstitutionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('By institution'),
        const SizedBox(height: 16),
        ...institutionBreakdown.map((item) {
          final total = ((item['total_usd'] ?? item['total'] ?? 0.0) as num)
              .toDouble();
          final name = (item['name'] ?? 'Bank').toString();
          return _breakdownRow(name, total);
        }),
      ],
    );
  }
}
