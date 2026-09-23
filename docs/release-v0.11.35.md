# Kaspire Android 0.11.35 · build 108 and extension 0.4.9

- K-Agora is now directly accessible as the fourth wallet action in Android
  and the browser extension.
- The extension implements the same dot.k covenant marketplace as Android:
  Browse, My names, My listings, listing, purchase, cancellation, recovery
  codes, automatic publication and the explicit publication retry path.
- Both clients load twelve offers initially, add twelve with Load more and
  progressively verify only displayed listings, two at a time. Name discovery
  remains independent from Browse and no periodic polling delays the screen.
- Extension marketplace transactions are reconstructed, reviewed and signed by
  the packaged Rust/WASM security core shared with the Android Rust core. Fresh
  node proofs and exact deed/sale covenant cells are required before signing.
- Marketplace review shows price distribution, reserve, fee, change, covenant,
  mass, signing identities, native review hash and the unsigned raw transaction.
- HUB21 and all existing extension themes cover the new marketplace interface.
- Android 11+; existing v3/v3.1 signing lineage retained for normal upgrades.

Verification: Flutter analyzer clean; 130 Flutter tests, 61 native Rust tests,
37 extension/WASM tests and the Chromium end-to-end smoke test pass.
