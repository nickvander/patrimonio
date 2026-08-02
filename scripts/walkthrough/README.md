# Headless UI walkthrough rig

Drive the **real, running** Patrimonio web app on the GUI-less dev VM: serve the
built Flutter bundle + backend on one origin, skip the login canvas with a
minted session cookie, and screenshot/click it with headless Playwright
Chromium. Use it to verify UI changes in the actual app (not just widget
tests), collect screenshot evidence, and run e2e smoke passes.

The agent-facing checklist and ground rules live in
`.agent/skills/ui-walkthrough/SKILL.md` — read that first. This file is the
mechanical runbook.

**DEV-ONLY.** Everything here talks to the local dev Postgres/backend. Never
point any of it at prod.

## Components

| File | What it does |
| --- | --- |
| `proxy.py` | Same-origin dev server: static `frontend/build/web` + reverse proxy `/api` → backend, **including WebSocket passthrough** for `/api/realtime/ws`. Stdlib-only. |
| `mint_session.sh` | Inserts a session row into the dev DB (same token recipe as `sessions.rs`) and prints the `patrimonio_session` cookie value. |

## Prerequisites

1. **Services up** — Postgres :5442 and Redis :6380 (start commands in
   `.agent/skills/dev-workflow/SKILL.md`).
2. **Backend built and running** on :8080:
   ```bash
   cd ~/dev/patrimonio/backend && source ~/.cargo/env && cargo build
   pkill -x patrimonio 2>/dev/null; RUST_LOG=warn ./target/debug/patrimonio &
   curl -s http://127.0.0.1:8080/api/health
   ```
3. **Web bundle built** at `frontend/build/web`:
   ```bash
   cd ~/dev/patrimonio/frontend && ~/flutter/bin/flutter build web --profile
   ```
   Takes ~50 s and prints nothing until the end. If the app later hangs at
   "Loading engine…" with an opaque `Uncaught Error`, the
   `.dart_tool/flutter_build` cache is stale (plugin registrant missing a
   newly-added plugin) — `flutter clean` and rebuild.

## Run sequence

```bash
cd ~/dev/patrimonio

# 1. Same-origin proxy on :3300 (backend :8080). Background it.
python3 scripts/walkthrough/proxy.py --port 3300 --backend 127.0.0.1:8080 &

# 2. Mint a cookie for the QA account (claude_dev = the data-rich account).
COOKIE=$(scripts/walkthrough/mint_session.sh claude_dev "2 hours")

# 3. Sanity: authenticated API call through the proxy.
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Cookie: patrimonio_session=$COOKIE" -H 'X-Requested-With: rig' \
  http://127.0.0.1:3300/api/auth/me        # expect 200
```

## Pointing Playwright at it

Playwright Chromium is pre-downloaded on the VM but needs user-space GUI libs:

```bash
source ~/.local/bin/chromium-env.sh   # sets LD_LIBRARY_PATH + PW_CHROMIUM
# Python venv (no system pip): uv venv <scratch>/pwenv && \
#   uv pip install --python <scratch>/pwenv/bin/python playwright
# (or reuse ~/dev/strongbox/frontend/node_modules/playwright for JS)
```

```python
browser = playwright.chromium.launch(
    executable_path=os.environ["PW_CHROMIUM"],
    args=["--no-sandbox", "--enable-unsafe-swiftshader", "--use-gl=swiftshader"],
)
ctx = browser.new_context(viewport={"width": 1440, "height": 900})
ctx.add_cookies([{
    "name": "patrimonio_session", "value": COOKIE,
    "url": "http://127.0.0.1:3300",
}])
page = ctx.new_page()
page.goto("http://127.0.0.1:3300/")   # auth_gate boots straight to the dashboard
```

### Activating semantics (required before any a11y/label probing)

Flutter web ships with the semantics tree **OFF**; until it is switched on
there are **no** `flt-semantics` nodes to query, and a probe that skips this
step concludes the app is an empty canvas. The switch is a hidden
`flt-semantics-placeholder` element that sits off-viewport — Playwright's
`.click()` can't reach it, so click it from JS:

```python
page.eval_on_selector("flt-semantics-placeholder", "el => el.click()")
page.wait_for_timeout(1000)   # semantics tree builds asynchronously
```

After that:
- Labels live in `flt-semantics` **textContent** (aria-label is rare). Match
  text, pick the **shortest** matching node (innermost), click it with
  `force=True`.
- Flutter virtualizes lists: off-screen rows are absent from semantics until
  wheel-scrolled into view.
- Login forms (if you ever need them) are real `input`/`textarea` nodes; typing
  into canvas search fields drops characters below ~150 ms/char.
- Some widgets never appear in semantics (allocation bands, some filter chips)
  — screenshot, Read the PNG, click by pixel coordinates.
- Phone viewport (390×844): the bottom nav bar does not match reliably by text;
  click fixed coords — y=805, x: Home 39 / Invest 117 / Activity 195 / Cash 273
  / More 351.

## Teardown

```bash
# Delete the minted session (mint_session.sh printed the exact command on stderr)
psql "postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio" \
  -c "DELETE FROM user_sessions WHERE id = '<session-id>'"
kill %1 2>/dev/null || pkill -f "[w]alkthrough/proxy.py"   # the proxy
pkill -x patrimonio                                        # backend, if you started it
```

`pkill -f proxy.py` without the `[w]` bracket trick can kill the wrapping shell
that launched it (its own cmdline contains the pattern).

## Known limitations

- **No HTTP keep-alive**: the proxy answers every non-WebSocket request with
  `Connection: close`. Chromium reopens sockets transparently; page loads are
  slightly chattier than prod nginx. Irrelevant for walkthroughs.
- **No TLS, binds 127.0.0.1 only** — by design; this is a loopback dev rig.
- **WS passthrough is a dumb tunnel**: after forwarding the upgrade request the
  proxy pipes bytes both ways and lets the *backend* accept (101) or reject
  (401/403) the handshake. It does not parse WS frames, so it cannot inject or
  assert on individual realtime messages — use it to verify the socket
  connects and the app's realtime features work, not for frame-level tests.
- **Static serving reads whole files into memory** per request — fine for the
  ~30 MB bundle, not a general-purpose file server.
- **`claude_dev` is the QA account; never drive the `nick` account** (the
  human's real dev data). Password reset for claude_dev, seeded QA fixtures,
  and multi-agent concurrency notes are in the ui-walkthrough skill.
