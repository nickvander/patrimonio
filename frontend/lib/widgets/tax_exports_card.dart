import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';
import '../utils/url_opener.dart';

/// Tax-filing export pack — the "Exports" card on the Tax planning screen.
///
/// One tappable row per year-end document (FBAR worksheet, Form 8949 CSV,
/// Schedule B interest CSV, MX annual summary CSV) plus a year selector.
/// Each row hands a same-origin backend URL to the browser via the
/// `openUrlSameTab` seam — the CSV endpoints reply with
/// `Content-Disposition: attachment` (download without navigating) and the
/// FBAR worksheet opens as a printable HTML page, exactly like the existing
/// tax CSV/PDF export buttons and the loan printables.
class TaxExportsCard extends StatefulWidget {
  const TaxExportsCard({
    super.key,
    required this.baseUrl,
    required this.years,
    required this.initialYear,
    required this.filingStatus,
    this.openUrl,
  });

  /// `ApiService.baseUrl` — the `/api` origin the download URLs are built on.
  final String baseUrl;

  /// Selectable tax years (the screen's derived list, newest first).
  final List<int> years;

  /// The screen's currently selected tax year; the card follows it when it
  /// changes but can diverge via its own dropdown (so a year-end export for
  /// last year doesn't require flipping the whole screen).
  final int initialYear;

  /// Backend filing-status vocabulary token (Single / Married / Head of
  /// Household) — forwarded to the MX summary export, which runs the shared
  /// estimation.
  final String filingStatus;

  /// Test seam: receives the built URL instead of the browser hand-off.
  /// Defaults to [openUrlSameTab] (a no-op on the test VM).
  final void Function(String url)? openUrl;

  @override
  State<TaxExportsCard> createState() => _TaxExportsCardState();
}

class _TaxExportsCardState extends State<TaxExportsCard> {
  late int _year = widget.initialYear;

  @override
  void didUpdateWidget(covariant TaxExportsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the screen-level year selector whenever the user changes it —
    // the card's own dropdown is a local override, not a second source of
    // truth to drift from.
    if (oldWidget.initialYear != widget.initialYear) {
      _year = widget.initialYear;
    }
  }

  void _open(String url) => (widget.openUrl ?? openUrlSameTab)(url);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The FBAR worksheet is a bilingual printable — open it in the app's
    // current language.
    final lang = l.localeName.startsWith('es') ? 'es' : 'en';
    final status = Uri.encodeQueryComponent(widget.filingStatus);

    // Guard: the dropdown asserts if its value is missing from the items.
    final yearItems = widget.years.contains(_year)
        ? widget.years
        : (<int>[_year, ...widget.years]..sort((a, b) => b.compareTo(a)));

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isPhone = constraints.maxWidth < 420;
          final pad = constraints.maxWidth < 720 ? 16.0 : 24.0;

          final titleBlock = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.taxExportsTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l.taxExportsSubtitle,
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          );
          final yearSelector = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l.taxYearLabel,
                style: TextStyle(
                  fontSize: 11,
                  color: context.textSubtle,
                  fontWeight: FontWeight.w600,
                ),
              ),
              DropdownButton<int>(
                value: _year,
                items: yearItems
                    .map(
                      (y) => DropdownMenuItem<int>(
                        value: y,
                        child: Text(y.toString()),
                      ),
                    )
                    .toList(),
                onChanged: (y) {
                  if (y != null) setState(() => _year = y);
                },
                underline: const SizedBox(),
              ),
            ],
          );

          return Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Phones stack the year selector under the title; wide layouts
                // keep one header row (inner-constraint breakpoint, per skill).
                if (isPhone) ...[
                  titleBlock,
                  const SizedBox(height: 8),
                  yearSelector,
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: titleBlock),
                      const SizedBox(width: 16),
                      yearSelector,
                    ],
                  ),
                const SizedBox(height: 8),
                _exportTile(
                  icon: Icons.travel_explore,
                  title: l.taxExportsFbar,
                  subtitle: l.taxExportsFbarDesc,
                  onTap: () => _open(
                    '${widget.baseUrl}/tax/export/fbar?year=$_year&lang=$lang',
                  ),
                ),
                _exportTile(
                  icon: Icons.trending_up,
                  title: l.taxExports8949,
                  subtitle: l.taxExports8949Desc,
                  onTap: () =>
                      _open('${widget.baseUrl}/tax/export/8949?year=$_year'),
                ),
                _exportTile(
                  icon: Icons.percent,
                  title: l.taxExportsScheduleB,
                  subtitle: l.taxExportsScheduleBDesc,
                  onTap: () => _open(
                    '${widget.baseUrl}/tax/export/schedule-b?year=$_year',
                  ),
                ),
                _exportTile(
                  icon: Icons.flag_outlined,
                  title: l.taxExportsMx,
                  subtitle: l.taxExportsMxDesc,
                  onTap: () => _open(
                    '${widget.baseUrl}/tax/export/mx?year=$_year&status=$status',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _exportTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      // ≥48dp touch target comes from ListTile's two-line minimum height.
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: context.accentSoft(context.info),
        child: Icon(icon, size: 20, color: context.textPrimary),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: context.textMuted),
      ),
      trailing: Icon(Icons.download, color: context.textMuted),
      onTap: onTap,
    );
  }
}
