# Kaspire Android 0.11.110 — Igra / Kasplex transfer encoding fix

2026-11-15. Android build **258**, cumulative changes since public Android
**0.11.109 (257)**.

## Igra and Kasplex transfers

- Fixed a reproducible encoding failure after signing an EVM transfer. When
  either signature scalar (`r` or `s`) started with a zero byte, the previous
  implementation retained that fixed-width padding. Ethereum RLP requires
  integers to use their shortest representation. Strict RPC decoders can reject
  such transactions with errors including `Failed to decode transaction
  (type 0): Unexpected type flag`.
- The native Rust signer now removes leading zero bytes from these two
  signature integers before encoding the signed transaction. The correction
  applies to both Igra and Kasplex, including native-currency and ERC20 transfers.
- This is an encoding correction, not a switch to another transaction type.
  EIP-155 chain binding, transaction review hashes, sender verification,
  authorization, destination, value, nonce, gas and calldata remain unchanged.
- QR scanning and address parsing are unchanged. No wallet reset, seed re-import
  or new permissions are required.

## Validation

- All **175 Rust core tests** pass. Added coverage includes the exact
  leading-zero regression, **2,048** signed transactions across Igra and Kasplex
  with canonical scalar checks and recovered-sender verification, the EIP-155
  reference signing payload, and ERC20 calldata/review binding.
- All **84 selected Flutter tests** pass, including actual Igra/Kasplex QR camera
  events, approval flows, narrow lockscreen layouts and Android update handling.
- Both ARM64 and ARMv7 native libraries were rebuilt and matched against the
  libraries in the final APK after normal release stripping. The package,
  permissions, branding, dApps, other native libraries, release certificate and
  signing lineage are preserved.
- Validation used offline signatures and local tests; no live payment was
  executed during validation. The public APK is byte-identical to the separate
  0.11.110 (258) Igra-send test APK.

## Delivery and platform scope

- **Both update routes** provide the identical signed APK: the official website
  download and the matching GitHub Release used by the in-app updater. The
  signed Android update manifest, website version and checksum are updated
  together without changing installed clients' update trust or URL format.
- Browser extension **0.5.31** and the iOS PWA are unchanged by this Android
  release. No Chrome Web Store submission or approval is implied.
- Release notes remain on GitHub only; the website download section does not
  gain an embedded changelog.

APK: `Kaspire-Android-mainnet-v0.11.110.apk`.

SHA-256: `49d017da9f6b7d29ce5c91e19ae278696590485d91ed07b527452a2fe104b39f`
