# Kaspire Android 0.11.34 · build 106

- Browse shows directory offers without waiting for wallet holdings or all on-chain listing checks.
- Display twelve offers initially; Load more adds twelve. Search and price sorting use the full downloaded directory.
- Verify displayed offers progressively, two at a time. Own listing history is checked when its tab is opened instead of blocking Browse.
- Unchecked offers remain marked Checking listing. Purchase/cancel requires successful verification, and transaction preparation still obtains fresh live-cell proofs and native signing validation.
- Ignore verification results from older refreshes or after leaving the screen.
- Android 11+; existing signing lineage retained.

Public release: website download, signed in-app update manifest and WalletConnect installation fallback use this APK. Browser extension remains 0.4.8.

APK SHA-256: `731dacceec09c6ea70453cd422b05e33b53f0c9f3f2e14bcaf01764398aaacc8`.

Verification: no Flutter analyzer issues; 130 Flutter tests pass. New widget tests hold both name discovery and status proofs unresolved while checking that Browse renders, verify that search reaches offers outside the first page, and confirm only twelve listings are checked before Load more (24 afterwards).
