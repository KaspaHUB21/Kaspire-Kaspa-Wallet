# Kaspire Android 0.11.51 — KRON DEX and KCC20 Last Call

## KRON DEX swaps

- Open KRON DEX directly from Swap on the Layer 1 dashboard.
- Buy and sell KRON tokens on mainnet, including supported launchpad bonding curves and graduated pools.
- Review token and market covenant IDs, token amounts, minimum receive, deposits, protocol fees and network fees before approving a trade.
- Independently check covenant outputs on the local node and execute transaction inputs locally before broadcast.
- Preserve signed transactions for recovery; retries reuse the same transaction.
- Attribute trades to Kaspire's KRON partner tag without adding a separate Kaspire trading fee.

## New standard KCC20 tokens

- Discover KCC20 Last Call reference tokens through Kasvio's public KCC20 API.
- Show exact decimal balances, covenant IDs and verified token images.
- Support transfers for the pinned reference profile with owner scheme 00 and up to three token input cells.
- Rebuild the covenant program and transfer locally, bind the reviewed transaction to its signatures and validate every input in the local script engine.
- Fix Android JSON number normalization incorrectly rejecting otherwise identical KCC20 signing requests.
- Keep standard KCC20, KRON and legacy token sources independent so one source's outage does not hide another's holdings.

## Activity and browser refinements

- Record KRON and KaspaRocket swap token quantities alongside native KAS activity.
- Improve local activity recording for NFT and dot.k marketplace operations, including recovered transactions.
- Keep different assets and wallet addresses distinct when merging transaction history.
- Read new standard KCC20 owner-net token activity, including tokens no longer held; historical coverage depends on complete indexer data.
- Hide the in-app Browser connection hint after a confirmed connection to the selected dApp and show it again after disconnection.

## Release compatibility and verification

- Android 0.11.51, build 172; package `space.kaspire.wallet`; Android 11 and newer, ARM64 and ARMv7.
- Preserve the existing signing lineage for normal upgrades, including internal builds 167–171.
- Keep the signed update manifest and APK on the pinned Kaspire download host.
- 287 mobile tests and 96 Rust tests passed; Flutter analysis passed.
- The browser extension remains on its separately published version; this release does not add these Android features to the extension.
- APK SHA-256: `4a089b01b6793c8ae705116b3136d9ddbb126359db923cefc739b1c80fa05bea`.
- Signing certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`; existing signing lineage retained.
