# Kaspire Android 0.11.40 and Extension 0.5.2

This release adds the native Covenant Dragons prototype and brings the browser
extension up to the account, theme and reliability baseline introduced in the
recent Android releases.

## Covenant Dragons

- Add reviewed Covenant Wyrm minting and state transitions to Android and the
  browser extension for the current private GothDAG Mainnet rollout.
- Construct, simulate and sign the covenant lifecycle in the shared Rust core.
- Verify the accepted creating transaction, output index, covenant ID, value,
  script, owner and current live UTXO before signing.
- Keep the rollout restricted to GothDAG, the configured prototype owner and
  the reserved serial/element set; all other requests fail closed.
- Require separate user approval for the commit and covenant-transition stages.

## Browser extension 0.5.2

- Generate fresh Kaspa receive addresses for mnemonic HD accounts without
  replacing the active wallet.
- Combine primary and rotated addresses into one KAS balance, activity history,
  UTXO set and locally reviewed multi-address spend.
- Keep KRC20, KRC721, KNS and KCC20 ownership attached to the address that
  actually holds each asset.
- Preserve the single-address signer path for imported private keys and normal
  subwallets, matching the Android 0.11.39 hotfix.
- Add the complete Glacier theme with local aurora artwork, crystal-glass cards,
  readable contrast and scanner-safe QR codes.
- Keep deterministic alphabetical asset ordering and complete KNS pagination.
- Use the credential-free Kaspire gateway when the public KRC20 indexer is
  unavailable; protected upstream credentials are never shipped in the app or
  extension.

## Security and compatibility

- Rebuild the shared Rust signing core for Android ARM64/ARMv7 and extension
  WASM.
- Validate every derived receive address against the encrypted active wallet
  and zeroize temporary signing material.
- Keep all remote indexer data outside the signing trust boundary.
- Preserve package ID, Android 11+ support and the established Android signing
  lineage so existing installations can update normally.
- Keep the signed Android update manifest on the pinned Kaspire download host.
