# Kaspire Browser Extension 0.5.22

- Add Kasseal Mainnet to Swap: KaspaRocket, Kasseal DEX, then KRON.
- Add verified Kasseal token discovery to wallet assets, independently of the other indexers.
- Search the complete Kasseal catalogue by ticker, name or covenant ID; paginate results and discard stale search responses.
- Support curve and pool buys/sells, exact whole-sompi curve lots, and separately reviewed split/merge preparations.
- Show trade proceeds, refundable deposits and actual net wallet changes without counting funding change as income.
- Add confirmed Kasseal swap history and transaction-ID copying. Persist signed recovery inside the encrypted wallet before submission.
- Rebuild the shared Rust/WASM core with pinned Kasseal Mainnet profiles and local contract execution before returning signed transactions.
- Open Rocket tokens in an asset detail view with balance, unit price, balance value, Send Asset, Swap and the correct KCC20 explorer link.
- Resolve Rocket transfer cells through the pinned 10/10 reference program and live own-node proofs, without requiring Kasvio cell discovery.
- Include the latest P2SH history pagination, bounded exact-outpoint swap conflict checks, verified KCC23 token display and dot.k newest/length filters.
- Improve exact US-style number formatting and keep forms consistent with the selected theme.

The extension identity and existing wallet storage are preserved. Provider SDK credentials stay server-side. Android, the website and the Chrome Web Store are not changed by building this package.
