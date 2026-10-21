# Kaspire Browser Extension 0.5.21

- Add KaspaRocket Mainnet under Swap, before KRON, with DEX Swaps and My Activity.
- Load bonding-curve holdings directly and independently of Kasvio; display prices per complete token.
- Keep all Mainnet SDK credentials on Kaspire's gateway, outside the extension.
- Rebuild the shared Rust/WASM signing core with Mainnet network, fee, review-hash and full covenant-script validation.
- Verify live swap inputs and their covenant origins using Kaspire's own node.
- Persist signed swaps inside the encrypted wallet vault before submitting; resume only the same approved bytes.
- Restore Refresh quote after an independently confirmed conflicting spend makes an old plan obsolete. Preserve recovery during timeouts, uncertain broadcasts and partial plans.
- Include pinned KCC20 10-input/10-output configurations and single-approval whole-payment consolidation plans.
- Keep the existing extension identity, wallet storage and upgrade path. No changes to Android.
