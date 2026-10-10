# Kaspire Android 0.11.50 — In-app dApp Browser and expanded token discovery

## Kaspire Browser

- Connect to approved dApps and review WalletConnect requests without leaving Kaspire.
- Include Kasvio, GothDAG, Kaspa Dev Tools, dot.k and KasCoven Vaults, with Kasvio first in the selection.
- Display each dApp with its logo and theme-specific controls.
- Restrict navigation to approved dApp origins and bind browser pairing requests to the selected origin.
- Refine browser layouts for HUB21 and Neptune.

## Dashboard and themes

- Add a compact two-row Layer 1 dashboard: Send, Receive, Vaults and Swap; Browser, Pair dApp, K-Agora and Settings.
- Keep Layer 2 actions separate from the Layer 1 dashboard.
- Add previews for upcoming vaults and KCC20 swaps.
- Center shortcut icons and labels, improve narrow-screen layouts and use consistent mixed-case labels without an uppercase setting.
- Replace the retired kcc20.info Toolbox link with Kasvio.

## Token and NFT reliability

- Expand KRON holdings discovery to include launchpad tokens before their bonding curve completes.
- Use Kasvio for available KRON market metadata while keeping balances and signing-cell checks tied to the KRON indexer and local contract validation.
- Improve NFT image delivery and listing-alert handling.

## Release compatibility

- Android version 0.11.50, build 166, package `space.kaspire.wallet`; Android 11 and newer.
- Preserve the existing Android signing lineage for normal upgrades, including recent internal test builds.
- Keep the signed update manifest and APK on the pinned Kaspire download host.
- Include the corresponding extension source changes for version 0.5.7.10, submitted separately to the Chrome Web Store.

## Verification

- APK SHA-256: `80aa410ad5581798140e5f6926a5d4b9ff44b284439109ae29c45d28d8e627f3`.
- Android 13+ signing certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`; Android 11–12 retain the legacy certificate through the existing signing lineage.
- Extension ZIP SHA-256: `b81bbbb17490c73035a5023327163dbda9afae3f6cb1f568660076daf5922cb5`.
- 266 Flutter tests and 93 Rust tests passed; Flutter analysis and extension TypeScript checks passed.
