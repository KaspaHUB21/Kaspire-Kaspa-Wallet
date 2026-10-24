# Persistent KRC20 logos

Public route: `GET /api/token-logos/krc20/{lowercase-ticker}`. The existing
`/api/` nginx proxy forwards this route; no new public upstream is needed.

Install `gateway.py` and `token_logos.py` together in
`/usr/local/lib/kaspire-kaspa-gateway/`. For an existing service, install
`kaspa-gateway-logo-cache.conf` as
`/etc/systemd/system/kaspa-gateway.service.d/token-logos.conf`, run
`systemctl daemon-reload`, then restart `kaspa-gateway.service`.
The base unit also declares the same state directory for fresh installations.
Do not replace existing credential/environment drop-ins.

Systemd provides `/var/lib/kaspire-token-logos` as persistent service-owned
storage, including when DynamicUser is enabled. `KASPIRE_TOKEN_LOGO_CACHE`
can override the directory if an alternative writable state path is provided.

Only fixed trusted metadata and raster-image origins are requested. Arbitrary
URLs, redirects, SVG/HTML, oversized responses and invalid ticker paths are
rejected. Images are capped at 2 MiB, origin work has two concurrent slots,
and disk storage is bounded at approximately 128 MiB. No cached logo is evicted
because its source is unavailable. Stale images are served immediately while
refreshing in the background; failed misses back off for five minutes.

Successful logo responses are browser-cacheable for one day. Account and
transaction responses retain their existing no-store policy. A token that has
never been cached still needs an available original image; HTTP 404 is not a
claim that the token or its wallet balance does not exist.

Tests: `python3 -m unittest discover -s ops/kaspa-api -p 'test_*.py'`.
