# Kaspire Android 0.11.97 — KasForge Mainnet and new browser dApps

Public Android release, build 242. Cumulative changes since Android 0.11.94
(build 239), including the separate 0.11.95 and 0.11.96 KasForge builds.
Requires Android 11 or later; includes ARM64 and ARMv7.

## KasForge Mainnet swaps

- KasForge is now available at the end of Mainnet Swap: KaspaRocket, Kasseal,
  Braid, KForge, KRON, then KasForge.
- The familiar themed flow is retained: token search and images, DEX/activity
  tabs, KAS-budget buys, whole-token sells with percentage shortcuts, transaction
  review, automatic order-status checks, trade details and recovery controls.
- Mainnet KasForge balances, names and images participate in progressive asset
  discovery. Unavailable indexer results are not treated as zero balances.
- Mainnet uses the official `/api/v1` trading API and `/api/kaspa/forge` public
  data. Testnet-10 remains separate at `kaspa.testnet.pumpforge.tech`, with
  separate saved-order journals and network-bound requests.
- Mainnet order signing checks contract version 3.8 and the locally rebuilt
  buy-v5/sell-v4 templates, sender, outputs, token conservation, fees and live
  node state. Signed transactions are checked by the local script engine.
  Network changes reject stale results rather than mixing chains.

## KasForge sell and reserve corrections

- Fixes valid sells rejected as “token output changes owner, policy or deposit”
  when historical token cells carry different KAS reserves. Exact order reserves
  are checked against independently verified input values, not a fixed amount
  inferred only from the contract version.
- Correctly distinguishes wallet-owned token merge outputs from final
  order-owned outputs during multi-step sells.
- Review now shows the exact refundable token reserve and order reserve.
  Ordinary wallet funding remains bounded; provider-supplied reserve amounts
  cannot authorize arbitrary extra spending.
- Unsigned preparation failures show a readable message rather than raw
  PlatformException/JNI wrappers. Saved signed orders and same-byte recovery
  remain preserved when confirmation is uncertain.

## Kaspire Browser

Adds KasForge, KasForge Vaults and ANTX Universe with locally bundled official
icons. Updated order:

1. Kasvio
2. Kasseal
3. GothDAG
4. Braid
5. dot.k
6. Kaspa News
7. Kaspa Dev Tools
8. KasForge — https://kaspa.pumpforge.tech/
9. KasForge Vaults — https://vault.pumpforge.tech/
10. Jeetslab
11. ANTX Universe — https://universe.antx.world/
12. KasCoven Vaults

Navigation remains restricted to exact approved HTTPS origins. Existing
WalletConnect approvals, the read-only news entry and KasCoven recovery-file
handling are unchanged. Adding a browser entry does not grant arbitrary
download, filesystem or signing permissions.

## Installation and scope

Both Android update choices are supported: download the APK from the official
website, or download the matching GitHub release inside Kaspire before opening
Android's installer. The signed update manifest, APK checksum, package identity,
version and existing signing certificate are verified. Android still requires
the user's installation confirmation.

This release updates Android only. Extension 0.5.27, Chrome Web Store status,
iOS PWA and Windows update channels are unchanged. KasForge generic token
transfers are not newly enabled by this release. Confidential partner contract
kits are not distributed. Contract integration checks are not an independent
audit of KasForge's contracts.

## Verification and downloads

166 Rust core tests and 1,144 full-suite Flutter tests passed; 17 optional
live/snapshot tests were explicitly skipped. Coverage includes real captured
unsigned Mainnet buy/sell plans, locally executed contract witnesses, network
separation, recovery, historical reserve values, and the twelve-entry browser
catalogue on narrow screens in every theme. The actual signed APK's native
libraries, new browser entries, official image assets, client configuration,
version and signing certificate were checked. No funded swap was executed
during this release run; prior Mainnet device testing was confirmed by the user.

Install over the existing app; do not uninstall or clear wallet data.

- [Official APK](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.97.apk)
- [GitHub APK](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.97/Kaspire-Android-mainnet-v0.11.97.apk)
- [SHA-256 checksum](https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.97.apk.sha256)
- [All changes since the previous public Android release](https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/compare/v0.11.94...v0.11.97)

APK SHA-256:
`e17de517f8b3dec5791e6bda9328abbcf69a37eaa7bc211ff450aa6eaad5c7dc`.

Android signing-certificate SHA-256:
`0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
