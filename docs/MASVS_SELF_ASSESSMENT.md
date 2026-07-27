# Kaspire OWASP MASVS self-assessment

Date: 2026-07-27

This is an engineering self-assessment, not an independent security audit or a
certification. Open findings remain production-release blockers.

| MASVS area | Status | Evidence and open work |
| --- | --- | --- |
| STORAGE | Partial | Mnemonic/private-key wallet records are AES-256-GCM encrypted under Android Keystore. Address-book entries, watch-wallet metadata and local activity are held in Keystore-backed encrypted storage; version 0.10.8 migrates their legacy plaintext SharedPreferences values and deletes the old values. Android backup is disabled and native secret dialogs use `FLAG_SECURE`. Add tests for process-memory/keyboard leakage. |
| CRYPTO | Partial | Rusty Kaspa primitives, BIP39/BIP32, Schnorr and random GCM IVs are used. New version-2 portable backups use Argon2id (32 MiB, three iterations, parallelism 1, 32-byte salt) with AES-256-GCM; legacy version-1 PBKDF2-SHA256 backups remain importable. Deterministic address and signing vectors are cross-checked against the pinned Rusty Kaspa v2.0.1 implementation. Independent cryptographic review and broader differential vectors remain open. |
| AUTH | Partial | Every sign, secret export and wallet deletion is authorized inside Kotlin using Android BiometricPrompt/device credentials or a throttled Kaspire PIN. Native code issues a random 20-second, one-use capability bound to the exact operation and review hash/message/wallet, then atomically consumes it before touching the secret. The vault key remains deliberately not auth-bound because several OEM Keystores failed authenticated `Cipher.init`; independent review of that device-compatibility tradeoff remains open. |
| NETWORK | Partial | Cleartext traffic is disabled and custom endpoints require HTTPS. Kaspire's default REST gateway is backed by its own pruned Kaspa node; public services remain fallbacks for data the node does not index. UTXO ownership/shape/duplication, balance, history amount, fee and KCC20 signing-data invariants fail closed, and an in-app diagnostic view exposes node, indexer and WalletConnect health. There is still no two-node response comparison. Pin certificates only for endpoints controlled by Kaspire; public/user-selected nodes must remain compatible with normal WebPKI rotation. |
| PLATFORM | Partial | Export/recovery dialogs block screenshots, app links are origin-restricted, the camera is optional, and an optional privacy mode masks wallet and activity amounts while keeping authorization reviews explicit. Deterministic hostile app-link, WalletConnect and QR corpora run as tests. Add coverage-guided intent fuzzing, tapjacking/overlay tests, accessibility testing and background-task privacy verification. |
| CODE | Partial | Rust dependencies are locked and the native signer fails closed. Flutter/Gradle dependencies are locked locally, but reproducible-build verification, SBOM generation, vulnerability scanning, release minification review and a production signing key remain open. |
| RESILIENCE | Open | No root/hooking/tamper response or Play Integrity policy is implemented. These controls must not be presented as protection against a fully compromised device. |
| PRIVACY | Partial | No analytics or crash reporter is included. The default KAS data path uses Kaspire's own pruned node and gateway, and users may configure another HTTPS-compatible gateway. Token/history indexer calls still reveal queried wallet addresses to their operators. Privacy mode masks balances on screen but does not suppress required network queries. |

## Required verification before production funds

- Independent review of the Rust/JNI signer and Android vault lifecycle.
- Differential signing tests against the pinned Rusty Kaspa wallet/runtime.
- Fuzzing for transaction/UTXO/inscription decoders and every deep-link route.
- Manipulated, inconsistent and stale RPC response suites.
- Backup corruption, wrong-password, wrong-passphrase and full device-loss restore drills.
- Physical-device matrix covering Android 8–16, biometric/no-biometric devices,
  gesture/three-button navigation, low-memory process death, tablets and foldables.
- Production signing key, reproducible APK/AAB hashes and dependency/SBOM review.
