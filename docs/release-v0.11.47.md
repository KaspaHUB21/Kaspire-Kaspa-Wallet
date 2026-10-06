# Kaspire Android 0.11.47 — Neptune and NFT Market

## Neptune theme

- Add the Neptune theme with turquoise ocean artwork, water-glass cards,
  pearl and moon ornaments, and the centered Kaspire balance-card logo.
- Keep controls, QR codes and transaction details readable across screens.
- Refine themed NFT cards and HUB21 button layouts.

## K-Agora NFT Market

- Choose between dot.k Market and NFT Market from K-Agora.
- List individual KRC721 NFTs using decentralized seller-signed PSKTs,
  without operator escrow or server-held keys.
- Browse and search listings with collection filters, collapsible trait
  filters, price sorting, and ten offers per page with Load more.
- Show NFT images, ticker, token ID and available rarity rank.
- Include My NFTs collection filtering and My listings with cancellation,
  active listings first and sold/cancelled history.
- Keep Send and List as separate NFT actions in asset collection views.
- Publish completed listings automatically with retries for temporary
  indexer lag; preserve interrupted transactions for recovery.
- Fix the fee recipient resolved from hub21.kas per listing. Kaspire's
  settlement profile enforces the 2.1% marketplace fee; a seller's partial
  PSKT signature alone cannot enforce this fee for external consumers.

## NFT display reliability

- Read wallet holdings, locally cached images, traits and rarity data from
  Kaspire's read-only KRC721 gateway.
- Fall back to the official inventory source only when the local source is
  unavailable; independent metadata or image failures do not hide holdings.
- Continue using the official KaspaCom KRC721 indexer and accepted node data
  for transaction ownership, listing and spendability checks.

## Browser extension parity

- Include Neptune, NFT Market and the read-only NFT display integration.
- Restore collection thumbnails and place normal Send/List buttons beneath
  NFT gallery images.
- Do not label app-created listings as incomplete merely because they lack
  extension-local recovery metadata; hide recovery controls on terminal sales.
- Fix Neptune browser-action autosizing and preserve the selected theme.

## Compatibility

- Android package `space.kaspire.wallet`, version 0.11.47, build 142.
- Preserve Android 11+ support, the established signing lineage, and upgrades
  from the tested Neptune/NFT builds.
- Keep the signed update manifest and APK URL on the pinned Kaspire host.

## Release verification

- APK SHA-256: `203336afb3324d5898513001223e2bfa5edaadb22ac4c3f59f2b2677eba49031`.
- Signing certificate SHA-256 (Android 13+):
  `0e6195b93a39d68d99ae6b9519220b46f2d2b60ae416bfa8b8ed5713f1ed6c3d`.
- Legacy certificate SHA-256 (Android 11–12):
  `89b3086bc31a733453c4d4915b1c8b294cf029dc8673195a19028ab31e8385bb`.
- Both supported native ABIs rebuilt; APK signatures and 16-KiB alignment
  verified. Flutter analysis is clean; 185 Flutter and 80 native tests pass.
- Extension test revision: 0.5.7.1; 60 regression tests and actual Chromium
  popup/theme checks passed before Chrome Web Store publication.
