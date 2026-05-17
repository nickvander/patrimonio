import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:flutter/services.dart';

/// One row in the command-palette results.
class PaletteItem {
  /// Short label that the user matches against and that's shown as the
  /// primary line of the row.
  final String label;

  /// Optional second line — usually a type / source ("Account · SoFi"),
  /// surfaced in dimmer text under the label.
  final String? subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onSelected;

  PaletteItem({
    required this.label,
    this.subtitle,
    required this.icon,
    required this.accent,
    required this.onSelected,
  });

  /// Tokenised lower-cased text we run substring matches against. We keep
  /// the search cheap (just a substring check on a concatenation) since
  /// a Patrimonio user has at most ~50 accounts + a few hundred holdings
  /// + a few hundred recent transactions to search through.
  late final String _haystack =
      '${label.toLowerCase()} ${(subtitle ?? '').toLowerCase()}';

  bool matches(String needle) => _haystack.contains(needle.toLowerCase());
}

/// Cmd-K / Ctrl-K palette. Shows a dialog with a top search input and a
/// scrolling list of results. ↑/↓ moves the highlight, Enter activates,
/// Esc dismisses.
class CommandPaletteDialog extends StatefulWidget {
  final List<PaletteItem> items;
  const CommandPaletteDialog({super.key, required this.items});

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  int _highlight = 0;
  String _query = '';

  List<PaletteItem> get _visible {
    if (_query.trim().isEmpty) return widget.items.take(30).toList();
    return widget.items.where((i) => i.matches(_query)).take(50).toList();
  }

  void _activateHighlight() {
    final list = _visible;
    if (list.isEmpty) return;
    final i = _highlight.clamp(0, list.length - 1);
    final selected = list[i];
    Navigator.of(context).pop();
    selected.onSelected();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final list = _visible;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight =
          list.isEmpty ? 0 : (_highlight + 1) % list.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = list.isEmpty
          ? 0
          : (_highlight - 1 + list.length) % list.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _activateHighlight();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;

    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search accounts, holdings, transactions, or jump to a tab…',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                  ),
                  onChanged: (v) => setState(() {
                    _query = v;
                    _highlight = 0;
                  }),
                  onSubmitted: (_) => _activateHighlight(),
                ),
              ),
              Divider(height: 1, color: context.hairline),
              Flexible(
                child: visible.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No matches.',
                          style: TextStyle(color: context.textSubtle),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: visible.length,
                        itemBuilder: (ctx, i) {
                          final it = visible[i];
                          final isHi = i == _highlight;
                          return Container(
                            color: isHi
                                ? context.tint(0.06)
                                : null,
                            child: ListTile(
                              dense: true,
                              leading: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: it.accent.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(it.icon,
                                    color: it.accent, size: 16),
                              ),
                              title: Text(
                                it.label,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: it.subtitle == null
                                  ? null
                                  : Text(
                                      it.subtitle!,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: context.textSubtle),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              onTap: () {
                                setState(() => _highlight = i);
                                _activateHighlight();
                              },
                            ),
                          );
                        },
                      ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: context.tint(0.03),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(20),
                  ),
                ),
                child: const Row(
                  children: [
                    _Hint(label: '↑↓', text: 'navigate'),
                    SizedBox(width: 12),
                    _Hint(label: '↵', text: 'select'),
                    SizedBox(width: 12),
                    _Hint(label: 'Esc', text: 'close'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String label;
  final String text;
  const _Hint({required this.label, required this.text});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: context.hairline,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: context.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(fontSize: 11, color: context.textSubtle),
        ),
      ],
    );
  }
}
