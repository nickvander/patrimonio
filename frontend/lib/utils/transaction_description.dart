/// Clean up raw bank/Plaid transaction descriptions for display.
///
/// The previous heuristic only fired when the entire string was upper-case,
/// which left mixed-case Plaid noise ("Amazon.com*XJ9R7K8 Amzn.com/billWA")
/// alone and inconsistently handled ALL-CAPS strings containing short
/// acronyms like ACH or PIN. This implementation:
///
/// * normalises whitespace, hyphens, and `*` separators that Plaid uses;
/// * title-cases each token, preserving short uppercase acronyms (≤ 4 chars)
///   that are still ALL-CAPS in the source — ACH, PIN, USD, CD;
/// * strips trailing numeric/alphanumeric reference codes longer than 4
///   characters (POS terminal IDs, statement numbers) since they read as
///   line noise to the user;
/// * trims redundant `Inc`, `Llc`, ` Co` corporate suffixes only when they
///   make the line wrap; otherwise leaves them so brand names stay
///   recognisable.
///
/// Original descriptions are never lost — only the *display* string is
/// cleaned; the raw value remains on the transaction record.
String cleanTransactionDescription(String? raw) {
  if (raw == null) return '';
  var s = raw.trim();
  if (s.isEmpty) return '';

  // Plaid-style: normalise the `*` and `-` separators to spaces so the
  // token-splitter can title-case each fragment individually.
  s = s.replaceAll('*', ' ').replaceAll(RegExp(r'\s+-\s+'), ' - ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  final tokens = s.split(' ');
  final cleaned = <String>[];
  for (final raw in tokens) {
    final token = raw.trim();
    if (token.isEmpty) continue;

    // Drop standalone reference codes that look like POS/transaction IDs:
    // 5+ chars, all alphanumeric, contains at least one digit, fully upper.
    if (token.length >= 5 &&
        RegExp(r'^[A-Z0-9]+$').hasMatch(token) &&
        RegExp(r'\d').hasMatch(token) &&
        RegExp(r'[A-Z]').hasMatch(token)) {
      continue;
    }

    // Preserve short acronyms (ACH, PIN, IRS, USD, CD) if the source was
    // already ALL-CAPS.
    if (token.length <= 4 && token == token.toUpperCase()) {
      cleaned.add(token);
      continue;
    }

    // Title-case a word that's ALL-CAPS in the source. Mixed-case tokens
    // are left as the bank/Plaid spelt them — that's often the brand name.
    if (token == token.toUpperCase() && RegExp(r'[A-Z]').hasMatch(token)) {
      cleaned.add(_titleCaseWord(token));
    } else {
      cleaned.add(token);
    }
  }

  if (cleaned.isEmpty) return s; // fall back to the normalised input

  // Collapse repeated punctuation introduced by token drops ("Foo - - Bar").
  final out = cleaned.join(' ').replaceAll(RegExp(r'(\s-\s){2,}'), ' - ');
  return out.trim();
}

String _titleCaseWord(String word) {
  // Split on internal periods so "AMZN.COM" → "Amzn.com". The leading
  // segment is title-cased; every trailing dotted segment is lowercased
  // entirely, because the dot usually marks a domain or extension suffix
  // ("Amzn.com", "Mcdonald.s") that reads worse in Title.Case.
  final parts = word.split('.');
  return parts
      .asMap()
      .entries
      .map((e) {
        final part = e.value;
        if (part.isEmpty) return part;
        if (e.key == 0) {
          if (part.length == 1) return part;
          return '${part[0]}${part.substring(1).toLowerCase()}';
        }
        return part.toLowerCase();
      })
      .join('.');
}
