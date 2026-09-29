# Kaspire Android 0.11.43

This Android hotfix binds Covenant Dragon signing to the exact WalletConnect
sender after the user approves the native review.

## Covenant Dragons

- Select the encrypted signing key by the reviewed genesis sender instead of
  implicitly using the wallet's primary address.
- Apply the same sender-bound key selection to later Covenant Wyrm transitions.
- Support imported keys, HD accounts and rotated receive addresses through the
  existing verified Kaspire address registry.
- Return a short, curated native or broadcast failure reason to the wallet UI
  instead of hiding every post-approval failure behind a generic message.

## Security and compatibility

- Preserve the package ID, Android 11+ support and established Android signing
  lineage so existing installations can update normally.
- Keep transaction construction, validation and signing inside the pinned native
  Rust core and Android approval boundary.
- Keep the signed Android update manifest on the pinned Kaspire download host.
