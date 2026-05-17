#!/usr/bin/env node

const { execFileSync } = require('node:child_process');

const apiBase = process.env.API_BASE_URL || 'http://127.0.0.1:8080/api';
const frontendUrl = process.env.FRONTEND_URL || 'http://127.0.0.1:3000';
const skipBrowser = process.env.SKIP_BROWSER === '1';

const suffix = Date.now();
const manualAccountName = `Smoke Manual ${suffix}`;
const cryptoInstitutionName = `Smoke Bitso ${suffix}`;

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
    headers: cookieHeader() ? { cookie: cookieHeader() } : {},
  });
  assert(emptyUpload.status === 400, `empty upload returned ${emptyUpload.status}`);

  record('manual account and import flow', { accountId: account.id });
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
    await smokeManualAccountAndImport();
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
