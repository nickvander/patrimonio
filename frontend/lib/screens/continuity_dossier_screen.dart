import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/buttons.dart';
import '../utils/theme_colors.dart';
import '../widgets/connected_segments.dart';

/// Household continuity dossier — the Settings-surface screen for the
/// printable "open in emergency" packet.
///
/// Three controls, mirroring how the tax-export pack is surfaced:
///  1. a multiline instructions field, persisted server-side as the
///     `continuity_notes` app-settings key (generic GET/PUT store);
///  2. an en / es-MX document-language choice ([ConnectedSegments]);
///  3. a Generate button that opens the backend's printable HTML
///     (`GET /api/exports/continuity-dossier?lang=…`) the same way the
///     loan agreement printable is delivered: `launchUrl` with
///     `webOnlyWindowName: '_blank'` — a new tab on web (session cookie
///     rides along under the same-origin /api proxy), the system browser
///     on Android.
class ContinuityDossierScreen extends StatefulWidget {
  const ContinuityDossierScreen({
    super.key,
    this.loadNotesOverride,
    this.saveNotesOverride,
    this.openUrl,
  });

  /// Test seams (ImportCleanupScreen / TaxExportsCard pattern): replace
  /// the settings round-trip and the browser hand-off so widget tests run
  /// without HTTP or a browser window.
  final Future<dynamic> Function()? loadNotesOverride;
  final Future<void> Function(String text)? saveNotesOverride;
  final void Function(String url)? openUrl;

  @override
  State<ContinuityDossierScreen> createState() =>
      _ContinuityDossierScreenState();
}

class _ContinuityDossierScreenState extends State<ContinuityDossierScreen> {
  final ApiService _api = ApiService();
  final TextEditingController _notesCtrl = TextEditingController();
  bool _loadingNotes = true;
  bool _saving = false;
  String? _lang; // resolved from the app locale on first build

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    try {
      final value =
          await (widget.loadNotesOverride?.call() ??
              _api.getSetting('continuity_notes'));
      if (!mounted) return;
      setState(() {
        // Backend returns JSON null for a never-written key.
        if (value is String) _notesCtrl.text = value;
        _loadingNotes = false;
      });
    } catch (_) {
      // First-visit load failure isn't fatal — the field just starts
      // empty; a save will surface any real connectivity problem.
      if (!mounted) return;
      setState(() => _loadingNotes = false);
    }
  }

  Future<void> _saveNotes() async {
    final l = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final text = _notesCtrl.text.trim();
      if (widget.saveNotesOverride != null) {
        await widget.saveNotesOverride!(text);
      } else {
        await _api.putSetting('continuity_notes', text);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.dossierInstructionsSaved)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.dossierInstructionsSaveFailed)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _generate() {
    final url = _api.continuityDossierUrl(lang: _lang ?? 'en');
    final open =
        widget.openUrl ??
        (String u) => launchUrl(Uri.parse(u), webOnlyWindowName: '_blank');
    open(url);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Default the document language to the app's current locale once.
    _lang ??= l.localeName.startsWith('es') ? 'es' : 'en';

    return Scaffold(
      appBar: AppBar(title: Text(l.dossierTitle)),
      body: LayoutBuilder(
        builder: (context, outer) {
          final pad = outer.maxWidth < 720 ? 16.0 : 24.0;
          return ListView(
            padding: EdgeInsets.all(pad),
            children: [
              Text(
                l.dossierIntro,
                style: TextStyle(fontSize: 13, color: context.textMuted),
              ),
              const SizedBox(height: 16),
              // --- Owner instructions ------------------------------------
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.dossierInstructionsTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l.dossierInstructionsSubtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_loadingNotes)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        TextField(
                          controller: _notesCtrl,
                          maxLines: 6,
                          minLines: 4,
                          decoration: InputDecoration(
                            hintText: l.dossierInstructionsHint,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: _saving || _loadingNotes
                              ? null
                              : _saveNotes,
                          child: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l.dashSave),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // --- Language + generate ------------------------------------
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: LayoutBuilder(
                    builder: (context, inner) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.dossierLanguageLabel,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ConnectedSegments<String>(
                            segments: [
                              ConnectedSegment(
                                value: 'en',
                                label: l.dossierLanguageEnglish,
                              ),
                              ConnectedSegment(
                                value: 'es',
                                label: l.dossierLanguageSpanish,
                              ),
                            ],
                            selected: _lang ?? 'en',
                            onSelected: (v) => setState(() => _lang = v),
                          ),
                          const SizedBox(height: 16),
                          ConstrainedBox(
                            constraints: actionButtonConstraints(
                              inner.maxWidth,
                            ),
                            child: FilledButton.icon(
                              onPressed: _generate,
                              icon: const Icon(Icons.print_outlined, size: 18),
                              label: Text(
                                l.dossierGenerate,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l.dossierGenerateNote,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textMuted,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
