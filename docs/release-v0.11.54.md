# Kaspire Android 0.11.54 — P2SH reliability and release hardening

- Restore the dedicated Android KaspaRocket Testnet-10 client configuration.
- Reject release builds with missing client configuration and verify the actual
  compiled configuration for ARM64 and ARMv7 before distribution.
- Keep the tested WalletConnect project identity unchanged.
- Give P2SH Receive, Send and Activity consistent theme-aware layouts, matching
  ordinary wallet controls in all themes, including narrow-screen layouts.
- Keep P2SH account history on Kaspire's own node; avoid unnecessary public API
  requests and isolate own-node reads from public-provider rate-limit cooldowns.
- Preserve valid empty own-node history instead of replacing it with a public
  provider error. Unavailable or unsynced data is not treated as a zero balance.
- Remove duplicated network error messages while retaining saved addresses,
  retired-key state and signed-payment recovery data.
- Harden sensitive derivation intermediates and the shared native/WASM input
  boundary without changing seed derivation, addresses or backup formats.
- Keep Covenant Vaults in HUB21 Toolbox and dot.k Market exclusively in K-Agora.

## Browser extension 0.5.14

The existing 0.5.14 package has been submitted to Chrome Web Store review.
It includes the matching P2SH theme/network reliability improvements, fixed popup
dimensions and mutable-buffer WASM boundary hardening. The existing package is
unchanged by this Android release; Store approval and rollout are separate.

P2SH hides the spending public key until spending. It does not make Schnorr
signatures post-quantum. Browser-memory wiping also remains best-effort where
JavaScript strings and garbage collection are involved.

## Compatibility

Android version 0.11.54, build 192; package `space.kaspire.wallet`; Android 11+
on ARM64 and ARMv7. Existing release certificate/signing lineage and pinned
update host are preserved. This release does not enable KaspaRocket Mainnet.

## Verification

- 518 Flutter tests passed; Dart analysis reports no issues.
- 150 extension tests passed; TypeScript reports no errors. The submitted ZIP
  was not rebuilt or changed.
- 14 gateway tests and 4 Android release-configuration tests passed.
- The separate official v2.1.0 validator accepted 8 synthetic P2SH cases and
  rejected all 56 mutated transactions. No live transactions were broadcast.
- Compiled Android client key and pinned WalletConnect identity verified in
  both ARM APK slices; the restored Android key is accepted by the provider's
  read-only TN10 protocol endpoint.
- A direct Gradle release validation without the client key was rejected as
  expected; the guard cannot silently turn a missing key into a release artifact.
- Android signatures verified for API 30–32 and API 33+; 16 KB ZIP alignment passed.
- APK SHA-256: `c27d902fa0d088af6046aacfb4dcd8ab2d0c8b7f58f8d8fae5a6871f7c43dcff`.
- Android certificate SHA-256: `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
- Extension ZIP SHA-256: `a6882357e67548e38818ab07bd972f00d123b85006b42d0931f7a777ba8b02d0`.

No physical-device Android test or live swap was performed for this release.
