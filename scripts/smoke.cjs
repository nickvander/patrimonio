#!/usr/bin/env node

const { execFileSync } = require('node:child_process');

const apiBase = process.env.API_BASE_URL || 'http://127.0.0.1:8080/api';
const frontendUrl = process.env.FRONTEND_URL || 'http://127.0.0.1:3000';
const skipBrowser = process.env.SKIP_BROWSER === '1';

const suffix = Date.now();
const manualAccountName = `Smoke Manual ${suffix}`;
const cryptoInstitutionName = `Smoke Bitso ${suffix}`;

const results = [];

function record(name, detail) {
  results.push({ name, ...detail });
  console.log(`ok - ${name}`);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function request(path, options = {}) {
  const response = await fetch(`${apiBase}${path}`, options);
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

  const emptyUpload = await fetch(`${apiBase}/imports/upload`, { method: 'POST', body: new FormData() });
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

  const coinbase = await fetch(`${apiBase}/auth/coinbase`, { redirect: 'manual' });
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
      const page = await browser.newPage({ viewport, isMobile });
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
      assert(apiResponses.every((item) => item.status === 200), `${name} had non-200 API responses`);
      await page.close();
    }
  } finally {
    await browser.close();
  }

  record('browser frontend boot', { frontendUrl });
}

(async () => {
  try {
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
