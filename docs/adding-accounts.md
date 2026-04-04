# Adding Financial Accounts

Patrimonio supports several methods for importing your financial data safely and securely.

---

## 1. Connecting US Banks (Plaid)

For seamless connection to US-based institutions (e.g., Chase, SoFi, Fidelity), Patrimonio integrates with Plaid. Plaid provides bank-level security and read-only access to your accounts.

### How to use Plaid in Patrimonio:
1. Navigate to the **Management** tab in your dashboard.
2. Click **Link Plaid (US Banks)**.
3. Follow the secure Plaid Link flow to authenticate with your bank.
4. Once completed, your accounts, balances, transactions, and investments will sync automatically.

> [!NOTE]
> Ensure your system administrator has configured the `PLAID_ENV`, `PLAID_CLIENT_ID`, and `PLAID_SECRET` environment variables properly in the backend configuration. Without these, Plaid integration will not work.

---

## 2. Connecting Cryptocurrency Exchanges

Patrimonio can pull real-time balances from popular cryptocurrency exchanges.

### Coinbase
Coinbase is integrated using standard OAuth 2.0.
- In the **Management** tab, click **Link Coinbase**.
- You will be redirected to Coinbase to authorize read access. Once authorized, it will sync automatically.

### Bitso
For users in Mexico or LATAM using Bitso, you need to provide API keys.
1. Log in to your Bitso account on the web.
2. Go to your Profile > **API**.
3. Create a new API Key with **View balances** permissions. Do NOT grant trading or withdrawal permissions.
4. Note your API Key and API Secret.
5. In Patrimonio's **Management** tab, click **Connect Bitso** and enter these credentials safely.

> [!CAUTION]
> Patrimonio stores api keys securely using AES-256-GCM encryption on the backend. Nevertheless, always strictly limit API key permissions to "read-only/View".

---

## 3. Importing Mexican Accounts (CSV & PDF)

Many Mexican institutions do not support standard API aggregators. For these, Patrimonio provides robust local, manual importers.

- Supported Banks: **Banamex**, **Nu Mexico**, **CetesDirecto**.

### How to Import
1. Download your monthly account statement (PDF) or transaction history (CSV) directly from your institution's portal.
2. In Patrimonio's **Management** tab, click **Import Mexico (CSV/PDF)**.
3. Select the target account and upload the file. (If your PDF is password-protected, the UI will prompt you to enter the password to decrypt it locally).
4. Review the parsed transactions visually in the screen and confirm the import.

---

## 4. Manual Accounts

If you have a cash wallet, physical real estate, or a bank not supported by any automated tools, you can track it manually.
- In the **Management** tab, click **Add Manual Account**.
- You can manually update the balance over time directly from the **Overview** list by clicking the "Update Balance" icon.
