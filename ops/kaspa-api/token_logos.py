"""Persistent, stale-on-error KRC20 raster cache. No arbitrary URL proxy."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import os
import re
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_IMAGE = 2 * 1024 * 1024
ORIGIN = "https://krc20data.s3.us-east-1.amazonaws.com"
_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="token-logo")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def raster_type(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        width, height = struct.unpack(">II", data[16:24])
        if 0 < width <= 8192 and 0 < height <= 8192:
            return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        width, height = struct.unpack("<HH", data[6:10])
        if 0 < width <= 8192 and 0 < height <= 8192:
            return "image/gif"
    raise ValueError("Not a supported bounded raster image")


class TokenLogoCache:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.locks = [threading.Lock() for _ in range(64)]
        self.negative = {}
        self.refreshing = set()
        self.guard = threading.Lock()
        self.download_slots = threading.BoundedSemaphore(2)

    @staticmethod
    def _read_url(url, maximum):
        opener = urllib.request.build_opener(NoRedirect())
        request = urllib.request.Request(url, headers={"user-agent": "Kaspire-Token-Logo/1"})
        with opener.open(request, timeout=4) as response:
            data = response.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("Logo response too large")
        return data

    def _download(self, symbol):
        direct = f"{ORIGIN}/verified/{symbol}-logo.png"
        try:
            data = self._read_url(direct, MAX_IMAGE)
        except (OSError, ValueError):
            metadata = json.loads(self._read_url(
                f"https://kaspatoken.kaslab.space/api/token/krc20-{symbol}", 256 * 1024))
            if not isinstance(metadata, dict) or not isinstance(metadata.get("data"), dict):
                raise ValueError("Invalid logo metadata")
            url = metadata.get("data", {}).get("image_url", "")
            parsed = urllib.parse.urlsplit(url)
            if (parsed.scheme != "https" or parsed.netloc != urllib.parse.urlsplit(ORIGIN).netloc
                    or parsed.query or parsed.fragment or not re.fullmatch(
                        r"/(?:verified|unverified)/[a-zA-Z0-9_.-]{1,120}\.(?:png|jpg|jpeg|webp|gif)", parsed.path)):
                raise ValueError("Logo origin is not allowed")
            data = self._read_url(url, MAX_IMAGE)
        raster_type(data)
        return data

    def _refresh(self, symbol, path):
        try:
            with self.download_slots, self.locks[hash(symbol) % len(self.locks)]:
                data = self._download(symbol)
                self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                # Never evict an existing logo because its upstream is down.
                if sum(p.stat().st_size for p in self.directory.glob("*.img")) > 128 * 1024 * 1024:
                    return data
                temporary = path.with_suffix(f".tmp-{threading.get_ident()}")
                try:
                    temporary.write_bytes(data)
                    temporary.replace(path)
                finally:
                    temporary.unlink(missing_ok=True)
                return data
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            with self.guard:
                if len(self.negative) >= 512:
                    self.negative.clear()
                self.negative[symbol] = time.monotonic() + 300
            return None
        finally:
            with self.guard:
                self.refreshing.discard(symbol)

    def response(self, symbol):
        if not re.fullmatch(r"[a-z0-9_-]{1,32}", symbol):
            return 400, {"content-type": "application/json"}, b'{"detail":"Invalid token ticker"}'
        path = self.directory / f"{symbol}.img"
        try:
            with path.open("rb") as stream:
                data = stream.read(MAX_IMAGE + 1)
            if len(data) > MAX_IMAGE:
                raise ValueError("Cached logo too large")
            mime = raster_type(data)
            if time.time() - path.stat().st_mtime > 86400:
                with self.guard:
                    if symbol not in self.refreshing and self.negative.get(symbol, 0) < time.monotonic():
                        self.refreshing.add(symbol)
                        _executor.submit(self._refresh, symbol, path)
            return 200, {"content-type": mime}, data
        except (OSError, ValueError):
            pass
        with self.guard:
            negative = self.negative.get(symbol, 0) > time.monotonic()
            busy = symbol in self.refreshing
            if not negative and not busy:
                self.refreshing.add(symbol)
        if busy:
            return 503, {"retry-after": "3"}, b'{"detail":"Logo is being cached"}'
        data = None if negative else self._refresh(symbol, path)
        if data is None:
            return 404, {"content-type": "application/json"}, b'{"detail":"No cached logo available"}'
        return 200, {"content-type": raster_type(data)}, data


cache = TokenLogoCache(os.environ.get("KASPIRE_TOKEN_LOGO_CACHE", "/var/lib/kaspire-token-logos"))
