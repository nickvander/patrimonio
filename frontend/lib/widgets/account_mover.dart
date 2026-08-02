import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/menus.dart';
import '../utils/mask_aware_name.dart';

/// Small inline picker: shows a dropdown of accounts and reassigns the
/// transaction on selection. Filters out the current account.
class AccountMover extends StatefulWidget {
  final List<dynamic> accounts;
  final String? currentAccountId;
  final Future<void> Function(String newAccountId) onMove;

  const AccountMover({
    super.key,
    required this.accounts,
    required this.currentAccountId,
    required this.onMove,
  });

  @override
  State<AccountMover> createState() => _AccountMoverState();
}

class _AccountMoverState extends State<AccountMover> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final candidates = widget.accounts
        .where((a) => a['id']?.toString() != widget.currentAccountId)
        .toList();
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _selectedId,
            isExpanded: true,
            dropdownColor: houseDropdownColor(context),
            borderRadius: kMenuRadius,
            decoration: InputDecoration(
              labelText: l.txReassignTo,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: candidates.map<DropdownMenuItem<String>>((a) {
              final id = a['id'].toString();
              final name = (a['name'] ?? 'Account').toString();
              final inst = (a['institution_name'] ?? '').toString();
              return DropdownMenuItem<String>(
                value: id,
                child: maskAwareNameText(
                  inst.isEmpty ? name : '$inst · $name',
                  const TextStyle(),
                ),
              );
            }).toList(),
            onChanged: (v) => setState(() => _selectedId = v),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _selectedId == null
              ? null
              : () => widget.onMove(_selectedId!),
          child: Text(l.txMove),
        ),
      ],
    );
  }
}
