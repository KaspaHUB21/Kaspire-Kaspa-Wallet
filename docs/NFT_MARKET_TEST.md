# K-Agora KRC721 NFT market — internal Android test

No public release, extension update or GitHub commit is part of this test.

## Test revision 3 (build 141): local KRC721 display data

Package: `0.11.47-nft-market.3`, build 141, unchanged signing lineage.
SHA-256: `5f05e4fcd35d46c91df2eff452136d69649a458aeac40f9fe92ca50aaff56034`.
All 185 Flutter tests and 14 private API tests passed; analyzer clean.
APK upgrade signatures and 16-KiB alignment verified.

Display reads use `https://kaspire.kaslab.space/krc721-read-v1` first:
wallet holdings, images, traits and saved Nexus rarity ranks. Ownership API
requests fall back to the official KaspaCom KRC721 indexer only on transport
failure, timeout, HTTP 408/429 or 5xx. A healthy empty result is authoritative;
403/404 and malformed successful ownership responses do not trigger fallback.
An independent metadata/image outage cannot discard discovered NFTs.

Missing or unavailable local metadata/image files can independently select
the existing KaspaCom metadata/cache services. Known collections without
published ranks have explicit empty local rank maps, not synthetic rankings
or unnecessary provider probes. Temporary failure cannot erase a known rank.
Images are locally resized to WebP; the app also has a fallback if the whole
image gateway is unavailable.

Transaction preflight (send/list), listing publication verification, and
buy/cancel live-listing checks continue to use the official KaspaCom KRC721
indexer exclusively. Local display state never substitutes for those checks.
Native UTXO, signature, canonical output and review binding checks are unchanged.

The local service exposes only validated GET display routes. Private indexer
administration, signing, broadcasting and optional API credentials are not
exposed. `scripts/export-nft-rarities.cjs` reads the existing Nexus rank cache
inside a read-only database transaction and atomically exports public rank
maps every five minutes. No owner records, credentials or private keys are
exported. `scripts/nft-read-server.mjs` uses only the loopback private API and
rank files; `scripts/nft-market-server.mjs` repairs existing offer metadata
without modifying seller PSKTs or signed sale terms.

Services: `kaspire-nft-read`, `kaspire-nft-rarity-export.timer`.
Rarity directory: `/var/lib/kaspire-nft-rarities`.
Private cached-metadata route added: `/v1/metadata/TICK?ids=ID,ID` (read-only).
Public ownership route: `/krc721-read-v1/address/ADDRESS`.
Public metadata route: `/krc721-read-v1/metadata/TICK?ids=ID,ID`.
Public image route: `/krc721-read-v1/images/TICK/ID`.

Live checks: existing KASZOMBIES #55 listing shows rank 114; HASH #1498 rank
2743; KASGOTHS #187 rank 845. Local KASZOMBIES #41 image returns WebP HTTP
200. Public admin request is 404 and public write request is 403.

## Test revision 2 (build 140)

- Browse trait controls are collapsed by default, with an active-filter count.
- My NFTs includes an alphabetical collection selector discovered across all
  wallet NFT pages; filtered ownership results retain load-more pagination.
- NFT asset tiles show both List and Send. Send remains disabled while listed.
- Native authorization retains review-hash binding and explicit approval,
  uses theme colors for the session confirmation, and displays NFT-specific
  validated terms instead of the generic PSKT warning count. OS authentication
  remains required when no authentication session is active.
- Indexer-lag, busy-directory, timeout and temporary-server failures retry
  publication automatically, without signing or broadcasting another listing.
  Saved incomplete publications resume when NFT Market is opened, including
  after restart, and retry while that screen remains open. Permanent validation
  errors remain visible and do not pretend the offer was published.

Test package: `0.11.47-nft-market.2`, build 140; same package/signing lineage.
No release manifest or public download/fallback link is changed.
SHA-256: `2c663b755f2ec6584f5a998cd95dacaac4c3b2555430414a1741a9645cfd86dc`.
Verification: all 174 Flutter tests passed; analyzer clean; upgrade certificates
verified for Android 11/12 and Android 13+; 16-KiB alignment verified.

## Test revision 1 (build 139)

Test APK: `0.11.47-nft-market.1`, build 139, package `space.kaspire.wallet`.
Same Android signing lineage as the existing Kaspire installation (min SDK 30).
SHA-256: `b39cde09e4f3734a0bb8530b8dc9d2b91c410f4d15688cbd67b5cd88ce3849c5`.

Automated checks: full Flutter suite passed (169 tests before the additional
remote-history pagination regression; six NFT-specific tests passed afterward),
full native suite passed (80 tests), final NFT-native tests passed after the
funding-selection adjustment, analyzer clean. Signature verification passed
for Android API 30–32 and API 33+, and 16-KiB zip alignment passed.

## Settlement

Uses the mainnet KRC721 `list`/`send` protocol and seller-signed PSKTs,
not an operator escrow. The deterministic listing redeem script contains
the seller's public key and canonical NFT `send` inscription. Listing is
commit/reveal; reveal output 0 is the listing P2SH. Ownership remains with
the seller while ordinary transfers are blocked by the KRC721 listed state.

Seller signs input 0 with SINGLE|ANYONECANPAY (132). Buyer adds funding;
output 0 pays 97.9% of the price plus the original listing reserve to the
seller, output 1 addresses the NFT to the buyer and returns buyer change,
output 2 pays 2.1% (rounded up to sompi) to the hub21.kas address resolved
and fixed when listing. Buyer also pays the network fee. Cancellation
uses ALL and **one output only**, returning the reserve less network fee
to the seller and delisting without transferring the NFT.

The seller signature cryptographically commits to the NFT outpoint and
seller payout. It does **not** make the separate platform-fee output
unavoidable for external PSKT consumers. Kaspire reconstructs and enforces
the exact fee output in its native NFT-market profile; the public directory
verifies the seller signature and fixed fee recipient before publication.
This limitation is disclosed in the seller PSKT review.

The directory stores only public offers/signatures and provides discovery.
Native code reconstructs the script and outputs, verifies the seller
signature, binds the review, and simulates fully signed purchase/cancel
transactions locally in the Kaspa script VM. Clients check accepted-chain
listing proof, live UTXO and current indexer ownership/listing state.

## UI and recovery

- K-Agora choice: dot.k Market / NFT Market. TN10 DEX routing is unchanged.
- NFT Market tabs: Browse / My NFTs / My listings.
- Individual NFT listing buttons and listed indicators in collection view.
- Ten offers per page; explicit Load more, search, collection/trait filters,
  ascending/descending price sort. No background polling timer.
- Image, ticker, token ID and actual rarity rank (or unavailable, never invented).
- Persist commit and reveal transactions before broadcast. Resume incomplete
  listings from My listings. Publish automatically after signing; failed
  publication leaves a conspicuous Publish action, not a duplicate listing.
- Published listings have no actionable Publish button. Active/pending
  listings first; newest first within the groups. Sold/cancelled history remains.

## Device test still required

Two distinct controlled wallets: list a low-value NFT, confirm Browse,
buy from the other wallet, verify indexer ownership and seller/fee payout.
Then list another NFT and cancel; verify original ownership and unlisted
state. Test wrong amounts, interrupts between each authorization, app restart,
failed publication and Resume, collection/trait filters, and more than ten
offers. Use small amounts: this feature operates on mainnet and has not yet
had an end-to-end user-device/mainnet transaction test.

Primary protocol references: https://krc721.kat.foundation/docs and
https://github.com/Nacho-the-Kat/krc721-protocol (commit
ce76f2a49e29f973cf3c54da3ff93cc9212e6231).
