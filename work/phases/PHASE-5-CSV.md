# Phase 5: Manual CSV/PDF Imports

**Goal:** Enable users to import financial data from Mexican institutions that don't support Plaid, using CSV or PDF statements.

## Context
Since most Mexican banks lack public APIs or reliable Plaid support, this phase focuses on robust manual imports. It includes auto-detection of common bank formats (Nu Mexico, Banamex, Cetesdirecto) and a preview UI for verification before saving.

## Deliverables

### 5.1 Backend Parsing Service
- [x] CSV parser for Nu Mexico
- [x] CSV parser for Banamex
- [x] CSV parser for Cetesdirecto
- [x] PDF parser for Nu Mexico (Regex-based text extraction)
- [x] PDF parser for Cetesdirecto (Regex-based text extraction)
- [x] Auto-detection logic in `detect_and_parse`
- [x] Unit tests for each parser with sample data

### 5.2 Frontend Import UI
- [x] File picker for .csv and .pdf
- [x] Multi-part upload to `/api/imports/upload`
- [x] Transaction preview table with edit/delete (preview only for now)
- [x] Account assignment dropdown
- [x] Confirmation call to `/api/imports/confirm`

### 5.3 Data Integrity & Deduplication
- [x] Deterministic `external_id` generation for manual imports
- [x] `ON CONFLICT DO NOTHING` logic for transaction insertion
- [x] Balance synchronization after import (Optional)

## Success Criteria
- [x] User can upload a Nu Bank PDF and see accurate transactions on the dashboard.
- [x] User can upload a Cetesdirecto PDF and see holdings/transactions.
- [x] No duplicate transactions are created if the same file is uploaded twice.
- [x] Multi-currency (MXN) is correctly handled and converted to USD for net worth.
