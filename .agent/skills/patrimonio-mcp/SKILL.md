---
name: patrimonio-mcp
description: >-
  Use this skill whenever the user asks about a live or local Patrimonio
  personal finance deployment, net worth changes, account balances, Plaid sync
  status, statement imports, transactions, investment holdings/lots, or
  loans/repayments. Guides safe, read-first analysis via the `patrimonio` MCP
  server or the `patrimonio-mcp` CLI and enforces Patrimonio's multi-currency,
  snapshot carry-forward, and least-privilege security invariants.
---

# Patrimonio MCP & CLI Financial Operations Skill

Access Patrimonio data through **two identical, security-hardened interfaces** backed by [`backend/src/bin/patrimonio_mcp.rs`](../../../backend/src/bin/patrimonio_mcp.rs):

1. **MCP Server (`patrimonio`)**: Invoked via `call_mcp_tool` (`ServerName: "patrimonio"`).
2. **Direct CLI (`patrimonio-mcp` or [`./scripts/patrimonio-cli.sh`](./scripts/patrimonio-cli.sh))**: Run directly from a shell for terminal inspection or `jq` pipelines.

Do not run ad-hoc `psql` queries unless performing an explicitly requested administrative migration outside the read-first boundary.

---

## 1. Security Architecture & Guardrails

1. **Zero Secret Exposure**:
   - Credentials live outside git in `~/.config/patrimonio-mcp/config.env` (`chmod 0600`), never in `mcp_config.json` or command-line arguments.
   - Connects either via `DATABASE_URL` or an automatic loopback-bound (`127.0.0.1`) SSH tunnel (`PATRIMONIO_SSH_HOST`) using the dedicated PostgreSQL role **`patrimonio_mcp_ro`** (provisioned by [`scripts/setup_mcp_role.sql`](../../../scripts/setup_mcp_role.sql)).
   - PostgreSQL enforces `default_transaction_read_only = on`, `statement_timeout = '10s'`, `lock_timeout = '2s'`, and **column-level `SELECT` grants** that physically block reading `plaid_access_token_enc`, `api_key_enc`, `api_secret_enc`, `api_pass_enc`, `password_hash`, `totp_secret_enc`, `passkey_credentials`, `user_sessions`, `recovery_codes`, and `invite_tokens`.
2. **Read-First / Dry-Run Mutations**:
   - All inspection tools carry `readOnlyHint: true`.
   - Any mutating tool (`reconcile_loan_installment`) defaults to `dry_run: true` and writes every preview/commit to `~/.config/patrimonio-mcp/audit.jsonl`.
   - Never pass `dry_run: false` without first running `dry_run: true`, showing the user the `before` and `proposed_after` state, and obtaining confirmation.

---

## 2. CLI Quick Reference

Run via `patrimonio-mcp` (if installed on `$PATH`) or [`./scripts/patrimonio-cli.sh`](./scripts/patrimonio-cli.sh):

```bash
# Net worth summary (USD/MXN, live FX rate, currency & institution breakdown)
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh summary

# Carry-forward net worth history & top per-account USD movers
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh movers --start 2026-10-01 --end 2026-10-25 --top 10

# Account & institution sync/import health (pass --issues to filter to problems only)
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh accounts --issues
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh accounts --institution "Chase"

# Search transactions with per-row USD conversion
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh transactions --query "transfer" --limit 25

# Investment holdings & optional tax lots
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh holdings --symbol GOOG --lots

# Loans, repayment schedules, and automatic out-of-order/overdue anomaly checks
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh loans --status active

# Full diagnostic audit across syncs, manual imports, snapshots, loans, and notifications
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh audit

# Generic MCP tool invocation with JSON arguments
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh call reconcile_loan_installment '{"loan_id":"<uuid>","installment_number":1,"status":"paid","reason":"preview","dry_run":true}'

# Verify security guards (secret column denial, read-only enforcement, connectivity)
./.agent/skills/patrimonio-mcp/scripts/patrimonio-cli.sh self-test
```

---

## 3. Workflow Recipes & Domain Invariants

### A. Net Worth & Attribution ("Why did my net worth change?")
1. Call **`get_net_worth_summary`** (`summary`) for current USD/MXN net worth and FX rate freshness.
2. Call **`get_net_worth_history_and_movers`** (`movers --start <YYYY-MM-DD> --end <YYYY-MM-DD>`).
   - Uses Patrimonio's **carry-forward algorithm** across `balance_snapshots` (never naive `GROUP BY as_of_date`, which falsely drops accounts that didn't write a row on a given day).
   - Inspect `snapshots_written_on_date` in `daily_series` to spot any cron/sync gaps, and inspect `top_movers_by_abs_usd_change` to attribute the change to specific accounts.
3. If an investment account is a top mover, call **`get_holdings_and_lots`** (`holdings --symbol <TICKER>`) to inspect share count and price changes.

### B. Account & Sync Triage ("What accounts dropped or need re-adding?")
1. Call **`list_accounts_and_sync_health`** with `only_issues: true` (`accounts --issues`).
2. Distinguish clearly between the four categories of account issues:
   - **`plaid_reconnect_required`** (`sync_status = 'reconnect_required'`, e.g., `ITEM_LOGIN_REQUIRED`): Instruct the user to click **Reconnect** (Plaid Link Update Mode) in **Settings → Institutions**. **Never** advise deleting and re-adding a Plaid institution, because deleting cascades or orphans historical transactions and `balance_snapshots`.
   - **`manual_import_stale`** (`integration_type = 'manual'` and >35 days since last update): Instruct the user to upload the latest PDF/CSV statement under **Imports**. Note that manual US investment accounts (`Fidelity NetBenefits`, `HealthEquity HSA`) have their holdings repriced nightly at 23:00 UTC via Yahoo Finance.
   - **`archived`** (`archived_at IS NOT NULL`): Auto-archived when Plaid stops returning a closed/zero-balance sub-account or card. No action needed unless archived in error.
   - **`null_balance_warning`**: Active account with `current_balance IS NULL`.

### C. Loan & Repayment Reconciliation ("Check lending / payments for <Borrower>")
1. Call **`get_loans_and_payments`** (`loans --borrower "<Name>"`).
2. Inspect `schedule_anomalies`: installments must be satisfied sequentially (`installment_number` 1, 2, 3...) unless specifically overridden.
3. Call **`search_transactions`** (`transactions --query "<Borrower>"`) to match bank transfers against `loan_payments.actual_tx_id` and `paid_date`.
4. To fix a misaligned installment, run `reconcile_loan_installment` with `dry_run: true` first to preview the change.
