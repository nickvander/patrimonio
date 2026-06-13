//! Rule-based auto-categorization for imported transactions.
//!
//! Statement imports (Banamex, BBVA, Santander, Nu, …) land with a NULL
//! `category`, so everything reads as "Uncategorized" and the dashboard's
//! spending/trends views have nothing to group on. Plaid-synced rows, by
//! contrast, arrive pre-tagged with Plaid's Personal Finance Category
//! (PFC) primary enum (`FOOD_AND_DRINK`, `TRANSPORTATION`, …).
//!
//! To keep imported rows consistent with synced ones — and to make them
//! render through the SAME `prettyCategory` label map in
//! `frontend/lib/utils/category.dart` — this module maps a Spanish
//! description (+ the amount sign, for direction-dependent buckets like
//! transfers) onto a **PFC primary code**. We deliberately return the
//! primary enum, not the detailed one, because the import insert only
//! writes the `category` column (there is no `category_detailed` for
//! imports), and the frontend prettifies the primary code fine.
//!
//! Philosophy: high-precision, not high-recall. A wrong category is worse
//! than none (it silently corrupts spending totals and the user has to
//! hunt it down), so anything we don't recognise returns `None` and stays
//! honestly uncategorized. The rules below are ordered most-specific
//! first; the first match wins.

use rust_decimal::Decimal;

/// Map a transaction description (and amount sign) to a Plaid PFC primary
/// category code, or `None` when no rule matches confidently.
///
/// `amount` sign convention matches the app's: income/inflow positive,
/// expense/outflow negative. Used only to split mechanism-neutral words
/// like SPEI / TRANSFERENCIA into `TRANSFER_IN` vs `TRANSFER_OUT`.
pub fn categorize(description: &str, amount: Decimal) -> Option<String> {
    let u = description.to_uppercase();
    let has = |needles: &[&str]| needles.iter().any(|n| u.contains(n));
    let cat = |s: &str| Some(s.to_string());

    // 1. Bank's own fees / charges. Checked first because a "COMISION SPEI"
    //    row also contains "SPEI" — fees must win over the transfer rule.
    if has(&[
        "COMISION", "COMISIÓN", "ANUALIDAD", "MANEJO DE CUENTA",
        "SOBREGIRO", "COM USO TPV", "COM CHQ", "MEMBRESIA", "MEMBRESÍA",
    ]) {
        return cat("BANK_FEES");
    }
    // IVA on its own line is the tax on a commission → still a bank fee.
    if has(&["I.V.A", "IVA "]) && has(&["COMISION", "COMISIÓN", "COM ", "TPV"]) {
        return cat("BANK_FEES");
    }

    // 2. Income: payroll + interest + dividends. These read as inflows but
    //    we key on the words so a "PAGO DE NOMINA" can't be mistaken for a
    //    transfer.
    if has(&["NOMINA", "NÓMINA", "SALARIO", "AGUINALDO", "PAGO DE PENSION"]) {
        return cat("INCOME");
    }
    if has(&["INTERESES", "RENDIMIENTO", "DIVIDENDO"]) {
        return cat("INCOME");
    }

    // 3. Taxes / government.
    if has(&[
        "IMPUESTO", "PREDIAL", "TENENCIA", "TESORERIA", "TESORERÍA",
        " SAT ", "MULTA", "DERECHOS VEHIC", "GOBIERNO", "RECAUDADORA",
    ]) {
        return cat("GOVERNMENT_AND_NON_PROFIT");
    }

    // 4. Loan / credit-card payments.
    if (has(&["TARJETA"]) && has(&["CREDITO", "CRÉDITO", "TDC"]))
        || has(&["PAGO TDC", "PAGO TARJETA", "ABONO A CREDITO", "PRESTAMO", "PRÉSTAMO", "CREDITO HIPOTEC"])
    {
        return cat("LOAN_PAYMENTS");
    }

    // 5. Specific merchant / spend categories BEFORE the generic
    //    transfer/ATM rules, so e.g. a SPEI labelled "PAGO RENTA" is filed
    //    as rent rather than a bare outgoing transfer.

    // Utilities & telecom.
    if has(&[
        "CFE", "TELMEX", "TELCEL", "MOVISTAR", "AT&T", "ATT ", "IZZI",
        "TOTALPLAY", "MEGACABLE", "DISH", "SKY ", "NATURGY", "GAS NATURAL",
        "AGUA ", "SACMEX", "SIAPA", "INTERNET", "RENTA",
        // More MX telecom / utilities / water boards.
        "BAIT", "UNEFON", "VIRGIN MOBILE", "AXTEL", "VETV", "STARLINK",
        "CESPT", "JAPAC", "SAPAL", "INTERAPAS", "CEA ", "GAS LICUADO",
        "GASRED", "GLOBALGAS", "ZGAS", "LUZ Y FUERZA", "PREDIO",
    ]) {
        return cat("RENT_AND_UTILITIES");
    }

    // Groceries & convenience & food.
    if has(&[
        "OXXO", "7-ELEVEN", "7 ELEVEN", "SEVEN", "CIRCLE K", "SORIANA",
        "WALMART", "BODEGA AURRERA", "AURRERA", "CHEDRAUI", "SUPERAMA",
        "COSTCO", "SAMS CLUB", "SAM'S", "LA COMER", "CITY MARKET", "HEB",
        "SUPERMERCADO", "ABARROTES", "RESTAURANTE", "UBER EATS", "RAPPI",
        "DIDI FOOD", "STARBUCKS", "MCDONALD", "BURGER", "DOMINO", "KFC",
        "VIPS", "SANBORNS", "TACO", "CAFE", "CAFÉ",
        // More MX grocers / convenience / food.
        "FRESKO", "SUMESA", "CALIMAX", "MERZA", "SMART AND FINAL", "S MART",
        "TIENDAS TRES B", "BODEGA COMERCIAL", "MEGA COMERCIAL", "PANADERIA",
        "PANADERÍA", "TORTILLERIA", "TORTILLERÍA", "CARNICERIA", "CARNICERÍA",
        "LITTLE CAESARS", "CARLS JR", "WINGS", "TOKS", "ITALIANNI", "CHILIS",
        "CHILI'S", "SUSHI", "PIZZA", "POLLO", "STARBUCK", "CIELITO QUERIDO",
        "LA CASA DE TOÑO", "FISHER", "BISTRO", "CANTINA", "CERVECERIA",
        "CERVECERÍA", "HEINEKEN", "MODELORAMA",
    ]) {
        return cat("FOOD_AND_DRINK");
    }

    // Transportation (rideshare, fuel, parking, tolls, transit).
    if has(&[
        "UBER", "DIDI", "CABIFY", "BEAT ", "GASOLIN", "PEMEX", "OXXO GAS",
        "BP ", "SHELL", "MOBIL", "ESTACIONAMIENTO", "PARKING", "PARKIMETRO",
        "CASETA", "PEAJE", "IAVE", "TELEVIA", "PASE ", "METRO ", "METROBUS",
        "MOVILIDAD INTEGRAL",
        // More MX fuel / transit / mobility.
        "REPSOL", "CHEVRON", "G500", "HIDROSINA", "REDCO", "ORSAN",
        "GASOLINERA", "CAPUFE", "TAG ", "ECOBICI", "MIBICI", "JETTY",
        "CUOTA", "AUTOPISTA", "PRIMERA PLUS", "SITIO ", "TAXI",
    ]) {
        return cat("TRANSPORTATION");
    }

    // Travel.
    if has(&[
        "AEROMEXICO", "AEROMÉXICO", "VOLARIS", "VIVA AEROBUS", "VIVAAEROBUS",
        "INTERJET", "HOTEL", "AIRBNB", "BOOKING", "EXPEDIA", "DESPEGAR",
        "VUELO", "AVIANCA", "AMERICAN AIR", "DELTA AIR", "UNITED AIR",
    ]) {
        return cat("TRAVEL");
    }

    // Medical / pharmacy / health.
    if has(&[
        "FARMACIA", "BENAVIDES", "DEL AHORRO", "SIMILARES", "HOSPITAL",
        "CLINICA", "CLÍNICA", "DENTAL", "DENTISTA", "LABORATORIO", "MEDICA",
        "MÉDICA", "CONSULTORIO", "OPTICA", "ÓPTICA",
    ]) {
        return cat("MEDICAL");
    }

    // Personal care / fitness.
    if has(&[
        "GIMNASIO", "SMART FIT", "SMARTFIT", "SPORTS WORLD", "GYM ",
        "ESTETICA", "ESTÉTICA", "SALON", "SALÓN", "BARBER", "SPA ", "PELUQ",
    ]) {
        return cat("PERSONAL_CARE");
    }

    // Streaming / entertainment.
    if has(&[
        "SPOTIFY", "NETFLIX", "DISNEY", "HBO", "MAX ", "PARAMOUNT", "STAR+",
        "YOUTUBE", "PRIME VIDEO", "CINEPOLIS", "CINÉPOLIS", "CINEMEX",
        "STEAM", "PLAYSTATION", "XBOX", "NINTENDO", "TICKETMASTER",
        // More streaming / gaming / events.
        "CRUNCHYROLL", "VIX", "BLIM", "MUBI", "DEEZER", "APPLE MUSIC",
        "AUDIBLE", "TWITCH", "EPIC GAMES", "RIOT GAMES", "BOLETIA",
        "SUPERBOLETOS", "FANDANGO", "DEPORTES",
    ]) {
        return cat("ENTERTAINMENT");
    }

    // Home improvement / hardware (checked before general merchandise so
    // Home Depot / IKEA don't get filed as plain shopping).
    if has(&[
        "HOME DEPOT", "IKEA", "TRUPER", "FERRETERIA", "FERRETERÍA",
        "TLAPALERIA", "TLAPALERÍA", "CONSTRURAMA",
    ]) {
        return cat("HOME_IMPROVEMENT");
    }

    // Online marketplaces / department stores / general merchandise.
    if has(&[
        "AMAZON", "MERCADO LIBRE", "MERCADOLIBRE", "MERCADO PAGO",
        "MERCADOPAGO", "LIVERPOOL", "PALACIO DE HIERRO", "COPPEL", "ELEKTRA",
        "SHEIN", "ALIEXPRESS", "BEST BUY", "APPLE.COM", "APPLE STORE",
        "OFFICE DEPOT",
        // More marketplaces / department / apparel / electronics.
        "TEMU", "SEARS", "SUBURBIA", "C&A", "ZARA", "BERSHKA", "PULL AND BEAR",
        "PULL&BEAR", "NIKE", "ADIDAS", "INNOVASPORT", "MARTI", "STEREN",
        "RADIOSHACK", "PCEL", "CYBERPUERTA", "MIXUP", "GANDHI", "SANBORN",
    ]) {
        return cat("GENERAL_MERCHANDISE");
    }

    // Cloud / software subscriptions → services.
    if has(&[
        "GOOGLE", "MICROSOFT", "ICLOUD", "DROPBOX", "ADOBE", "GITHUB",
        "OPENAI", "ANTHROPIC", "NOTION",
        // More SaaS / app subscriptions.
        "CANVA", "FIGMA", "ZOOM", "SLACK", "LINKEDIN", "CHATGPT", "CLAUDE",
        "GODADDY", "NAMECHEAP", "CLOUDFLARE", "AWS", "DIGITALOCEAN",
    ]) {
        return cat("GENERAL_SERVICES");
    }

    // 6. ATM cash withdrawals → an outgoing transfer (matches Plaid's
    //    TRANSFER_OUT_WITHDRAWAL bucket; we store the primary).
    if has(&["CAJERO", "DISPOSICION", "DISPOSICIÓN", "RETIRO EFECTIVO", "RETIRO EN"]) {
        return cat("TRANSFER_OUT");
    }

    // 7. Generic transfers / SPEI / interbank — direction from the sign.
    if has(&[
        "SPEI", "TRASPASO", "TRANSFERENCIA", "INTERBANCARIO", "DEPOSITO DE TERCERO",
        "DEPÓSITO DE TERCERO", "PAGO RECIBIDO", "PAGO INTERBANCARIO", "TEF ",
        "ENVIO DE DINERO", "ENVÍO DE DINERO",
    ]) {
        return Some(if amount >= Decimal::ZERO {
            "TRANSFER_IN".to_string()
        } else {
            "TRANSFER_OUT".to_string()
        });
    }

    // 8. A bare "COMPRA" (card purchase) with no recognised merchant is
    //    still clearly retail spend.
    if has(&["COMPRA", "PAGO CON TARJETA", "TARJETA DE DEBITO", "TARJETA DE DÉBITO", "TDD"]) {
        return cat("GENERAL_MERCHANDISE");
    }

    None
}

/// The income detail string (T6 / T14) for interest the user earned —
/// the SAME `category_detailed` value the Plaid investment sync stamps on
/// brokerage/bank interest, which `frontend/lib/utils/category.dart` and the
/// tax summary's interest decomposition (`TaxEstimation::interest_income`,
/// keyed on `category_detailed = 'INCOME_INTEREST_EARNED'`) already
/// understand. Exposed so the cetesdirecto parsers can tag a maturity
/// premium / interest row with the identical taxonomy.
///
/// NOTE (T14 limitation): the statement-import insert path
/// (`api/imports.rs`) only persists the `category` column — there is no
/// `category_detailed` for imported rows (see the `categorize` module doc
/// and `ParsedTransaction`, which has no `category_detailed` field). So a
/// CETES interest row reaches the income predicate (`UPPER(category) =
/// 'INCOME'`) and the MX tax base, but cannot reach the dividends/interest
/// *decomposition* (`interest_income`) without a migration + insert change,
/// which is out of scope here. This constant is provided for the day that
/// detail column is wired through imports, and is asserted in tests so it
/// stays in lockstep with the tax-side string.
pub const INCOME_INTEREST_DETAIL: &str = "INCOME_INTEREST_EARNED";

/// Classify ONE cetesdirecto cash-movement description (T14).
///
/// cetesdirecto "Movimientos del período" is the contract's CASH sub-ledger.
/// Its rows are mostly PRINCIPAL movements, which must NOT be taxed:
///   - `INGEFVO`  — ingreso de efectivo (you funding the contract);
///   - `COMPRA` / `COMPSI` — buying an instrument (cash out, `Cargo`);
///   - `VENTA` / `VTASI`   — selling/redeeming an instrument. The `Abono`
///     here is principal **plus** yield COMBINED; the ledger never breaks the
///     two apart, and the parser does no lot matching, so tagging the whole
///     redemption as income would massively overcount. Left uncategorized.
///   - `RETENCION` / ISR rows — tax WITHHELD (an outflow), not income.
///
/// The ONLY rows whose `Abono` is *purely* yield are the explicit
/// interest / maturity-premium credits cetesdirecto books separately
/// (`INTERES`, `RENDIMIENTO`, `PREMIO`, and the `LIQUIDA…`/`VENCIMIENTO`
/// yield-liquidation rows). For those — and only when the amount is a
/// positive inflow (the canonical sign for income in this app: outflow is
/// negative) — we return `"INCOME"`. This is the documented way principal is
/// separated from yield: by movement TYPE (explicit yield credit) rather than
/// by trying to net a redemption against an earlier purchase the cash ledger
/// doesn't link.
///
/// Returns `Some("INCOME")` for a yield/interest credit, else `None` (the
/// row stays honestly uncategorized — principal movements and ISR retentions
/// included). `None` for any non-positive amount, since income is an inflow.
pub fn classify_cetes_movement(description: &str, amount: Decimal) -> Option<String> {
    // Income is an INFLOW → positive. A negative amount here is a Cargo
    // (buy / withholding / fee); never income regardless of wording.
    if amount <= Decimal::ZERO {
        return None;
    }
    let u = description.to_uppercase();
    let has = |needles: &[&str]| needles.iter().any(|n| u.contains(n));
    // Explicit yield / interest / maturity-premium credits. "PREMIO" is the
    // CETES maturity premium (discount instrument redeemed at par). The
    // accented and unaccented spellings both appear depending on the export.
    if has(&[
        "INTERES", "INTERÉS", "RENDIMIENTO", "PREMIO",
        "VENCIMIENTO", "LIQUIDA",
    ]) {
        return Some("INCOME".to_string());
    }
    None
}

/// True when a cetesdirecto movement description denotes an ISR withholding
/// (the SAT tax retained on yield, `RETSI` / "RETENCION ISR"). cetesdirecto
/// books retention as its own `Cargo` (outflow) movement. T14 wants this
/// stored so the MX card can later show "estimated minus withheld", but
/// `ParsedTransaction` has no withholding field and adding one needs a
/// migration + insert change (out of scope). This predicate is provided so a
/// future change can route these rows; today the row stays an ordinary
/// outflow transaction. See the TODO in the cetes parsers.
pub fn is_cetes_isr_withholding(description: &str) -> bool {
    let u = description.to_uppercase();
    (u.contains("RETEN") || u.contains("RETSI") || u.contains("RET ISR"))
        && (u.contains("ISR") || u.contains("RETSI"))
}

/// A coarse merchant key for "learn from my edits": normalize a description
/// to its leading significant words, dropping generic verbs/stopwords, so a
/// category the user set on one "STARBUCKS …" row can be reused for future
/// "STARBUCKS …" imports. Returns "" when nothing significant remains (the
/// caller skips learned-matching then). Deliberately conservative (keeps a
/// few words) so it doesn't over-apply across unrelated merchants.
pub fn merchant_key(description: &str) -> String {
    const NOISE: &[&str] = &[
        "COMPRA", "PAGO", "SPEI", "ENVIASTE", "RECIBISTE", "RECIBIDO",
        "ABONO", "CARGO", "TRASPASO", "DEPOSITO", "DEPÓSITO", "RETIRO",
        "TRANSFERENCIA", "CON", "TARJETA", "DEBITO", "DÉBITO", "CREDITO",
        "CRÉDITO", "DE", "DEL", "LA", "EL", "EN", "POR", "PARA", "REF",
        "TDD", "TDC", "MN", "MXN", "SERVICIO", "Y",
    ];
    let upper = description.to_uppercase();
    let cleaned: String = upper
        .chars()
        .map(|c| if c.is_alphabetic() || c == ' ' { c } else { ' ' })
        .collect();
    let words: Vec<&str> = cleaned
        .split_whitespace()
        .filter(|w| w.chars().count() >= 2 && !NOISE.contains(w))
        .take(3)
        .collect();
    words.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    fn neg(s: &str) -> Decimal {
        -Decimal::from_str(s).unwrap()
    }
    fn pos(s: &str) -> Decimal {
        Decimal::from_str(s).unwrap()
    }

    #[test]
    fn fees_beat_transfers() {
        // "COMISION SPEI" contains SPEI but is a fee.
        assert_eq!(categorize("COMISION SPEI ENVIADO", neg("15.00")).as_deref(), Some("BANK_FEES"));
        assert_eq!(categorize("COMISION MANEJO DE CUENTA", neg("37.32")).as_deref(), Some("BANK_FEES"));
        assert_eq!(categorize("I.V.A POR COMISION", neg("5.92")).as_deref(), Some("BANK_FEES"));
    }

    #[test]
    fn income_payroll_and_interest() {
        assert_eq!(categorize("ABONO NOMINA QUINCENA 1", pos("12500.00")).as_deref(), Some("INCOME"));
        assert_eq!(categorize("INTERESES GANADOS", pos("18.42")).as_deref(), Some("INCOME"));
        assert_eq!(categorize("ABONO INTERESES", pos("12.95")).as_deref(), Some("INCOME"));
    }

    #[test]
    fn cetes_yield_is_income_principal_is_not() {
        // T14: explicit yield/interest/premium credits → income (positive).
        assert_eq!(classify_cetes_movement("PREMIO CETES 240725", pos("258.74")).as_deref(), Some("INCOME"));
        assert_eq!(classify_cetes_movement("INTERESES CETES", pos("18.42")).as_deref(), Some("INCOME"));
        assert_eq!(classify_cetes_movement("RENDIMIENTO BONDDIA", pos("4.10")).as_deref(), Some("INCOME"));
        assert_eq!(classify_cetes_movement("LIQUIDA VENCIMIENTO", pos("100.00")).as_deref(), Some("INCOME"));
        // Principal movements are NOT income, even though they share the ledger.
        assert_eq!(classify_cetes_movement("COMPRA CETES 241003", neg("23995.12")), None);
        assert_eq!(classify_cetes_movement("VTASI BONDDIA PF2", pos("23995.82")), None);
        assert_eq!(classify_cetes_movement("INGEFVO", pos("24000.00")), None);
        // A yield word on a NEGATIVE amount (an outflow) is never income.
        assert_eq!(classify_cetes_movement("RETENCION ISR INTERES", neg("2.50")), None);
    }

    #[test]
    fn cetes_isr_withholding_detection() {
        assert!(is_cetes_isr_withholding("RETENCION ISR"));
        assert!(is_cetes_isr_withholding("RETSI CETES"));
        assert!(!is_cetes_isr_withholding("INTERESES CETES"));
        assert!(!is_cetes_isr_withholding("COMPRA CETES"));
    }

    #[test]
    fn income_interest_detail_matches_tax_taxonomy() {
        // Stays in lockstep with the tax summary's interest decomposition.
        assert_eq!(INCOME_INTEREST_DETAIL, "INCOME_INTEREST_EARNED");
    }

    #[test]
    fn transfers_split_by_sign() {
        assert_eq!(categorize("SPEI RECIBIDO BANORTE", pos("5000.00")).as_deref(), Some("TRANSFER_IN"));
        assert_eq!(categorize("SPEI ENVIADO BBVA", neg("3200.00")).as_deref(), Some("TRANSFER_OUT"));
        assert_eq!(categorize("TRASPASO ENTRE CUENTAS", neg("1500.00")).as_deref(), Some("TRANSFER_OUT"));
    }

    #[test]
    fn atm_is_outgoing_transfer() {
        assert_eq!(categorize("DISPOSICION EFECTIVO CAJERO SUC 4857", neg("2000.00")).as_deref(), Some("TRANSFER_OUT"));
    }

    #[test]
    fn merchant_buckets() {
        assert_eq!(categorize("COMPRA OXXO COL DEL VALLE", neg("248.50")).as_deref(), Some("FOOD_AND_DRINK"));
        assert_eq!(categorize("COMPRA AMAZON MX MEXICO DF", neg("1149.00")).as_deref(), Some("GENERAL_MERCHANDISE"));
        assert_eq!(categorize("PAGO DE SERVICIO CFE", neg("1485.06")).as_deref(), Some("RENT_AND_UTILITIES"));
        assert_eq!(categorize("UBER TRIP", neg("89.00")).as_deref(), Some("TRANSPORTATION"));
        assert_eq!(categorize("SPOTIFY AB", neg("129.00")).as_deref(), Some("ENTERTAINMENT"));
        assert_eq!(categorize("FARMACIA GUADALAJARA", neg("210.00")).as_deref(), Some("MEDICAL"));
    }

    #[test]
    fn rent_beats_transfer_mechanism() {
        // A SPEI labelled with RENTA should file as utilities/rent, not a
        // bare transfer.
        assert_eq!(categorize("SPEI ENVIADO PAGO RENTA DEPTO", neg("9000.00")).as_deref(), Some("RENT_AND_UTILITIES"));
    }

    #[test]
    fn credit_card_payment() {
        assert_eq!(categorize("PAGO TARJETA DE CREDITO SANTANDER", neg("4500.00")).as_deref(), Some("LOAN_PAYMENTS"));
    }

    #[test]
    fn unknown_stays_none() {
        assert_eq!(categorize("XYZZY REFERENCIA 9981", neg("42.00")), None);
        assert_eq!(categorize("", pos("1.00")), None);
    }

    #[test]
    fn merchant_key_strips_noise_and_matches_recurring() {
        // Generic verbs/refs/punctuation dropped; the same merchant produces
        // the same key across imports so a learned category can be reused.
        assert_eq!(merchant_key("COMPRA STARBUCKS REFORMA REF 9981"), "STARBUCKS REFORMA");
        assert_eq!(merchant_key("Pago de servicio SPOTIFY"), "SPOTIFY");
        // Single-token app-style merchant → broad, stable key.
        assert_eq!(merchant_key("Enviaste a NETFLIX"), "NETFLIX");
        // Pure noise → empty (caller won't learn-match).
        assert_eq!(merchant_key("PAGO TARJETA DE DEBITO"), "");
    }

    #[test]
    fn grown_rules_cover_more_merchants() {
        assert_eq!(categorize("COMPRA TEMU", neg("300.00")).as_deref(), Some("GENERAL_MERCHANDISE"));
        assert_eq!(categorize("PAGO BAIT RECARGA", neg("100.00")).as_deref(), Some("RENT_AND_UTILITIES"));
        assert_eq!(categorize("CRUNCHYROLL", neg("129.00")).as_deref(), Some("ENTERTAINMENT"));
        assert_eq!(categorize("REPSOL GASOLINERA", neg("800.00")).as_deref(), Some("TRANSPORTATION"));
        assert_eq!(categorize("CANVA PRO", neg("199.00")).as_deref(), Some("GENERAL_SERVICES"));
    }

    #[test]
    fn bare_compra_is_merchandise() {
        assert_eq!(categorize("COMPRA CON TARJETA DE DEBITO REF 7766", neg("532.68")).as_deref(), Some("GENERAL_MERCHANDISE"));
    }
}
