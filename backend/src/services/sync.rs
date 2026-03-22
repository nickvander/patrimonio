use anyhow::Result;
use sqlx::PgPool;

/// Sync engine stub — will be expanded in Phase 2 with Plaid integration
/// and Phase 4 with CSV/PDF import support.
pub async fn sync_all_institutions(_db: &PgPool) -> Result<()> {
    tracing::info!("Sync engine: starting sync for all institutions");

    // TODO Phase 2: Query institutions with integration_type = 'plaid'
    //   - For each, call Plaid /transactions/sync and /investments/holdings/get
    //   - Update accounts and holdings tables
    //   - Create balance_snapshots

    // TODO Phase 4: Handle integration_type = 'csv_upload'
    //   - Process any pending file uploads
    //   - Parse CSV/PDF and upsert transactions

    tracing::info!("Sync engine: sync complete");
    Ok(())
}
