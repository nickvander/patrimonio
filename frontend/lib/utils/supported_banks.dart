/// Single source of truth for the Mexican institutions Patrimonio can import.
///
/// Why this exists: the onboarding hero and the import screen each used to
/// carry their own hand-written bank list, and they drifted — the hero
/// advertised Bancomer/Santander/Banorte (which have NO backend parser)
/// while omitting the ones that actually work. The set below mirrors the
/// live parsers in `backend/src/services/parser/mod.rs` (nu_mexico, banamex,
/// cetes + their PDF variants). Both user-facing copies render from this
/// constant so they can never disagree again.
const List<String> kSupportedMxBanks = ['Nu México', 'Banamex', 'Cetesdirecto'];

/// "Nu México, Banamex, or Cetesdirecto" — an Oxford-style human list of the
/// supported institutions for use in body copy.
String supportedMxBanksSentence() {
  final banks = kSupportedMxBanks;
  if (banks.length == 1) return banks.first;
  final head = banks.sublist(0, banks.length - 1).join(', ');
  return '$head, or ${banks.last}';
}
