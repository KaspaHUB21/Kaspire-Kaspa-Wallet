# Kaspire Android Explorer

Read-only embedded React UI, bundled into
`apps/mobile_flutter/assets/explorer/`. The Android host applies its theme and
provides a bounded, allowlisted public-read transport. It does not expose a
wallet provider, keys, signing or transaction submission to this UI.

Run `npm ci`, `npm run build` and `npm test` in this directory. The build checks
TypeScript, produces the local JS/CSS/font assets and records source/static-file
hashes in `provenance.json`. Use an isolated build environment without wallet or
release credentials. Do not update the generated files independently of source.

`tests/browser.mjs` exercises the built bundle in Chromium with captured public
read fixtures under `/fixtures` and writes results/screenshots under `/export`.
The Android release workflow repeats those checks with Explorer files extracted
from the signed APK. Browser fixtures must not broadcast real transactions.

The embedded view intentionally excludes L2, Combined/domain-portfolio routes,
the domain-only NFT Holder Snapshot and table-view switches. Native Igra/Kasplex
wallets and stored legacy favorites are not deleted or changed. NFT ranks,
listing coverage and unavailable token units remain explicit rather than guessed.

The small public BlockDAG and NFT-trait read services are in `ops/explorer/`.
Their production instances are deployed separately from the APK.
