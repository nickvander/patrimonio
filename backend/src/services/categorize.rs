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
    ]) {
        return cat("FOOD_AND_DRINK");
    }

    // Transportation (rideshare, fuel, parking, tolls, transit).
    if has(&[
        "UBER", "DIDI", "CABIFY", "BEAT ", "GASOLIN", "PEMEX", "OXXO GAS",
        "BP ", "SHELL", "MOBIL", "ESTACIONAMIENTO", "PARKING", "PARKIMETRO",
        "CASETA", "PEAJE", "IAVE", "TELEVIA", "PASE ", "METRO ", "METROBUS",
        "MOVILIDAD INTEGRAL",
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
    ]) {
        return cat("GENERAL_MERCHANDISE");
    }

    // Cloud / software subscriptions → services.
    if has(&[
        "GOOGLE", "MICROSOFT", "ICLOUD", "DROPBOX", "ADOBE", "GITHUB",
        "OPENAI", "ANTHROPIC", "NOTION",
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
    fn bare_compra_is_merchandise() {
        assert_eq!(categorize("COMPRA CON TARJETA DE DEBITO REF 7766", neg("532.68")).as_deref(), Some("GENERAL_MERCHANDISE"));
    }
}
