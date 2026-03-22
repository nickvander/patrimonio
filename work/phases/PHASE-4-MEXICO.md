# Phase 4: Mexican Institutions

**Goal:** Add support for Mexican financial accounts via CSV/OFX import and manual entry.

## Deliverables
- [ ] CSV parser for Nu Bank Mexico statements
- [ ] CSV parser for Banamex/Citibanamex statements
- [ ] CSV parser for Cetesdirecto statements
- [ ] **PDF statement parser** (many MX institutions only provide PDF statements)
  - Use `pdf-extract` (Rust) or `lopdf` for text extraction
  - Template-based parsing per institution (each has a different layout)
- [ ] File upload UI with format auto-detection (CSV, OFX, PDF)
- [ ] Manual account/balance entry
- [ ] Multi-currency normalization in all views (USD ↔ MXN)

## Success Criteria
- Upload a Nu Bank CSV **or PDF** and see transactions appear
- Upload a Cetesdirecto statement (PDF) and see investment holdings
- Dashboard shows Mexican accounts alongside US ones
- Net worth correctly sums USD + MXN converted positions
