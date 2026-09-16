# Kaspire Android 0.11.33 · build 105

- Fix transient “Status unavailable” caused by marketplace request bursts hitting API rate limits.
- Pace verification requests across marketplace screens, with two request slots and starts spaced by 125 ms.
- Retry temporary 429/502/503/504 responses and transport failures with bounded backoff (four attempts maximum).
- Verify both listing cells using one fresh originating-transaction proof per pass. Completed UTXO proofs are never cached.
- Temporary verification outages no longer trigger additional history queries. Sold/cancelled status still requires accepted transaction evidence; native pre-signing checks remain unchanged.
- Server: retain the API limit of 20 requests/second per client, queue bounded bursts of 80, return 429 on overflow. Separate the marketplace directory limit (5 requests/second, burst 10). This also helps existing installations.
- Android 11+; existing signing lineage retained. Browser extension remains 0.4.8.

Website APK, signed update manifest and WalletConnect installation fallback are updated together.

Verification: Flutter analyzer reports no issues; all 128 Flutter tests pass, including retry bounds, concurrent read coalescing, no completed-proof cache, request concurrency and closed-reader handling.
