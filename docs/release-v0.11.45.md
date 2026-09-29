# Kaspire Android 0.11.45

This release makes Covenant Dragon lifecycle transactions immediately visible
and easier to follow after WalletConnect returns control to GothDAG.

## Covenant Dragons

- Record the Genesis egg transaction in Kaspire Activity as soon as the local
  node accepts its broadcast.
- Record both the confirmed DAA-clock commit and the Covenant successor
  transaction for every lifecycle action.
- Label incubation, warming, hatching, feeding, growth, naming, sleep, wake,
  transfer and special-feed actions in plain language.
- Refresh an open Activity panel immediately when a dApp transaction is
  recorded.
- Show an explicit successful-broadcast confirmation before the user returns
  to GothDAG for Mainnet verification.

## Security and compatibility

- Preserve the package ID, Android 11+ support and established Android signing
  lineage so existing installations can update normally.
- Keep transaction construction, validation and signing inside the pinned
  native Rust core and Android approval boundary.
- Keep the signed Android update manifest on the pinned Kaspire download host.
