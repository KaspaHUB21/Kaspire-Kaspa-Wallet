# Kaspire Android 0.11.61 — KaspaRocket token transfer hotfix

- Fix the erroneous “Sending disabled: cell discovery is incomplete” gate for
  KaspaRocket KCC20 balances in the new token detail/Send Asset flow.
- Resolve Rocket token-cell hints directly, without depending on Kasvio's
  recognition of bonding-curve tokens or legacy indexer signing-cell lists.
- Reconstruct the pinned 10x10 reference token program and verify exact live
  outpoints, owner/script commitments, covenant IDs, deposits and DAA metadata
  against Kaspire's own Mainnet node. Native Rust still rebuilds and locally
  simulates the final transfer; the discovery check is not bypassed.
- Keep up to ten token inputs in one payment; larger fragmented holdings use
  the existing native consolidation plan and saved-transfer continuation.
- Confirm Kasseal Mainnet holdings load directly into the home wallet's KCC20
  assets, without opening Swap. Token sources remain independent, so an
  unavailable source does not suppress another source's balances.

The Android signing certificate and update-manifest trust remain unchanged.
Validation: 628 Flutter tests and 8 resolver/SDK tests pass. This includes a
read-only live Rocket cell check and real Kasseal holder
response inspection; no real-money transfer was signed or broadcast.
