# Kaspire Android 0.11.49 — Nexus Offers and NFT Market refinements

## Nexus Offers

- Integrate private, non-binding NFT offers directly into K-Agora, without the former external Nexus website or a separate WalletConnect connection.
- Search by collection, collection and token ID, or wallet; browse active offers and inspect NFT details, traits and rarity rankings.
- Create private offers, negotiate counter offers and receive notifications for offers and listing activity. No funds are locked by an offer.
- Activate the ringing notification bell while the wallet is unlocked, without a second PIN/biometric prompt for internal notifications. Transaction signing retains its separate approval requirements.
- Show persistent success confirmations after creating offers and counter offers.
- Use the name “Nexus Offers” throughout the wallet.

## NFT Market and asset reliability

- Add expandable seller-wallet and NFT-trait details to listings; remove redundant active-status text from Browse.
- Default Browse to most recent listings. Apply price and collection-specific rarity-rank sorting across the directory before pagination.
- Load My NFTs in collection-specific pages of ten; show Load more only when additional matching NFTs exist.
- Restore emergency fallback to the official KRC721 indexer when the local display indexer is unavailable or returns an invalid response.
- Keep NFT images and rarity data local-first, while transaction authority remains with the official indexer.
- Improve HUB21, Glacier and Neptune borders for wallet and notification controls, and align the extension’s K-Agora shortcut.

## Token transfers

- Fix Android KRON broadcasting by including the finalized transaction ID in the canonical broadcast JSON; validate the signed contract locally before submission.
- Support the recognized legacy KCC20 template identifier while preserving local script, ownership and signing checks.

## Backup hardening and diagnostics

- Correct the native release constant and signer displays to the pinned Rusty Kaspa v2.1.0 dependencies.
- Pass Android backup passwords through mutable character/UTF-8 byte buffers and JNI, with zeroizing Rust buffers and explicit Java buffer clearing.
- Return backup keys as byte arrays rather than immutable hexadecimal strings.
- Preserve existing backup formats and Argon2id parameters; verify v2/v3 compatibility using frozen ASCII and Unicode key vectors.

## Release compatibility

- Android version 0.11.49, build 151, package `space.kaspire.wallet`; Android 11 and newer.
- Retain the existing Android signing lineage, including upgrades from recent internal test builds.
- Keep the signed update manifest and APK on the pinned Kaspire download host.
- Include the corresponding browser-extension source changes for the already-live Chrome Store release 0.5.7.8.
