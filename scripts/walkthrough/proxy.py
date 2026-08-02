#!/usr/bin/env python3
"""Same-origin dev proxy for headless UI walkthroughs.

The Flutter web app derives its API base from window.location + "/api"
(frontend/lib/.../api_platform_web.dart), so a served web build only works when
the static bundle and the backend share ONE origin. This proxy provides that
origin for the walkthrough rig:

  * serves the built web bundle (frontend/build/web) as static files, with an
    SPA fallback to index.html;
  * reverse-proxies everything under /api to the backend (default
    127.0.0.1:8080), forwarding ALL request and response headers verbatim
    (minus hop-by-hop). That matters for three rig-artifact bug classes we've
    hit before:
      - Cookie must reach the backend (session auth);
      - X-Requested-With must reach the backend (CSRF guard on writes —
        dropping it makes every in-app save silently 403);
      - X-Total-Count must come BACK (transactions list totals — dropping it
        makes the app fall back to climbing loaded-count denominators);
  * passes WebSocket upgrades through for /api/realtime/ws. The earlier
    http.server+urllib incarnation could not do this, so the app's realtime
    socket failed 400 on every page. Here an Upgrade: websocket request is
    tunneled as a raw byte pipe (after the 101 handshake WS is just bytes), so
    the BACKEND decides the handshake outcome (101, or 401/403 for bad auth).

Pure stdlib (asyncio streams) — the dev VM has no aiohttp/websockets and no
pip. HTTP/1.1 keep-alive is deliberately not implemented: every non-WS exchange
is Connection: close on both legs. Browsers just reopen connections; for a dev
rig, simple and correct beats fast.

Usage:
    python3 scripts/walkthrough/proxy.py [--port 3300] [--backend 127.0.0.1:8080] \
        [--web-root frontend/build/web]
    # env overrides: WALKTHROUGH_PORT, WALKTHROUGH_BACKEND, WALKTHROUGH_WEB_ROOT

DEV-ONLY tooling. Binds 127.0.0.1. Never point it at prod.
"""

from __future__ import annotations

import argparse
import asyncio
import mimetypes
import os
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WEB_ROOT = REPO_ROOT / "frontend" / "build" / "web"
DEFAULT_PORT = 3300
DEFAULT_BACKEND = "127.0.0.1:8080"

# Hop-by-hop headers stripped on the non-WebSocket proxy path (we speak
# Connection: close to the backend). On the WS path Connection/Upgrade must
# survive, so only Host is rewritten there.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",  # request side only; we tunnel bodies raw anyway
    "upgrade",
}

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/octet-stream", ".symbols")


def parse_head(head: bytes) -> tuple[str, str, list[tuple[str, str]]]:
    """Split a raw request head into (method, target, [(name, value), ...])."""
    lines = head.decode("latin-1").split("\r\n")
    method, target, _version = lines[0].split(" ", 2)
    headers: list[tuple[str, str]] = []
    for line in lines[1:]:
        if not line:
            continue
        name, _, value = line.partition(":")
        headers.append((name.strip(), value.strip()))
    return method, target, headers


def header(headers: list[tuple[str, str]], name: str) -> str:
    for k, v in headers:
        if k.lower() == name.lower():
            return v
    return ""


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Copy bytes until EOF, then half-close the write side."""
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except (OSError, RuntimeError):
            pass


async def proxy_api(
    client_r: asyncio.StreamReader,
    client_w: asyncio.StreamWriter,
    method: str,
    target: str,
    headers: list[tuple[str, str]],
    backend_host: str,
    backend_port: int,
) -> None:
    """Forward one /api request. WebSocket upgrades become a raw tunnel; plain
    requests are Connection: close on both legs and piped until EOF."""
    is_ws = (
        "websocket" in header(headers, "upgrade").lower()
        or "upgrade" in header(headers, "connection").lower()
    )
    try:
        backend_r, backend_w = await asyncio.open_connection(backend_host, backend_port)
    except OSError:
        client_w.write(
            b"HTTP/1.1 502 Bad Gateway\r\n"
            b"Content-Type: text/plain\r\nConnection: close\r\n\r\n"
            b"walkthrough proxy: backend unreachable\n"
        )
        await client_w.drain()
        return

    out = [f"{method} {target} HTTP/1.1"]
    for name, value in headers:
        low = name.lower()
        if low == "host":
            continue
        if not is_ws and low in HOP_BY_HOP:
            continue
        out.append(f"{name}: {value}")
    out.append(f"Host: {backend_host}:{backend_port}")
    if not is_ws:
        out.append("Connection: close")
    backend_w.write(("\r\n".join(out) + "\r\n\r\n").encode("latin-1"))
    await backend_w.drain()

    # From here both directions are raw pipes. Covers request bodies of any
    # framing, streamed responses, and post-101 WebSocket frames alike. The
    # backend closing its side (Connection: close, or WS teardown) ends the
    # exchange.
    upstream = asyncio.create_task(pipe(client_r, backend_w))
    downstream = asyncio.create_task(pipe(backend_r, client_w))
    try:
        await downstream
    finally:
        upstream.cancel()
        backend_w.close()
        try:
            await backend_w.wait_closed()
        except (ConnectionError, OSError):
            pass


def resolve_static(web_root: Path, raw_path: str) -> Path:
    """Map a URL path onto the web bundle, with traversal protection and an
    SPA fallback to index.html for unknown extension-less routes."""
    rel = unquote(urlsplit(raw_path).path).lstrip("/")
    candidate = (web_root / rel).resolve() if rel else web_root / "index.html"
    if not str(candidate).startswith(str(web_root.resolve())):
        return web_root / "index.html"
    if candidate.is_dir():
        candidate = candidate / "index.html"
    if not candidate.is_file():
        candidate = web_root / "index.html"
    return candidate


async def serve_static(
    client_w: asyncio.StreamWriter, method: str, target: str, web_root: Path
) -> None:
    path = resolve_static(web_root, target)
    if not path.is_file():
        client_w.write(
            b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
            b"Connection: close\r\n\r\nwalkthrough proxy: web bundle not built?\n"
        )
        await client_w.drain()
        return
    body = path.read_bytes()
    ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    head = (
        f"HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\n"
        f"Content-Length: {len(body)}\r\nCache-Control: no-cache\r\n"
        f"Connection: close\r\n\r\n"
    ).encode("latin-1")
    client_w.write(head if method == "HEAD" else head + body)
    await client_w.drain()


def make_handler(backend_host: str, backend_port: int, web_root: Path):
    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = await reader.readuntil(b"\r\n\r\n")
            method, target, headers = parse_head(head)
            path = urlsplit(target).path
            if path == "/api" or path.startswith("/api/"):
                await proxy_api(
                    reader, writer, method, target, headers, backend_host, backend_port
                )
            else:
                await serve_static(writer, method, target, web_root)
        except (
            asyncio.IncompleteReadError,
            asyncio.LimitOverrunError,
            ConnectionError,
            ValueError,
        ):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    return handle


async def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("WALKTHROUGH_PORT", DEFAULT_PORT)),
    )
    ap.add_argument(
        "--backend",
        default=os.environ.get("WALKTHROUGH_BACKEND", DEFAULT_BACKEND),
        help="host:port of the running patrimonio backend",
    )
    ap.add_argument(
        "--web-root",
        type=Path,
        default=Path(os.environ.get("WALKTHROUGH_WEB_ROOT", DEFAULT_WEB_ROOT)),
        help="built Flutter web bundle (frontend/build/web)",
    )
    args = ap.parse_args()

    if not (args.web_root / "index.html").is_file():
        sys.exit(
            f"proxy.py: no index.html under {args.web_root} — "
            "run `flutter build web` first (see scripts/walkthrough/README.md)"
        )
    backend_host, _, port_s = args.backend.partition(":")
    backend_port = int(port_s or "8080")

    server = await asyncio.start_server(
        make_handler(backend_host, backend_port, args.web_root),
        "127.0.0.1",
        args.port,
    )
    print(
        f"walkthrough proxy: http://127.0.0.1:{args.port} "
        f"-> static {args.web_root}, /api -> {backend_host}:{backend_port} "
        f"(incl. WS upgrade passthrough)",
        flush=True,
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
