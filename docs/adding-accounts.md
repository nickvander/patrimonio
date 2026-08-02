# Adding Financial Accounts

Patrimonio supports several methods for importing your financial data safely and securely.

---

## 1. Connecting US Banks (Plaid)

For seamless connection to US-based institutions (e.g., Chase, SoFi, Fidelity), Patrimonio integrates with Plaid. Plaid provides bank-level security and read-only access to your accounts.

### How to use Plaid in Patrimonio:
1. Navigate to the **Settings** tab in your dashboard.
2. Click **Link Plaid (US Banks)**.
3. Follow the secure Plaid Link flow to authenticate with your bank.
4. Once completed, your accounts, balances, transactions, and investments will sync automatically.

> [!NOTE]
> Ensure your system administrator has configured the `PLAID_ENV`, `PLAID_CLIENT_ID`, and `PLAID_SECRET` environment variables properly in the backend configuration. Without these, Plaid integration will not work.

### Production readiness checklist

To let a real user connect Plaid and have accounts populate, verify:

- The Settings tab's **Launch setup** panel shows Plaid and credential encryption as configured.
- The Plaid dashboard app is approved for the required products: Transactions and Investments.
- `PLAID_ENV`, `PLAID_CLIENT_ID`, and `PLAID_SECRET` are set in the backend runtime.
- `ENCRYPTION_KEY` is set before exchanging public tokens.
- The frontend can reach the API host used by the browser.
- Plaid redirect and webhook URLs match the deployed HTTPS API/frontend URLs, if enabled for the environment.
- If users link from the Android app: the package name (default `com.patrimonio.patrimonio`, overridable via `PLAID_ANDROID_PACKAGE_NAME`) is registered under **Allowed Android package names** in the Plaid dashboard — OAuth institutions (e.g. U.S. Bank) cannot link from the APK without it. See the [deployment guide](deployment.md#plaid-oauth-from-the-android-app).
- The immediate sync after token exchange succeeds, and the user can also trigger `/api/institutions/sync` later.
- Empty, pending, item-error, and re-auth states are visible enough that a user knows whether data is still syncing or needs attention.

---

## 2. Connecting Cryptocurrency Exchanges

Patrimonio can pull real-time balances from popular cryptocurrency exchanges.

### Coinbase
Coinbase is integrated using standard OAuth 2.0.
- In the **Settings** tab, click **Link Coinbase**.
- You will be redirected to Coinbase to authorize read access. Once authorized, it will sync automatically.

### Bitso
For users in Mexico or LATAM using Bitso, you need to provide API keys.
1. Log in to your Bitso account on the web.
2. Go to your Profile > **API**.
3. Create a new API Key with **View balances** permissions. Do NOT grant trading or withdrawal permissions.
4. Note your API Key and API Secret.
5. In Patrimonio's **Settings** tab, click **Connect Bitso** and enter these credentials safely.

> [!CAUTION]
> Patrimonio stores api keys securely using AES-256-GCM encryption on the backend. Nevertheless, always strictly limit API key permissions to "read-only/View".

> [!NOTE]
> Crypto credentials require a configured `ENCRYPTION_KEY` in the backend environment. Without it, the API should reject credential storage rather than persisting secrets unsafely.

---

## 3. Importing Statements (CSV & PDF)

Many institutions — especially Mexican banks — do not support standard API aggregators. For these, Patrimonio provides robust local, manual importers.

- Supported Mexican institutions: **Nu Mexico**, **Banamex**, **BBVA**, **Santander**, **Banorte**, **HSBC México**, **Scotiabank**, **CetesDirecto**, **Revolut**.
- Supported US statement sources: **HealthEquity** (HSA), **Fidelity Stock Plan Services** (NetBenefits).

### How to Import
1. Download your monthly account statement (PDF) or transaction history (CSV) directly from your institution's portal.
2. In Patrimonio's **Settings** tab, click **Import a statement (CSV or PDF)**.
3. Select the target account and upload the file. (If your PDF is password-protected, the UI will prompt you to enter the password to decrypt it locally).
4. Review the parsed transactions visually in the screen and confirm the import. Transactions already in the account are flagged as duplicates at preview time, so re-uploading an overlapping statement won't double-count.

---

## 4. Manual Accounts

If you have a cash wallet, physical real estate, or a bank not supported by any automated tools, you can track it manually.
- In the **Settings** tab, click **Add manual account**.
- You can manually update the balance over time directly from the **Overview** list by clicking the "Update Balance" icon.

---

## 5. Recommended: give accounts short nicknames

Imported account names come from the institution verbatim and are often
long legal strings ("GOOGLE LLC 401(K) SAVINGS PLAN - 093926",
"… - Roth IRA Brokerage Account - ****9215"). Those names appear in every
holdings-row subtitle, account list, drawer header, tax view, and CSV
export — and on narrow screens even truncation-priority logic can only do
so much with them.

Set a **nickname** right after connecting an account: **Overview →
account row → ⋮ → Rename account** (or `PATCH /api/accounts/{id}/nickname`).
Nicknames take display priority over the imported name everywhere
(`COALESCE(NULLIF(nickname,''), name)`), while the original name is kept
for sync matching. Aim for 2–3 words that answer "which account is this?"
at a glance:

| Imported name                                        | Nickname            |
|------------------------------------------------------|---------------------|
| GOOGLE LLC 401(K) SAVINGS PLAN - 093926              | Google 401(k)       |
| … - Roth IRA Brokerage Account - ****9215            | Roth IRA            |
| Alphabet, Inc. (Morgan Stanley StockPlan)            | Alphabet GSUs       |
| Individual (Fidelity)                                | Fidelity Individual |

An empty nickname clears the override and falls back to the imported name.
