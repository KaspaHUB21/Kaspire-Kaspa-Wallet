# dot.k integration: Android and extension

Release: **Android 0.11.31 (100)** and **extension 0.4.8**.
Both use the same embedded Rust deed derivation (JNI / locally packaged WASM)
and equivalent directory, script/bond/covenant and fresh-UTXO verification.
The extension adds host access to the documented dot.k directory only.
Its Chrome Web Store rollout is separate from the ZIP download.

## Prior Android device test

Private test: **0.11.31-dotk.1 (99)**, confirmed working by the user.

APK: `artifacts/dotk-test/Kaspire-Android-dotk-v0.11.31-test-build99.apk`
(96,364,461 bytes). SHA-256:
`d8c227ea0d2336db4aeba58686a5f54f12390670567b56234f7c12c5ea3977f1`.
Existing signing lineage verified for API 30–32 and API 33+; minSdk 30,
targetSdk 36. 113 Flutter tests and 49 Rust tests passed; analyzer clean.
The live probe also passed with the real directory and node. No transaction
was signed or broadcast. No physical Android device was connected for UI testing.

## Scope

- Separate, alphabetically ordered, collapsible dot.k names category.
- Holdings are explicitly directory listings, not independent ownership proofs.
- Opening a name freshly checks its ownership and shows its payment address,
  deed address, registry covenant ID and live outpoint.
- KAS and existing asset send forms accept `name.k` via the shared recipient
  resolver. Address-book and watch-wallet name entry use that resolver too.
- Existing native transaction review, allowlist and approval remain in effect.
- Mainnet Layer 1 only. No name registration, deed transfer, record/avatar
  rendering, custom payment record interpretation, Testnet or EVM resolution.

## Public protocol sources (reviewed 2026-09-15)

- https://dotk.name/developers
- https://dotk.name/integrators
- https://api.dotk.name/v1/openapi.json
- https://api.dotk.name/v1/genesis

The address endpoint returns a complete set with no pagination in the current
OpenAPI contract. No arbitrary 10/50/100-name display cap is applied. Failed or
malformed listings display an unavailable notice rather than pretending the
wallet has no names. The only confirmed public directory is `api.dotk.name`;
other site hosts were not confirmed REST mirrors and are not configured.

## Ownership checks

The mainnet v4 identity and deed bytecode are embedded in
`crates/kaspa_secure_core/src/dotk_mainnet.json`. Runtime API responses cannot
replace the deployment. The compiled registry is
`ee2128c03dfac7f6d74734bb3c879bd999434c47a55945b8a6daae2a1e4a21de`.

Rust validates the ASCII name and owner scheme, hashes the bare name with
BLAKE3, writes the 103-byte ACTIVE state into the pinned deed template and uses
the official Rusty-Kaspa P2SH/address implementation to derive the deed address.
It independently derives the payment address for Schnorr, ECDSA and P2SH owners.
Covenant-owned names have no ordinary address and are refused as recipients.
No seed, private key, signing operation or wallet authorization is used for
this read-only derivation.

The resolver compares the directory response to that derivation, queries the
configured own-node REST bridge for live UTXOs at the derived deed address,
requires the exact 1 KAS bond and script, and checks the corresponding accepted
transaction output for the pinned registry covenant ID. It rechecks the live
outpoint after this lookup. It does not treat funding a deed address with an
unrelated coin as an ownership proof. No cached resolution is reused for a new
payment, and network changes abort resolution.

The current REST bridge omits covenant IDs from UTXO responses, hence the extra
transaction lookup. This depends on the bridge being able to retrieve the
creating transaction; if pruning or availability prevents that, payment
resolution fails closed, even if the name is legitimate. A future bridge
enhancement can expose covenant IDs directly from indexed UTXOs to remove that
extra dependency. Node responses remain a trust boundary, not SPV consensus
verification performed on the phone. A name can also change ownership after a
check; users must review the final address in the existing confirmation screen.

Directory completeness cannot be independently proven from a UTXO index alone.
Names are public data, and lookup services learn queried names/addresses and
request IP addresses. Cards/custom records are deliberately not rendered or
used as payment targets without their separate protocol proofs.

## Verification

```sh
cargo test --locked -p kaspa_secure_core --lib
cargo build --locked -p kaspa_secure_core --example dotk_derive
cd apps/mobile_flutter
flutter analyze --no-pub
flutter test --no-pub
# Optional read-only live integration probe; performs no signing/broadcast:
flutter test --no-pub tool/dotk_probe.dart
```

The regression vector for `21millioncoven.k` binds the complete derivation to
its real mainnet deed address. Negative cases cover malformed names, owner
schemes, wrong deployment/address/deed, spent outputs, missing registry lineage,
incorrect bond/script and unaccepted transactions. Holdings tests cover sorting,
deduplication and more than 100 names.

Manual device test: open the owner as a watch wallet, expand dot.k names, open
`21millioncoven.k`, check the verified owner, then enter the name in a send form
and inspect the resolved recipient. Review only; a real payment is not required
to test resolution. Repeat in Midnight and HUB21 and on a narrow screen.
