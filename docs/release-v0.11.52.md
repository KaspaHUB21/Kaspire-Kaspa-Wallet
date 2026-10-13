# Kaspire Android 0.11.52 — KaspaCom Marketplace in K-Agora

## KaspaCom Marketplace

- Open KaspaCom Marketplace directly from the first, separately highlighted entry in K-Agora, using the official KaspaCom logo.
- Trade supported decentralized KRC721 NFT, KRC20 token and KNS name orders without leaving Kaspire.
- Keep KaspaCom orders, commissions and purchase history separate from Kaspire's own marketplaces.
- Search and filter collections, inspect traits and sort NFTs by price or rarity rank.
- Browse ranked collections and tokens in batches with Load more.
- Show NFT collection floor prices without unreliable holder counts.
- Show compact KRC20 order cards with token images, quantities and price per token; prefill listing unit prices from the current floor.
- Separate My listings, Purchases and Sales; show already-listed assets instead of offering a duplicate listing.
- Use consistent purchase-success screens and preserve signed transactions for recovery without trapping users behind cancelled orders.
- Simplify repeated marketplace confirmations while preserving local transaction reconstruction, approval binding and node checks.

## Nexus Offers

- Recognize active KaspaCom KRC721 PSKT listings alongside Kaspire NFT listings.
- Read ownership and listing status from Kaspire's read-only NFT indexer, with the existing official emergency fallback.
- Enrich listed NFTs with targeted KaspaCom price lookups only when required, using a shared 90-second cache, request deduplication, concurrency limits and an upstream request budget.
- Match prices to the exact on-chain listing transaction and seller; changed ownership or a cancelled/relisted NFT cannot reuse a previous listing's quote.
- Open the corresponding marketplace for purchase review and recognize KaspaCom relistings at an agreed offer price.

## Loading and browser refinements

- Load the selected asset promptly on Send Asset instead of waiting for all asset services.
- Load KRC20 and KNS marketplace holdings progressively, keeping independent services from blocking each other.
- Permit recovery-file downloads from the approved Vaults dApp inside Kaspire Browser while retaining restricted navigation and download handling.
- Refine Glacier glass rendering on narrow screens.

## Release compatibility

- Android 0.11.52, build 181; package `space.kaspire.wallet`; Android 11 and newer, ARM64 and ARMv7.
- Preserve the existing Android signing lineage for normal upgrades, including the recent internal test builds.
- Keep the signed update manifest and APK downloads on the pinned Kaspire host.
- The browser extension remains on its separately published version; this release does not replace its Chrome Web Store package.
- 375 mobile tests and 109 Rust tests passed; Flutter analysis and Nexus TypeScript checks passed. 25 marketplace/Nexus protocol tests passed.
- APK SHA-256: `732d2d482a09e5e4615471d9be53b61c011d6c9d93d9277d1d45f70e780b4956`.
- Signing certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`; existing signing lineage retained.
