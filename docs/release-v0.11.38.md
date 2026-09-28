# Kaspire Android 0.11.38

Kaspire 0.11.38 adds account-wide Kaspa receive-address rotation, introduces the Glacier visual theme, refines HUB21 layouts and keeps asset loading resilient when a public KRC20 indexer is unavailable.

## Rotating Kaspa receive addresses

- Generate fresh receive addresses from the active HD wallet.
- Combine the primary and rotated addresses into one KAS account balance.
- Merge KAS activity and spendable UTXOs across those receive addresses.
- Spend from multiple controlled receive addresses in one locally reviewed transaction.
- Keep KRC20, KRC721, KNS and KCC20 ownership bound to the address that actually holds each asset.
- Validate every derivation path and address against the encrypted active wallet before signing.
- Zeroize temporary HD signing material after derivation.

## Glacier theme

- Add a complete Glacier theme with a subtle aurora background.
- Use translucent frost-glass cards, crystal bevels and mint/lavender light veils.
- Keep QR codes scanner-safe with a dedicated dark module color.
- Preserve readable contrast across balance, send, receive, settings and review screens.
- Refine HUB21 button clipping and narrow-screen layouts.

## Asset reliability and ordering

- Route the authenticated secondary KRC20 source through the Kaspire gateway without shipping credentials in the app or extension.
- Keep direct indexer responses outside the signing trust boundary.
- Preserve progressive asset loading and deterministic alphabetical ordering.
- Improve KNS pagination so large name collections are not truncated.

## Security and compatibility

- Rebuild the Rust signing core for ARM64 and ARMv7.
- Preserve the Android signing lineage and package ID for normal upgrades.
- Continue supporting Android 11 and newer.
- Keep the signed update manifest on the pinned Kaspire download host.
- The browser extension remains version 0.5.1; its KRC20 fallback now uses the credential-free Kaspire gateway.
