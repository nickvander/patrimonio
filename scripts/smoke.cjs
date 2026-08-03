#!/usr/bin/env node

const { execFileSync } = require('node:child_process');

const apiBase = process.env.API_BASE_URL || 'http://127.0.0.1:8080/api';
const frontendUrl = process.env.FRONTEND_URL || 'http://127.0.0.1:3000';
const skipBrowser = process.env.SKIP_BROWSER === '1';

const suffix = Date.now();
const manualAccountName = `Smoke Manual ${suffix}`;
const cryptoInstitutionName = `Smoke Bitso ${suffix}`;
// Distinctive descriptor the rules smoke matches on with `contains`.
const ruleMatchValue = `SMOKE RULE OXXO ${suffix}`;

// The smoke account persists across runs. On a fresh DB we bootstrap
// it; on subsequent runs we just log in. Both use the same fixed
// credentials so the test is idempotent.
const smokeUsername = process.env.SMOKE_USERNAME || 'smoke-user';
const smokePassword = process.env.SMOKE_PASSWORD || 'smoke-password-1234';

const results = [];
const cookieJar = new Map();

function record(name, detail) {
  results.push({ name, ...detail });
  console.log(`ok - ${name}`);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function captureCookies(response) {
  // The Set-Cookie response header can repeat — Node's fetch surfaces
  // them as a comma-joined string via .get() but exposes them
  // individually through .getSetCookie().
  const setCookies = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : [];
  for (const raw of setCookies) {
    const pair = raw.split(';')[0]?.trim();
    if (!pair) continue;
    const eq = pair.indexOf('=');
    if (eq <= 0) continue;
    const name = pair.slice(0, eq);
    const value = pair.slice(eq + 1);
    if (value === '' || /^deleted$/i.test(value)) {
      cookieJar.delete(name);
    } else {
      cookieJar.set(name, value);
    }
  }
}

function cookieHeader() {
  if (cookieJar.size === 0) return null;
  return Array.from(cookieJar.entries())
    .map(([k, v]) => `${k}=${v}`)
    .join('; ');
}

async function request(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const cookies = cookieHeader();
  if (cookies && !headers.has('cookie')) {
    headers.set('cookie', cookies);
  }
  // Auto-attach the CSRF header on every mutating method so the
  // smoke test stays in sync with `require_csrf_header` on the
  // protected router. Callers that pass their own header win.
  const method = (options.method || 'GET').toUpperCase();
  const mutating = method === 'POST' || method === 'PUT' || method === 'PATCH' || method === 'DELETE';
  if (mutating && !headers.has('x-requested-with')) {
    headers.set('x-requested-with', 'patrimonio-smoke');
  }
  const response = await fetch(`${apiBase}${path}`, { ...options, headers });
  captureCookies(response);
  const text = await response.text();
  let body = text;
  try {
    body = JSON.parse(text);
  } catch (_) {
    // Keep text body for non-JSON error responses.
  }
  return { response, body };
}

function cleanupDatabase() {
  const sql = `
    DELETE FROM transactions WHERE account_id IN (SELECT id FROM accounts WHERE name = '${manualAccountName}');
    DELETE FROM balance_snapshots WHERE account_id IN (SELECT id FROM accounts WHERE name = '${manualAccountName}');
    DELETE FROM accounts WHERE name = '${manualAccountName}';
    DELETE FROM accounts WHERE institution_id IN (SELECT id FROM institutions WHERE name = '${cryptoInstitutionName}');
    DELETE FROM institutions WHERE name = '${cryptoInstitutionName}';
    DELETE FROM ignored_subscription_merchants WHERE merchant_key LIKE 'smoke-%';
    DELETE FROM user_rules WHERE match_value LIKE 'SMOKE RULE OXXO %';
  `;

  execFileSync(
    'docker',
    ['compose', 'exec', '-T', 'postgres', 'psql', '-U', 'patrimonio', '-d', 'patrimonio', '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { stdio: 'pipe' },
  );
}

async function smokeAuth() {
  // /api/auth/status is the contract the login screen relies on.
  const status = await request('/auth/status');
  assert(status.response.status === 200, `auth status returned ${status.response.status}`);
  assert(typeof status.body === 'object', 'auth status was not JSON');

  // /api/auth/me without a cookie should 401 — proves the middleware
  // is doing its job before we authenticate.
  cookieJar.clear();
  const unauth = await request('/auth/me');
  assert(unauth.response.status === 401, `unauthed /auth/me returned ${unauth.response.status}`);

  // A protected data endpoint must also 401 without auth.
  const dashUnauth = await request('/dashboard/overview');
  assert(dashUnauth.response.status === 401, `unauthed /dashboard/overview returned ${dashUnauth.response.status}`);

  // Bootstrap if the DB is fresh; otherwise log in.
  if (status.body.needs_bootstrap === true) {
    const bootstrap = await request('/auth/bootstrap', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: smokeUsername, password: smokePassword }),
    });
    assert(bootstrap.response.status === 200, `bootstrap returned ${bootstrap.response.status}: ${JSON.stringify(bootstrap.body)}`);
  } else {
    const login = await request('/auth/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: smokeUsername, password: smokePassword }),
    });
    assert(
      login.response.status === 200,
      `login as ${smokeUsername} returned ${login.response.status}: ${JSON.stringify(login.body)}. ` +
        `If the DB already has a different user, set SMOKE_USERNAME and SMOKE_PASSWORD env vars.`,
    );
  }
  assert(cookieJar.has('patrimonio_session'), 'session cookie was not set after auth');

  // /me with cookie should now work and report our username.
  const me = await request('/auth/me');
  assert(me.response.status === 200, `/auth/me after login returned ${me.response.status}`);
  assert(
    typeof me.body === 'object' && me.body.username === smokeUsername,
    `/auth/me did not return expected username, got ${JSON.stringify(me.body)}`,
  );

  record('auth bootstrap/login flow', { user: smokeUsername });
}

async function smokeApi() {
  const health = await request('/health');
  assert(health.response.status === 200, `health returned ${health.response.status}`);
  assert(health.body.status === 'ok', 'health body did not report ok');
  record('api health', { status: health.response.status });

  for (const endpoint of [
    '/dashboard/overview',
    '/dashboard/net-worth-history',
    '/dashboard/holdings',
    '/dashboard/credit-utilization',
    '/dashboard/sync-status',
    '/dashboard/transactions',
    '/dashboard/allocation',
    '/dashboard/trends',
    '/setup/status',
    '/fx/latest/USD/MXN',
    '/tax/summary',
  ]) {
    const { response } = await request(endpoint);
    assert(response.status === 200, `${endpoint} returned ${response.status}`);
  }
  record('dashboard and tax endpoints', { status: 200 });
}

async function smokeManualAccountAndImport() {
  const created = await request('/accounts', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      name: manualAccountName,
      account_type: 'checking',
      currency: 'USD',
      initial_balance: 12.34,
    }),
  });
  assert(created.response.status === 201, `manual account create returned ${created.response.status}`);

  const listed = await request('/accounts');
  assert(listed.response.status === 200, `accounts list returned ${listed.response.status}`);
  const account = listed.body.find((item) => item.name === manualAccountName);
  assert(account, 'created manual account not found in account list');

  const updated = await request(`/accounts/${account.id}/balance`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ current_balance: 56.78 }),
  });
  assert(updated.response.status === 200, `balance update returned ${updated.response.status}`);

  const imported = await request('/imports/confirm', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      account_id: account.id,
      transactions: [
        {
          date: '2026-01-02',
          description: `Smoke import ${suffix}`,
          amount: -4.56,
          currency: 'USD',
          category: 'Smoke',
        },
      ],
    }),
  });
  assert(imported.response.status === 200, `import confirm returned ${imported.response.status}`);
  assert(imported.body.new_transactions === 1, 'import confirm did not insert one transaction');

  const transactions = await request(`/accounts/${account.id}/transactions`);
  assert(transactions.response.status === 200, `account transactions returned ${transactions.response.status}`);
  assert(transactions.body.length === 1, `expected one smoke transaction, found ${transactions.body.length}`);

  const emptyUpload = await fetch(`${apiBase}/imports/upload`, {
    method: 'POST',
    body: new FormData(),
    // FormData uploads also need the CSRF header — fetch can't pull
    // it from the request() helper because we bypass it for the
    // multipart body.
    headers: {
      'x-requested-with': 'patrimonio-smoke',
      ...(cookieHeader() ? { cookie: cookieHeader() } : {}),
    },
  });
  assert(emptyUpload.status === 400, `empty upload returned ${emptyUpload.status}`);

  record('manual account and import flow', { accountId: account.id });
  return { accountId: account.id, transactionId: transactions.body[0].id };
}

/// Exercise the surfaces that landed in recent sprints: split /
/// edit-split (via PUT) / unsplit, the subscription dismiss
/// roundtrip, and the FX-transfer detect endpoint. The smoke
/// account starts with a single $4.56 expense seeded by
/// smokeManualAccountAndImport; we re-use it for the split flow.
async function smokeRecentFeatures({ accountId, transactionId }) {
  // ---- splits: POST -> PUT (atomic edit) -> DELETE ----
  const split = await request(`/accounts/transactions/${transactionId}/splits`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      splits: [
        { description: 'Smoke half A', amount: -2.28 },
        { description: 'Smoke half B', amount: -2.28 },
      ],
    }),
  });
  assert(split.response.status === 201, `split returned ${split.response.status}: ${JSON.stringify(split.body)}`);

  // The parent is hidden once it has children; both children appear
  // in the transactions list with parent_id set.
  const afterSplit = await request('/dashboard/transactions?limit=200');
  const children = (afterSplit.body || []).filter((t) => t.parent_id === transactionId);
  assert(children.length === 2, `expected 2 split children, got ${children.length}`);

  // Re-splitting via POST would 422 ("already split"). The new PUT
  // endpoint atomically replaces.
  const edit = await request(`/accounts/transactions/${transactionId}/splits`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      splits: [
        { description: 'Smoke 60', amount: -2.74 },
        { description: 'Smoke 40', amount: -1.82 },
      ],
    }),
  });
  assert(edit.response.status === 200, `edit-split returned ${edit.response.status}: ${JSON.stringify(edit.body)}`);
  assert(edit.body.removed === 2, `edit-split should report removed=2, got ${edit.body.removed}`);
  assert(edit.body.inserted === 2, `edit-split should report inserted=2, got ${edit.body.inserted}`);

  // Unsplit restores the parent.
  const unsplit = await request(`/accounts/transactions/${transactionId}/splits`, {
    method: 'DELETE',
  });
  assert(unsplit.response.status === 200, `unsplit returned ${unsplit.response.status}`);

  record('split / edit-split / unsplit round-trip', { transactionId });

  // ---- subscriptions: ignore + list + un-ignore ----
  const ignoreKey = `smoke-merchant-${suffix}`;
  const ignore = await request('/dashboard/subscriptions/ignore', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ merchant: ignoreKey }),
  });
  assert(ignore.response.status === 204, `subscription ignore returned ${ignore.response.status}`);

  const listed = await request('/dashboard/subscriptions/ignored');
  assert(listed.response.status === 200, `subscription ignored list returned ${listed.response.status}`);
  const row = (listed.body || []).find((r) => r.merchant_key === ignoreKey);
  assert(row, `dismissed merchant not in /ignored list — got ${JSON.stringify(listed.body)}`);

  const unignore = await request(
    `/dashboard/subscriptions/ignored/${encodeURIComponent(ignoreKey)}`,
    { method: 'DELETE' },
  );
  assert(unignore.response.status === 204, `subscription unignore returned ${unignore.response.status}`);
  record('subscription ignore / unignore round-trip', { merchantKey: ignoreKey });

  // ---- since-last-login: shape check ----
  const sll = await request('/dashboard/since-last-login');
  assert(sll.response.status === 200, `since-last-login returned ${sll.response.status}`);
  // The endpoint always returns a JSON object with at least new_transactions
  // (the rest of the fields are conditional on having a prior login).
  assert(
    typeof sll.body === 'object' && 'new_transactions' in sll.body,
    `since-last-login shape unexpected: ${JSON.stringify(sll.body)}`,
  );
  record('since-last-login shape', { newTransactions: sll.body.new_transactions });

  // ---- fx-transfer detect: should run cleanly even with no candidates ----
  const fxList = await request('/dashboard/fx-transfers');
  assert(fxList.response.status === 200, `fx-transfers GET returned ${fxList.response.status}`);
  assert(Array.isArray(fxList.body), `fx-transfers GET should return an array`);
  const fxDetect = await request('/dashboard/fx-transfers', { method: 'POST' });
  assert(fxDetect.response.status === 200, `fx-transfers detect returned ${fxDetect.response.status}`);
  assert(
    typeof fxDetect.body === 'object' &&
      typeof fxDetect.body.checked === 'number' &&
      typeof fxDetect.body.inserted === 'number',
    `fx-transfers detect shape unexpected: ${JSON.stringify(fxDetect.body)}`,
  );
  record('fx-transfer listing and detect', {
    checked: fxDetect.body.checked,
    inserted: fxDetect.body.inserted,
  });

  // ---- detected subscriptions: shape check + by_account presence ----
  const subs = await request('/dashboard/subscriptions');
  assert(subs.response.status === 200, `subscriptions returned ${subs.response.status}`);
  assert(Array.isArray(subs.body), `subscriptions should return an array`);
  // Each row should have a by_account array (length >= 1) per the
  // per-account-split work that just landed.
  for (const sub of subs.body) {
    assert(
      Array.isArray(sub.by_account) && sub.by_account.length >= 1,
      `subscription ${sub.merchant} missing by_account: ${JSON.stringify(sub)}`,
    );
  }
  record('detected subscriptions shape', { count: subs.body.length });
}

/// User rules engine (work/RULES_ENGINE_DESIGN.md §6): create -> preview
/// -> apply, asserting the one property the whole feature rests on —
/// a rule rewrites the rows it previewed and NEVER a row a human edited
/// by hand. Also pins the single-use preview token and DEC-028 (deleting
/// a rule keeps the values it already applied).
async function smokeRules({ accountId }) {
  // Two rows matching the same descriptor; one of them then gets a
  // manual category edit, which must fence it off from the rule.
  const seeded = await request('/imports/confirm', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      account_id: accountId,
      transactions: [
        { date: '2026-02-03', description: `${ruleMatchValue} A`, amount: -11.11, currency: 'USD', category: 'Smoke' },
        { date: '2026-02-04', description: `${ruleMatchValue} B`, amount: -22.22, currency: 'USD', category: 'Smoke' },
      ],
    }),
  });
  assert(seeded.response.status === 200, `rules seed import returned ${seeded.response.status}`);
  assert(seeded.body.new_transactions === 2, `rules seed inserted ${seeded.body.new_transactions} rows, expected 2`);

  const listed = await request(`/accounts/${accountId}/transactions`);
  assert(listed.response.status === 200, `account transactions returned ${listed.response.status}`);
  const rowA = listed.body.find((t) => t.description === `${ruleMatchValue} A`);
  const rowB = listed.body.find((t) => t.description === `${ruleMatchValue} B`);
  assert(rowA && rowB, 'seeded rule rows not found in the account');

  // Row B becomes a manual edit — the layer no rule may ever overwrite.
  const manual = await request(`/accounts/transactions/${rowB.id}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ user_category: 'Smoke Manual' }),
  });
  assert(manual.response.status === 200, `manual category edit returned ${manual.response.status}`);

  const definition = {
    match_type: 'contains',
    match_value: ruleMatchValue,
    set_category: 'Smoke Rules',
  };

  const created = await request('/rules', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(definition),
  });
  assert(created.response.status === 201, `rule create returned ${created.response.status}: ${JSON.stringify(created.body)}`);
  const ruleId = created.body.id;
  assert(ruleId, 'rule create did not return an id');

  // Creating the rule must not have touched a single transaction.
  const afterCreate = await request(`/accounts/${accountId}/transactions`);
  const untouchedA = afterCreate.body.find((t) => t.id === rowA.id);
  assert(
    !untouchedA.user_category,
    `creating a rule changed a transaction: ${JSON.stringify(untouchedA.user_category)}`,
  );

  const preview = await request('/rules/preview', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(definition),
  });
  assert(preview.response.status === 200, `rule preview returned ${preview.response.status}: ${JSON.stringify(preview.body)}`);
  assert(preview.body.matched >= 2, `preview matched ${preview.body.matched}, expected >= 2`);
  assert(preview.body.category_changes >= 1, `preview reported ${preview.body.category_changes} category changes`);
  assert(preview.body.skipped_manual >= 1, `preview reported ${preview.body.skipped_manual} manual skips, expected >= 1`);
  const token = preview.body.preview_token;
  assert(typeof token === 'string' && token.length > 0, 'preview did not mint a token');

  const applied = await request(`/rules/${ruleId}/apply`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ preview_token: token }),
  });
  assert(applied.response.status === 200, `rule apply returned ${applied.response.status}: ${JSON.stringify(applied.body)}`);
  assert(applied.body.updated_category >= 1, `apply updated ${applied.body.updated_category} categories, expected >= 1`);

  // The whole point: the previewed row changed, the hand-edited one did not.
  const afterApply = await request(`/accounts/${accountId}/transactions`);
  const finalA = afterApply.body.find((t) => t.id === rowA.id);
  const finalB = afterApply.body.find((t) => t.id === rowB.id);
  assert(
    finalA.user_category === 'Smoke Rules',
    `rule did not apply to the unedited row: ${JSON.stringify(finalA.user_category)}`,
  );
  assert(
    finalB.user_category === 'Smoke Manual',
    `rule clobbered a manually edited row: ${JSON.stringify(finalB.user_category)}`,
  );

  // The token is single-use: a replay (double-click) must not re-fire.
  const replay = await request(`/rules/${ruleId}/apply`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ preview_token: token }),
  });
  assert(replay.response.status === 409, `replayed apply returned ${replay.response.status}, expected 409`);

  // DEC-028: deleting a rule keeps the values it already applied.
  const removed = await request(`/rules/${ruleId}`, { method: 'DELETE' });
  assert(removed.response.status === 204, `rule delete returned ${removed.response.status}`);
  const afterDelete = await request(`/accounts/${accountId}/transactions`);
  const keptA = afterDelete.body.find((t) => t.id === rowA.id);
  assert(
    keptA.user_category === 'Smoke Rules',
    `deleting the rule rewrote history: ${JSON.stringify(keptA.user_category)}`,
  );

  record('rules create/preview/apply flow', {
    matched: preview.body.matched,
    updatedCategory: applied.body.updated_category,
    skippedManual: preview.body.skipped_manual,
  });
}

async function smokeIntegrationStates() {
  const plaidLink = await request('/institutions/link-token', { method: 'POST' });
  assert([200, 503].includes(plaidLink.response.status), `plaid link-token returned ${plaidLink.response.status}`);

  const malformedExchange = await request('/institutions/exchange-token', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ institution_name: 'Smoke Plaid Missing Token' }),
  });
  assert(malformedExchange.response.status === 422, `malformed Plaid exchange returned ${malformedExchange.response.status}`);

  const coinbase = await fetch(`${apiBase}/auth/coinbase`, {
    redirect: 'manual',
    headers: cookieHeader() ? { cookie: cookieHeader() } : {},
  });
  assert([302, 303, 307, 308].includes(coinbase.status), `Coinbase auth returned ${coinbase.status}`);

  const crypto = await request('/institutions/crypto', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      name: cryptoInstitutionName,
      integration_type: 'bitso',
      api_key: 'fake-key',
      api_secret: 'fake-secret',
    }),
  });
  assert([200, 201, 503].includes(crypto.response.status), `crypto setup returned ${crypto.response.status}`);

  record('integration setup/error states', {
    plaidLinkStatus: plaidLink.response.status,
    cryptoStatus: crypto.response.status,
  });
}

async function smokeBrowser() {
  if (skipBrowser) {
    record('browser boot skipped', { skipped: true });
    return;
  }

  let chromium;
  try {
    ({ chromium } = require('playwright'));
  } catch (error) {
    throw new Error('Playwright is required for browser smoke checks. Install it or run with SKIP_BROWSER=1.');
  }

  const browser = await chromium.launch({
    headless: true,
    args: ['--disable-dev-shm-usage', '--enable-unsafe-swiftshader'],
  });

  try {
    for (const [name, viewport, isMobile] of [
      ['desktop', { width: 1440, height: 1000 }, false],
      ['mobile', { width: 390, height: 844 }, true],
    ]) {
      const context = await browser.newContext({ viewport, isMobile });

      // Pre-seed the browser with our smoke session cookie so the
      // Flutter app boots straight into the dashboard instead of
      // showing the login screen. Browser smoke is about render
      // correctness, not the login UI.
      const sessionToken = cookieJar.get('patrimonio_session');
      if (sessionToken) {
        const url = new URL(frontendUrl);
        await context.addCookies([{
          name: 'patrimonio_session',
          value: sessionToken,
          domain: url.hostname,
          path: '/',
          httpOnly: true,
          sameSite: 'Lax',
        }]);
      }

      const page = await context.newPage();
      const failed = [];
      const apiResponses = [];

      page.on('requestfailed', (request) => failed.push(`${request.url()} ${request.failure()?.errorText || ''}`));
      page.on('response', (response) => {
        const url = response.url();
        if (url.includes('/api/')) {
          apiResponses.push({ url, status: response.status() });
        }
      });

      await page.goto(`${frontendUrl}/?smoke=${suffix}-${name}`, {
        waitUntil: 'domcontentloaded',
        timeout: 30000,
      });
      await page.waitForFunction(
        () => document.querySelector('flutter-view') || document.querySelector('flt-glass-pane'),
        null,
        { timeout: 60000 },
      );
      await page.waitForFunction(() => !document.querySelector('#splash'), null, { timeout: 30000 });
      await page.waitForTimeout(3000);

      const state = await page.evaluate(() => ({
        hasFlutterView: Boolean(document.querySelector('flutter-view')),
        hasGlassPane: Boolean(document.querySelector('flt-glass-pane')),
        hasSplash: Boolean(document.querySelector('#splash')),
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
      }));

      assert(state.hasFlutterView || state.hasGlassPane, `${name} did not render Flutter root`);
      assert(!state.hasSplash, `${name} splash still visible`);
      assert(state.scrollWidth === state.clientWidth, `${name} has document horizontal overflow`);
      assert(failed.length === 0, `${name} had failed requests: ${failed.join(', ')}`);
      assert(apiResponses.length > 0, `${name} did not call API endpoints`);
      // 401 is OK during boot for the unauth probe; we only fail on
      // 5xx and unexpected 4xx outside the auth surface.
      const bad = apiResponses.filter((item) =>
        item.status >= 500 ||
        (item.status >= 400 && item.status !== 401 && !item.url.includes('/auth/')),
      );
      assert(bad.length === 0, `${name} had non-OK API responses: ${JSON.stringify(bad)}`);
      await page.close();
      await context.close();
    }
  } finally {
    await browser.close();
  }

  record('browser frontend boot', { frontendUrl });
}

(async () => {
  try {
    await smokeAuth();
    await smokeApi();
    const seeded = await smokeManualAccountAndImport();
    await smokeRecentFeatures(seeded);
    await smokeRules(seeded);
    await smokeIntegrationStates();
    await smokeBrowser();
  } finally {
    cleanupDatabase();
  }

  console.log(JSON.stringify({ ok: true, results }, null, 2));
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
