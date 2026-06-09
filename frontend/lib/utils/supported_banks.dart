/// Single source of truth for the Mexican institutions Patrimonio can import.
///
/// Why this exists: the onboarding hero and the import screen each used to
/// carry their own hand-written bank list, and they drifted — the hero
/// advertised banks with NO backend parser while omitting the ones that
/// actually work. The set below is the curated list we advertise: banks whose
/// `pdftotext -layout` parsers were built/validated against REAL statements
/// (Banorte & Scotiabank from public statements; Banamex/Nu/Cetes mature).
/// Both user-facing copies render from this constant so they can never
/// disagree again.
///
/// Note: `backend/src/services/parser/mod.rs` also dispatches BBVA, Santander
/// and HSBC parsers, but those were validated against reconstructed/decoded
/// fixtures rather than real personal PDFs (HSBC's date format is still
/// unconfirmed), so we don't advertise them yet — they still run, guarded by
/// the import preview, if such a file is uploaded.
const List<String> kSupportedMxBanks = [
  'Nu México',
  'Banamex',
  'Banorte',
  'Scotiabank',
  'Cetesdirecto',
  // US: HealthEquity HSA — validated against six real monthly statements
  // (cash ledger + invested fund value → total account worth).
  'HealthEquity',
  // US: Fidelity Stock Plan Services ("NetBenefits") — equity-comp reports
  // (monthly + year-end), validated against five real statements.
  'Fidelity NetBenefits',
];

/// An Oxford-style human list of the supported institutions for body copy.
String supportedMxBanksSentence() {
  final banks = kSupportedMxBanks;
  if (banks.length == 1) return banks.first;
  final head = banks.sublist(0, banks.length - 1).join(', ');
  return '$head, or ${banks.last}';
}
