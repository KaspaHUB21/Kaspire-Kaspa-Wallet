# Kaspire Android 0.11.58

## KaspaRocket on Mainnet

- Open Swap and choose KaspaRocket, now listed before KRON.
- Browse covenant tokens and use the same DEX Swaps and My Activity flow as on TN10.
- Buy and sell through KaspaRocket's bonding-curve, AMM and order-book routing.
- Review token and pool covenant IDs, token amounts, wallet flows and network/DEX fees before signing locally.
- Verify spendable Mainnet inputs against Kaspire's own node and validate signatures and scripts in the Rust core.
- Keep signed swaps encrypted for safe recovery without creating a second purchase.
- Show KaspaRocket token balances alongside other wallet assets and record completed swaps in activity.
- Load bonding-curve holdings directly from KaspaRocket, without waiting for Kasvio or other covenant indexers. Display amounts and prices in full token units rather than raw units.

## KCC20 payments

- Support locally verified 10-input/10-output KCC20 configurations, while retaining the original limits for existing 3-input/3-output tokens.
- Use a single whole-payment approval for larger, resumable consolidation plans.

## Release integrity

- Mainnet SDK credentials stay on the Kaspire gateway, never in the APK or public source.
- Preserve the Android package ID, signing certificate and upgrade lineage.
- Keep signed update downloads on the pinned Kaspire host.

This release updates Android only. The browser extension is unchanged.
