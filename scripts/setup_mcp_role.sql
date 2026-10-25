-- =============================================================================
-- Patrimonio MCP Least-Privilege Role Provisioning (setup_mcp_role.sql)
-- =============================================================================
-- Creates or updates the dedicated `patrimonio_mcp_ro` PostgreSQL role used by
-- the `patrimonio_mcp` Model Context Protocol server.
--
-- Security invariants enforced at the PostgreSQL engine level:
--   1. Read-only transactions by default (`default_transaction_read_only = on`).
--   2. Strict statement (10s), lock (2s), and idle-in-transaction (10s) timeouts
--      to prevent runaway queries or table-lock contention.
--   3. Zero access to authentication/secret tables (`passkey_credentials`,
--      `recovery_codes`, `user_sessions`, `invite_tokens`, `auth_audit`).
--   4. Column-level SELECT grants on `users` and `institutions` so PostgreSQL
--      physically blocks any query from reading `password_hash`, `totp_secret_enc`,
--      `plaid_access_token_enc`, `api_key_enc`, `api_secret_enc`, `api_pass_enc`,
--      or `plaid_transactions_cursor`.
--
-- Usage:
--   psql -U patrimonio -d patrimonio -v mcp_password="'<strong-random-secret>'" \
--        -f scripts/setup_mcp_role.sql
-- =============================================================================

\set ON_ERROR_STOP on

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'patrimonio_mcp_ro') THEN
        CREATE ROLE patrimonio_mcp_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION CONNECTION LIMIT 5;
    END IF;
END
$$;

-- Apply password if passed via -v mcp_password="'...'"
\if :{?mcp_password}
ALTER ROLE patrimonio_mcp_ro WITH PASSWORD :mcp_password;
\endif

-- Engine-enforced read-only & DoS protection settings
ALTER ROLE patrimonio_mcp_ro SET default_transaction_read_only = on;
ALTER ROLE patrimonio_mcp_ro SET statement_timeout = '10s';
ALTER ROLE patrimonio_mcp_ro SET lock_timeout = '2s';
ALTER ROLE patrimonio_mcp_ro SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE patrimonio_mcp_ro SET search_path = public;

-- Reset privileges cleanly before granting explicit allow-list
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM patrimonio_mcp_ro;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM patrimonio_mcp_ro;
GRANT USAGE ON SCHEMA public TO patrimonio_mcp_ro;

-- Column-level SELECT on `users` (excludes password_hash, totp_secret_enc, totp_last_used_step)
GRANT SELECT (
    id,
    username,
    email,
    is_active,
    created_at,
    last_login_at,
    previous_login_at,
    role,
    last_visit_at,
    previous_visit_at
) ON TABLE public.users TO patrimonio_mcp_ro;

-- Column-level SELECT on `institutions` (excludes plaid_access_token_enc, api_key_enc,
-- api_secret_enc, api_pass_enc, plaid_transactions_cursor)
GRANT SELECT (
    id,
    name,
    institution_type,
    country,
    integration_type,
    plaid_item_id,
    last_synced_at,
    sync_status,
    created_at,
    last_sync_error,
    user_id,
    sync_started_at
) ON TABLE public.institutions TO patrimonio_mcp_ro;

-- Financial domain tables (safe for read-only agent analysis)
GRANT SELECT ON TABLE
    public.accounts,
    public.app_settings,
    public.asset_class_overrides,
    public.balance_snapshots,
    public.benchmark_prices,
    public.cash_fx_transfers,
    public.dismissed_fx_pairs,
    public.exchange_rates,
    public.holding_lots,
    public.holdings,
    public.ignored_subscription_merchants,
    public.loan_payments,
    public.loans,
    public.lot_disposals,
    public.people,
    public.recurring_rules,
    public.transactions,
    public.user_fx_alerts,
    public.user_notifications,
    public.user_rules
TO patrimonio_mcp_ro;

-- Helper functions (e.g., is_liability_account_type)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO patrimonio_mcp_ro;
