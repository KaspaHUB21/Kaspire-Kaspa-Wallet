# Kaspire Android 0.11.60 — Kasseal Mainnet and wallet refinements

- Mainnet Swap now lists KaspaRocket, Kasseal and KRON, in that order.
- Kasseal curve and pool trades use SDK 0.1.1, verified launch proofs, separately
  pinned Mainnet contracts, independent own-node input checks and local Rust
  script simulation. Testnet 10 remains available on its separate endpoint.
- Curve trades use exact 1,000-token lots; graduated constant-product pools
  accept whole-token amounts without lots. Token-cell deposits, protocol fees,
  network fees and net wallet changes are shown separately.
- Partial Kasseal sales prepare necessary self-owned splits/merges before a fresh
  sale review. Encrypted recovery reuses the same signed bytes, with swap history.
- KaspaRocket token details show image, ticker, balance, price per token and balance
  value, with separate Send Asset and Swap buttons instead of opening Swap immediately.
- P2SH account history now paginates and deduplicates transactions across addresses,
  with Load more and an explicit incomplete-history state.
- Saved-swap recovery checks more input groups and paginated history. Only an
  independently confirmed exact conflicting spend can retire a saved payment;
  missing data or exhausted lookup limits never permit unsafe replacement.
- dot.k Browse defaults to newest listings and adds optional name-length filters.
- Verified KCC-23 metadata takes precedence over technical fallback token aliases.
- US-style thousands separators and exact integer Sompi formatting improve
  readability across token, marketplace, swap and EVM balance displays.

Validation: 623 Flutter tests, 129 Rust tests, 212 extension tests, 16 gateway
tests and 5 SDK tests pass. Mainnet curve/pool and token
preparation fixtures execute locally with synthetic funding; no real-money test
trade was signed or broadcast for this release. Android signing certificate and
lineage remain unchanged. This release does not publish a new extension package.
