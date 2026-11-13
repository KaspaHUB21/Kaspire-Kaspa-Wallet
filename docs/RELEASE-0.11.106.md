# Kaspire Android 0.11.106

2026-11-13. Complete cumulative changes since public Android **0.11.105 (252)**.
Includes the user-approved KCC20 dApp fix from **0.11.106-test.1 (253)**.
Public Android build: **254**.

## Native KCC20 payments from dApps

- Fixes KCC20 requests such as GothDAG's 21 Kaspire PunkyAI entry waiting
  without reaching the wallet approval dialog. The old handler scanned the
  entire wallet and expected discovery results to already contain verified
  signing cells. Current discovery deliberately resolves signing cells only
  when a specific transfer is prepared.
- Resolves only the requested, pinned reference KCC20 covenant, verifies its
  token units and current spendable cells, and prepares the complete native
  transfer plan. No full-wallet, NFT, price or unrelated token-history scan is
  required before approval.
- Shows a cancellable preparation dialog with progress before the explicit
  transaction review. Cancelling or rejecting does not sign or send tokens.
- Reuses an eligible recipient token cell with Borrowed Receive. An unavailable
  recipient lookup fails closed instead of silently funding an unnecessary new
  cell. Necessary self-consolidation uses the existing native payment planner.
- Saves the immutable signed plan before broadcasting, checkpoints confirmed
  steps, and supports continuation through Send assets. An existing saved
  payment blocks preparing a duplicate. The dApp receives the final recipient
  transaction ID, never an intermediate self-consolidation ID.
- Records each confirmed transfer in wallet activity. Uncertain signed-payment
  outcomes explicitly instruct users to check the dApp and the saved transfer
  rather than pay again.

## Delivery and validation

- Preserves the Android package, release certificate and signing lineage, both
  `arm64-v8a` and `armeabi-v7a`, native signing libraries and Android permissions.
- Preserves **both update routes**: the classic official-website APK download
  and the identical GitHub Release APK used by the signed in-app updater.
  Website version/checksum, release assets and signed manifest refer to the
  same public artifact. Build 254 upgrades both public build 252 and test 253.
- Repeats 100 focused dApp, KCC20 discovery, fallback, payment-journal and update
  tests, static analysis, and checks the actual built APK's two architectures,
  client configuration, signature, package identity and download hashes.
  Automated tests use isolated fixtures, not real user payments.
- Browser Extension **0.5.29**, iOS/React PWAs, Windows and unrelated in-progress
  marketplace/server changes are excluded from this Android release. This
  release does not change GothDAG's confirmation polling or its local indexer.
- Website download cards retain version, download and checksum; complete
  release notes remain on GitHub.

Verified Android APK SHA-256:
`7d458ba94b355e9dfc6ddff526960714bcb79cbf7f8dfa278e15bda0326f1142`
