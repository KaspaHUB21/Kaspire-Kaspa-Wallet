# Kaspire Android 0.11.42

This Android hotfix completes the authorization step for GothDAG Covenant
Dragons after the user accepts the dApp review.

## Covenant Dragons

- Authorize Covenant Wyrm genesis signing against the exact native review hash.
- Authorize Covenant Wyrm transition signing through the same protected path.
- Use one central allowlist for every native-reviewed signing operation so the
  displayed review, authorization token and signing request cannot drift apart.
- Remove consumed native reviews after signing, including Covenant Wyrm reviews.

## Security and compatibility

- Preserve the package ID, Android 11+ support and established Android signing
  lineage so existing installations can update normally.
- Keep transaction construction, validation and signing inside the pinned native
  Rust core and Android approval boundary.
- Keep the signed Android update manifest on the pinned Kaspire download host.
