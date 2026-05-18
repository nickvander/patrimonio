# Multi-currency: how Patrimonio handles USD + MXN

A short, plain-English guide to how the app tracks bi-national money.
There are **two distinct pipelines** here — they sound similar but
solve different problems. Knowing which one applies to a given number
makes the dashboard a lot less mysterious.

## TL;DR

* **Investment positions** (stocks, ETFs, mutual funds in a brokerage)
  have FX-aware cost basis. Each buy is recorded at that day's USDMXN
  rate. Your MXN profit / loss is genuinely computed, not just a
  current-FX conversion of the USD number.
* **Cash transfers between currencies** (US bank → Wise → Nu Bank, or
  similar) are **not linked yet**. They show up as two unrelated
  transactions and the implicit Wise FX rate isn't stored anywhere.
  That's tracked as a future enhancement.

## Pipeline 1: investment lots (shipped)

### What's a "lot"?

A lot is one acquisition event. Buying 10 shares of VTI on March 5
creates one lot. Buying 5 more shares on April 12 creates a second
lot — different price, different date, possibly different FX rate.
Selling shares depletes lots oldest-first (FIFO — the IRS default).

### What gets recorded per lot

| Field | Meaning |
|---|---|
| `acquired_at` | The trade date. |
| `qty` | Number of shares. |
| `cost_per_unit` | Price per share at the trade. |
| `currency` | The native currency the trade settled in (USD for a US broker; MXN for a Mexican one). |
| `usd_fx_rate` | The USDMXN exchange rate **on the trade date**. `1.0` for USD-denominated securities; the historical rate for MXN-denominated ones. |
| `source_id` | Plaid's `investment_transaction_id`. Used so re-syncs never duplicate lots. |

### Where the data comes from

Every time you click **Sync all accounts**, the backend hits Plaid's
`/investments/transactions/get` endpoint per linked brokerage. Each
returned transaction maps to either:

* a `buy` (and `dividend reinvestment`) → **insert a new lot**
* a `sell` → **FIFO-deplete the oldest lots**
* a cash dividend / fee / deposit / withdrawal → **skipped** (no
  share change; that data lives on the regular cash transactions
  side)

### What this gives you

The portfolio card shows a side-by-side panel:

```
USD US Dollar             MXN Mexican Peso
Total value $X            Total value MX$Y
Profit / Loss …           Profit / Loss …
```

The MXN side isn't just "USD value × current FX" — it's computed
lot-by-lot using each lot's own historical FX rate. So a holding
bought when USDMXN was 17.5 and held until USDMXN is 19.0 shows a
*different* MXN P&L than a naive current-FX conversion would.

### What can make the MXN side look wrong

* **You haven't synced since the lot code shipped.** The endpoint
  falls back to `holdings.cost_basis × current FX`, which is correct
  in USD and approximate in MXN. Fix: click Sync.
* **Your broker doesn't expose the `investments` product to Plaid.**
  Some don't — you'll see `INVALID_PRODUCT` / `PRODUCTS_NOT_SUPPORTED`
  in the backend logs. The fallback computation still applies.
* **The buy was outside the 1-year lookback window.** The sync pulls
  the trailing 12 months. Older lots aren't backfilled. (Bumping the
  window is a one-line change if it ever matters.)

## Pipeline 2: cross-currency cash transfers (not shipped)

Your real-life flow:

```
US bank account (USD)  →  Wise (does FX: USD→MXN)  →  Nu Bank (MXN)
```

This is **not** the same as buying an investment. There's no
security, no lot, no brokerage. Wise just converts dollars to pesos
at whatever rate it offers that day.

### What the app sees today

Two completely separate `transactions` rows:

* US bank: a USD outflow.
* Nu Bank: an MXN inflow.

They aren't linked. The implicit Wise FX rate isn't stored. Patrimonio
treats this as "USD disappeared and MXN appeared", which is
technically true but not useful.

### What "tracking it properly" would mean

The future-work item (see `work/FUTURE.md` 2b) is the auto-linker:

1. Notice that a USD outflow + MXN inflow happened within a few days
   and that the amounts back-out to a plausible FX rate.
2. Bonus: the description contains a remittance keyword (`WISE`,
   `REMITLY`, `XOOM`, `WESTERN UNION`).
3. Create a link row recording the pair + the back-computed rate.
4. Surface the link in the transaction detail modal so you can see
   "this $1,000 USD outflow corresponds to this MX$19,500 inflow at
   an implied rate of 19.50".
5. Cash-flow tab gets a "Cross-currency transfers" line showing each
   transfer's implied rate next to the day's spot rate — so you can
   see whether Wise gave you a good deal that day.

### What's deliberately NOT in scope

Tracking "realized FX gain/loss on the MXN cash you held over time"
is a harder model question — when does "the MXN I got from Wise on
May 5" stop being a distinct unit? Every Nu Bank outflow is
arguably a partial disposal of that pool. That's only worth solving
if it shows up as an actual user complaint.

## What if the dashboard says "MX$0.00 P&L" but I have MXN holdings?

Two likely causes, both fixable:

1. **You haven't synced since the dual-currency code shipped.**
   The endpoint reads the new fields only after the backend writes
   them. Click Sync.
2. **The `exchange_rates` table doesn't have a USDMXN row for your
   sync date.** Fall-through path: latest rate is used; if there's
   no rate at all, a hardcoded 20.0 is the absolute last resort.
   Check the FX badge in the dashboard header — if it's showing a
   real number you're fine.

## Cheat sheet for reading the portfolio card

| You see | It means |
|---|---|
| USD tile shows a number, MXN tile shows the same number ÷ current FX | Lots haven't populated yet — fallback path. Sync to fix. |
| MXN P&L % differs from USD P&L % | Lots have populated, you're seeing true FX-aware P&L. The two percentages will only match exactly if the FX rate hasn't moved since acquisition. |
| Both tiles say "—" or hide entirely | The backend response didn't include the new fields. Old build, redeploy. |
| Either tile is empty but the other has data | Shouldn't happen — file a bug. |
