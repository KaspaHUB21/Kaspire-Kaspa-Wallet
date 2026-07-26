# Kaspire OWASP MASVS self-assessment

Date: 2026-07-23

This is an engineering self-assessment, not an independent security audit or a
certification. Open findings remain production-release blockers.

| MASVS area | Status | Evidence and open work |
| --- | --- | --- |
| STORAGE | Partial | Mnemonic/private-key wallet records are AES-256-GCM encrypted under Android Keystore; Android backup is disabled and native secret dialogs use `FLAG_SECURE`. Verify all SharedPreferences integrity and add tests for process-memory/keyboard leakage. |
| CRYPTO | Partial | Rusty Kaspa primitives, BIP39/BIP32, Schnorr, random GCM IVs and PBKDF2-SHA256 portable backups are used. Independent cryptographic review and differential vectors remain open. |
| AUTH | Partial | Every value-moving action requests biometrics/device credentials or a throttled Kaspire PIN. The vault key is deliberately not auth-bound because several OEM Keystores failed authenticated `Cipher.init`; therefore the custom PIN is not cryptographically bound to KeyStore use. This requires independent threat review before production. |
| NETWORK | Partial | Cleartext traffic is disabled and custom endpoints require HTTPS. There is no redundant node response comparison yet. Pin certificates only for endpoints controlled by Kaspire; public/user-selected nodes must remain compatible with normal WebPKI rotation. |
| PLATFORM | Partial | Export/recovery dialogs block screenshots, app links are origin-restricted, and the camera is optional. Add automated intent fuzzing, tapjacking/overlay tests, accessibility testing and background-task privacy verification. |
| CODE | Partial | Rust dependencies are locked and the native signer fails closed. Flutter/Gradle dependencies are locked locally, but reproducible-build verification, SBOM generation, vulnerability scanning, release minification review and a production signing key remain open. |
| RESILIENCE | Open | No root/hooking/tamper response or Play Integrity policy is implemented. These controls must not be presented as protection against a fully compromised device. |
| PRIVACY | Partial | No analytics or crash reporter is included. Public REST/indexer calls reveal queried wallet addresses to their operators; the endpoint UI must explain this and the own-node path must be completed. |

## Required verification before production funds

- Independent review of the Rust/JNI signer and Android vault lifecycle.
- Differential signing tests against the pinned Rusty Kaspa wallet/runtime.
- Fuzzing for transaction/UTXO/inscription decoders and every deep-link route.
- Manipulated, inconsistent and stale RPC response suites.
- Backup corruption, wrong-password, wrong-passphrase and full device-loss restore drills.
- Physical-device matrix covering Android 8–16, biometric/no-biometric devices,
  gesture/three-button navigation, low-memory process death, tablets and foldables.
- Production signing key, reproducible APK/AAB hashes and dependency/SBOM review.
