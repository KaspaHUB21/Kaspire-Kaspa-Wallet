# Kaspire Android 0.11.53 — P2SH accounts

## P2SH accounts in Android and the browser extension

- Open Receive KAS and switch between ordinary receiving and a separate Mainnet P2SH account.
- Receive KAS without publishing the spending public key. Spending reveals that key; fresh P2SH change avoids reusing it for new payments.
- Use KIP-22 derivation with a seed-based HD wallet. Imported private-key wallets receive a clear explanation instead of a technical platform error.
- Keep P2SH balances and activity separate from ordinary KAS accounts and assets.
- Review the exact recipient, amount, fee and change before signing. Max automatically deducts the network fee.
- Rebuild and verify ownership and transaction terms in the shared Rust core, then simulate the spending scripts locally.
- Preserve issued/retired addresses and saved signed payments in encrypted recovery backups. Resume the same signed payment without creating a replacement.
- Automatically check own-node acceptance and copy transaction IDs from account activity.

P2SH hides a public key until spending; it does not turn Schnorr signatures into post-quantum signatures. Keep a current encrypted backup, do not reuse retired receiving addresses, and do not use the same P2SH account on multiple devices at once. Recovery in another wallet requires KIP-22 support; a seed alone cannot reconstruct signatures that were never broadcast.

## Navigation and browser refinements

- Keep dot.k Market exclusively inside K-Agora, not in HUB21 Toolbox.
- Keep the new Covenant Vaults accessible in HUB21 Toolbox without moving them to the main Vaults entry.
- Add Kaspa News with its original logo to Kaspire Browser, immediately before KasCoven Vaults. This read-only news entry does not request a wallet connection.

## Browser extension 0.5.11

- Bring the same KIP-22 P2SH account and encrypted recovery journal to the extension, including fee-adjusted Max, own-node confirmation and saved-payment recovery.
- Use the correct transaction submission route and report explicit rejections immediately instead of repeatedly waiting for confirmation.
- Keep the popup width unchanged when switching from Receive KAS to P2SH.
- Preserve timed unlock behavior; lock, wallet or network changes invalidate pending signature approvals.
- Include native Time Lock and Dead Man’s Switch Covenant Vaults with portable encrypted recovery files.
- Version 0.5.11 is live in the Chrome Web Store; the extension ZIP remains available separately.

## Compatibility

- Android 0.11.53, build 188; package `space.kaspire.wallet`; Android 11 and newer; ARM64 and ARMv7.
- Existing Android release certificate and signing lineage retained for normal upgrades from public and recent internal builds.
- Keep the signed update manifest and APK on the pinned Kaspire host, including WalletConnect fallback downloads.

## Release verification

- 493 Flutter tests passed; Dart analysis reports no issues.
- APK signature verified for Android 11–12 and Android 13+, with 16 KB zip alignment.
- APK SHA-256: `a980d2a7a3c7eb657d9fefb0794c89e53a29b90c0f5090fa92a219afe6bdae84`.
- Android signing certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
