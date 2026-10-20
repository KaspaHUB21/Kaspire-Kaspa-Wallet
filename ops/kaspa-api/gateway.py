#!/usr/bin/env python3
"""Kaspire's local-first Kaspa REST gateway."""

from __future__ import annotations

import base64
import json
import logging
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCAL = "http://127.0.0.1:8000"
PUBLIC = "https://api.kaspa.org"
HISTORY_SUFFIX = "/full-transactions"
LOCAL_NODE_PREFIX = "/local-node"
KRC20_FALLBACK_PREFIX = "/krc20-fallback"
KRC20_FALLBACK_BASE = os.environ.get(
    "KRC20_FALLBACK_BASE", "https://kcc.kaslab.space/api/krc20"
).rstrip("/")
KRC20_FALLBACK_USER = os.environ.get("KRC20_FALLBACK_USER", "")
KRC20_FALLBACK_PASSWORD = os.environ.get("KRC20_FALLBACK_PASSWORD", "")
MAX_BODY = 16 * 1024 * 1024
MAX_HISTORY_FETCH = 100
LOG = logging.getLogger("kaspa-gateway")

_health_lock = threading.Lock()
_health_checked_at = 0.0
_local_healthy = False
_history_healthy = False


def _request(
    base: str,
    method: str,
    path: str,
    body: bytes | None = None,
    content_type: str | None = None,
    timeout: float = 15,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    headers = {
        "accept": "application/json",
        "user-agent": "kaspire-kaspa-gateway/1",
    }
    if content_type:
        headers["content-type"] = content_type
    if extra_headers:
        headers.update(extra_headers)
    request = urllib.request.Request(
        base + path,
        data=body,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, dict(response.headers.items()), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers.items()), error.read()


def _is_local_healthy() -> bool:
    global _health_checked_at, _local_healthy, _history_healthy
    now = time.monotonic()
    with _health_lock:
        if now - _health_checked_at < 5:
            return _local_healthy
        try:
            status, _, body = _request(
                LOCAL, "GET", "/info/health", timeout=3
            )
            payload = json.loads(body)
            servers = payload.get("kaspadServers", [])
            _local_healthy = (
                status == 200
                and bool(servers)
                and all(
                    server.get("isSynced") and server.get("isUtxoIndexed")
                    for server in servers
                )
            )
            _history_healthy = (
                _local_healthy
                and payload.get("database", {}).get("isSynced") is True
            )
        except (OSError, ValueError, TypeError):
            _local_healthy = False
            _history_healthy = False
        _health_checked_at = now
        return _local_healthy


def _is_history_healthy() -> bool:
    _is_local_healthy()
    return _history_healthy


def _rows(payload: object) -> list[dict]:
    if isinstance(payload, list):
        return [row for row in payload if isinstance(row, dict)]
    if isinstance(payload, dict) and isinstance(payload.get("transactions"), list):
        return [
            row
            for row in payload["transactions"]
            if isinstance(row, dict)
        ]
    return []


def _transaction_key(row: dict) -> str:
    return str(row.get("transaction_id") or row.get("id") or "")


def _transaction_time(row: dict) -> int:
    value = row.get("block_time") or row.get("accepting_block_time") or 0
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _history_path(path: str) -> tuple[str, int, int]:
    parsed = urllib.parse.urlsplit(path)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    try:
        requested_limit = max(1, min(100, int(query.get("limit", ["20"])[0])))
        requested_offset = max(0, int(query.get("offset", ["0"])[0]))
    except ValueError:
        requested_limit, requested_offset = 20, 0
    query["limit"] = [str(min(MAX_HISTORY_FETCH, requested_offset + requested_limit))]
    query["offset"] = ["0"]
    fetch_path = urllib.parse.urlunsplit(
        ("", "", parsed.path, urllib.parse.urlencode(query, doseq=True), "")
    )
    return fetch_path, requested_offset, requested_limit


def _merged_history(path: str) -> tuple[int, dict[str, str], bytes]:
    fetch_path, offset, limit = _history_path(path)
    results: list[tuple[int, dict[str, str], bytes]] = []
    local_synced = _is_history_healthy()
    local_valid = public_valid = False
    for base in (LOCAL, PUBLIC):
        try:
            response = _request(base, "GET", fetch_path, timeout=15)
            results.append(response)
            if base == LOCAL:
                local_valid = _validated_history(response) is not None
            else:
                public_valid = _validated_history(response) is not None
            # HD gap discovery needs only existence, not a merged feed.
            # A synced own indexer is authoritative, including a valid empty
            # list. Never fan every unused address out to the public API.
            if base == LOCAL and local_synced and offset == 0 and limit == 1:
                rows = _validated_history(response)
                if rows is not None:
                    return _history_response(rows[:1])
        except OSError:
            LOG.warning("history backend failed: %s", base)

    merged: dict[str, dict] = {}
    anonymous = 0
    for response in results:
        rows = _validated_history(response)
        if rows is None:
            continue
        for row in rows:
            key = _transaction_key(row)
            if not key:
                anonymous += 1
                key = f"anonymous-{anonymous}-{_transaction_time(row)}"
            existing = merged.get(key)
            if existing is None or len(row) > len(existing):
                merged[key] = row

    if not merged:
        # A fallback error must not overwrite a successful primary response.
        # But an unsynced/invalid primary plus a failed fallback is not "empty".
        if (local_synced and local_valid) or public_valid:
            return _history_response([])
        for response in reversed(results):
            if response[0] >= 400:
                return response
        raise OSError("No valid account history source is available")
    rows = sorted(merged.values(), key=_transaction_time, reverse=True)
    return _history_response(rows[offset : offset + limit])


def _validated_history(response: tuple[int, dict[str, str], bytes]) -> list[dict] | None:
    status, _, body = response
    if status != 200:
        return None
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        return None
    rows = payload.get("transactions") if isinstance(payload, dict) else payload
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        return None
    return rows


def _history_response(rows: list[dict]) -> tuple[int, dict[str, str], bytes]:
    return 200, {"content-type": "application/json"}, json.dumps(rows, separators=(",", ":")).encode()


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "KaspireKaspaGateway/1"

    def do_GET(self) -> None:
        request_path = urllib.parse.urlsplit(self.path).path
        if request_path == KRC20_FALLBACK_PREFIX or request_path.startswith(
            KRC20_FALLBACK_PREFIX + "/"
        ):
            self._proxy_krc20_fallback()
            return
        if request_path.startswith(LOCAL_NODE_PREFIX + "/"):
            self._proxy_local_node_read()
            return
        if HISTORY_SUFFIX in urllib.parse.urlsplit(self.path).path:
            try:
                self._respond(*_merged_history(self.path))
            except OSError as error:
                self._error(502, f"Kaspa history backends unavailable: {error}")
            return
        self._proxy_read()

    def _proxy_krc20_fallback(self) -> None:
        if not KRC20_FALLBACK_USER or not KRC20_FALLBACK_PASSWORD:
            self._error(503, "KRC20 fallback is not configured")
            return
        parsed = urllib.parse.urlsplit(self.path)
        relative_path = parsed.path[len(KRC20_FALLBACK_PREFIX) :] or "/"
        if not (relative_path == "/oplist" or (
            relative_path.startswith("/address/")
            and relative_path.endswith("/tokenlist")
        )):
            self._error(404, "Unsupported KRC20 fallback route")
            return
        upstream_path = urllib.parse.urlunsplit(
            ("", "", relative_path, parsed.query, "")
        )
        credentials = base64.b64encode(
            f"{KRC20_FALLBACK_USER}:{KRC20_FALLBACK_PASSWORD}".encode()
        ).decode("ascii")
        try:
            response = _request(
                KRC20_FALLBACK_BASE,
                "GET",
                upstream_path,
                timeout=15,
                extra_headers={"authorization": f"Basic {credentials}"},
            )
            self._respond(*response)
        except OSError as error:
            self._error(502, f"KRC20 fallback unavailable: {error}")

    def _proxy_local_node_read(self) -> None:
        if not _is_local_healthy():
            self._error(503, "Kaspire local Kaspa node is not synced and UTXO-indexed")
            return
        parsed = urllib.parse.urlsplit(self.path)
        if HISTORY_SUFFIX in parsed.path and not _is_history_healthy():
            self._error(503, "Kaspire account history indexer is not synced")
            return
        upstream_path = urllib.parse.urlunsplit(
            ("", "", parsed.path[len(LOCAL_NODE_PREFIX) :], parsed.query, "")
        )
        try:
            response = _request(LOCAL, "GET", upstream_path, timeout=15)
            self._respond(*response)
        except OSError as error:
            self._error(502, f"Kaspire local Kaspa node unavailable: {error}")

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        if length < 0 or length > MAX_BODY:
            self._error(413, "Request body too large")
            return
        body = self.rfile.read(length)
        backend = LOCAL if _is_local_healthy() else PUBLIC
        try:
            response = _request(
                backend,
                "POST",
                self.path,
                body,
                self.headers.get("content-type", "application/json"),
                timeout=25,
            )
            self._respond(*response)
        except OSError as error:
            self._error(502, f"Kaspa transaction backend unavailable: {error}")

    def _proxy_read(self) -> None:
        preferred = LOCAL if _is_local_healthy() else PUBLIC
        fallback = PUBLIC if preferred == LOCAL else LOCAL
        try:
            response = _request(preferred, "GET", self.path, timeout=15)
            if response[0] >= 500:
                response = _request(fallback, "GET", self.path, timeout=15)
            self._respond(*response)
        except OSError:
            try:
                self._respond(*_request(fallback, "GET", self.path, timeout=15))
            except OSError as error:
                self._error(502, f"Kaspa REST backends unavailable: {error}")

    def _respond(
        self, status: int, headers: dict[str, str], body: bytes
    ) -> None:
        self.send_response(status)
        self.send_header("content-type", headers.get("content-type", "application/json"))
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.send_header("x-content-type-options", "nosniff")
        for name, value in headers.items():
            if name.lower() == "retry-after" and status in (429, 503):
                self.send_header("retry-after", value)
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str) -> None:
        payload = json.dumps({"detail": message}, separators=(",", ":")).encode()
        self._respond(status, {"content-type": "application/json"}, payload)

    def log_message(self, fmt: str, *args: object) -> None:
        # Request paths can contain wallet addresses. Nginx access logging is
        # disabled for /api and the gateway must not reintroduce that leak.
        return


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    server = ThreadingHTTPServer(("127.0.0.1", 8010), GatewayHandler)
    LOG.info("listening on http://127.0.0.1:8010")
    server.serve_forever()


if __name__ == "__main__":
    main()
