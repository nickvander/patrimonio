# Manual test checklist — real-estate / manual assets

> Run this against `http://localhost:3000` on your browser after
> merging `claude/suspicious-chatterjee-c8cfda` to main. The
> categorisation logic itself is covered by 40/40 passing Dart unit
> tests in `frontend/test/utils/account_category_test.dart`; this
> checklist is the visual + integration confirmation against the
> live stack.

## Prereqs

* `docker compose -p patrimonio ps` shows api, frontend, postgres,
  redis all Up. Postgres marked healthy.
* You're signed in at `http://localhost:3000` (your normal session).

## 1. Add-account dialog: grouped sections

1. Click **Management** tab.
2. Click **Add manual account** (or the equivalent button on
   Management).
3. Click the **Account type** dropdown.

Expected (regression-prone):
* Five disabled section headers in uppercase, in order:
  `CASH & BANKING`, `INVESTMENTS`, `CRYPTO`, `REAL ASSETS`,
  `LIABILITIES`.
* Under `REAL ASSETS`: **Real Estate · Vehicle · Private Equity ·
  Collectibles · Other Asset**.
* Section headers are NOT selectable (clicking them shouldn't
  change the dropdown's value).
* Each type entry is indented under its section.

If any of these fail, the dropdown wiring in `add_account_dialog.dart`
is wrong — open an issue or revert.

## 2. Create a Real Estate test account

1. In the Add dialog, type:
   * **Account name**: `Test House`
   * **Account type**: Real Estate (under `REAL ASSETS`)
   * **Currency**: USD
   * **Initial balance**: `500000`
2. Click **Create account**.

Expected:
* Snackbar `Account "Test House" created!`.
* Dialog dismisses.
* The dashboard reloads.

## 3. Real assets group on the Accounts column

Go to the **Overview** tab.

Expected:
* In the left ACCOUNTS column, after Loans (if any) and before
  Other, a new group `Real assets` appears with:
  - A house/work icon (`Icons.maps_home_work_rounded`).
  - Yellow accent.
  - `Test House  USD 500,000.00` row inside it.
* The Manual institution row continues to show its own Manual
  group separately (don't get confused — Manual is the
  institution; Real assets is the category).

## 4. Real assets KPI tile

Look at the KPI stat strip at the top of Overview.

Expected:
* A 6th tile appears: **REAL ASSETS · USD 500,000.00** with a yellow
  accent dot.
* All 6 tiles fit on one row on a wide viewport (>= 880px wide):
  Net worth / Assets / Liabilities / Cash / Investments / Real assets.
* Tiles are equal width — no wrap, no overflow, no horizontal scroll.
* Net worth tile updates to reflect the +$500k.
* Assets tile (= net worth + liabilities) also updates.

Resize the window narrower (under 880px) and confirm the tiles wrap
onto two rows cleanly (`(maxWidth − 12) / 2` math).

## 5. Add a second real asset — verify they bucket together

1. Management tab → Add manual account.
2. Name: `Test Car`, Type: **Vehicle**, Currency: USD,
   Initial balance: `25000`.
3. Save.

Expected:
* The Real assets group on Overview now lists BOTH `Test House`
  (USD 500,000) AND `Test Car` (USD 25,000).
* The Real assets KPI tile reads **USD 525,000.00**.
* Net worth ↑ by another $25k.

## 6. Revalue (the existing balance-update flow)

1. On the Accounts column, click the `Test Car` row to open the
   account-detail side panel.
2. Find the **Update balance** affordance (kebab menu / edit icon).
3. Change the balance to `22500` (depreciation).
4. Save.

Expected:
* Snackbar / quiet confirmation.
* Test Car row updates to USD 22,500.
* Real assets KPI tile updates to USD 522,500.
* A new entry lands in `balance_snapshots` for today
  (verify via `docker exec patrimonio-postgres-1 psql -U patrimonio
  -d patrimonio -c "SELECT * FROM balance_snapshots WHERE account_id
  = (SELECT id FROM accounts WHERE name = 'Test Car') ORDER BY
  as_of_date DESC LIMIT 2;"`).

## 7. Net-worth history picks it up

1. Click the **YTD** or **1Y** preset on the Net worth chart.
2. Verify the line jumps UP at today's date by ~$525k vs yesterday
   (or wherever the first snapshot landed).

This confirms the snapshots → history chart pipeline includes
manually-added assets without any code change — they look like any
other account to `net_worth_history`.

## 8. Cleanup

Delete both test accounts so they don't pollute your real net worth:

1. Management tab → click the `…` menu on `Test House` →
   **Delete account**. Confirm.
2. Same for `Test Car`.

Expected:
* Both rows disappear from the Accounts column.
* Real assets group disappears (since count = 0).
* Real assets KPI tile disappears (since total = 0).
* Net worth + Assets KPI tiles reverse the +$525k bump.

## Sanity checks (any tab)

* No new errors in browser console (DevTools → Console).
* No new error logs from the api:
  `docker logs --since 5m patrimonio-api-1 | grep -iE "error|panic"`.
* `migration_head` is `2026051806` (no schema regression):
  `docker exec patrimonio-postgres-1 psql -U patrimonio -d patrimonio
   -At -c "SELECT MAX(version) FROM _sqlx_migrations;"`.

## If something looks wrong

* `Real assets` group missing on Overview but accounts created
  successfully: the categorizer didn't pick up the account_type
  string. Check the actual stored value:
  `docker exec patrimonio-postgres-1 psql -U patrimonio -d patrimonio
   -c "SELECT name, account_type FROM accounts WHERE name LIKE 'Test%';"`.
  Then check `frontend/lib/utils/account_category.dart` to confirm
  the type matches one of the realAsset substring rules.
* KPI tile overflows on wide screen: the `(c.maxWidth - (n - 1) * 12) / n`
  math in `_buildStatStrip` is the fix — confirm it's still in
  `dashboard_screen.dart`.
* "Auto Loan" account lands in Real assets (regression): the
  ordering in `categorizeAccount` matters — loan-side checks must
  run BEFORE the realAsset block. The unit test in
  `frontend/test/utils/account_category_test.dart` covers this.
