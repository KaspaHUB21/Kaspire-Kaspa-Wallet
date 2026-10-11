# KRON Android integration

Pinned SDK: `@kronsdk/kron-sdk` 0.19.0. This is KRON's native token format,
not the forthcoming general KCC20 standard.

The loopback service exposes an unsigned catalogue, quote and transaction-plan
API at `/dex-test-v1/kron/{tokens,quote,plan}`. It never receives wallet secrets,
signatures or signed transactions and cannot broadcast trades. Metadata is
verified using the SDK's built-in token-list signing key and freshness checks.
Templates retain each token's launch-time parameters and template version.
Kasvio's public KRON-v2 catalogue is optional display enrichment only.

Android independently checks spendable UTXOs and confirmed covenant bindings
through the local-node gateway before review and again before signing. Rust
binds the amount, minimum receive, token/market IDs, recipient, fee outputs,
funding inputs, network fee and `kron:r:kaspirewallet` payload to the review.
All covenant inputs execute in the local script engine after funding signatures
are added. Temporary signing keys remain within the existing native boundary.

Signed wRPC transactions are retained in encrypted Android storage before
broadcast through the existing mainnet gateway; retries use the same transaction.
The review displays actual wallet KAS change, including token deposits and fees.

Checks:

```sh
npm test
cargo test --locked -p kaspa_secure_core --lib
flutter test test/kron_dex_amount_test.dart test/kron_dex_node_test.dart
```

`simulation-vector.mjs` piped into the `review_kron --simulate` Rust example
exercises live curve/pool programs with fabricated test-key ownership and
funding scripts. These vectors are **not chain-valid**, are never submitted,
and are not evidence of a completed mainnet trade. The fixed `11…11` private
key is a deliberately public test key; never fund it. Four locally simulated
paths: pool buy/sell and launchpad curve buy/sell.

Introduced in internal build 167 and published for Android in 0.11.51 (build 172).
The existing `/dex-test-v1` path and loopback service name are retained for
compatibility. Despite that historical name, the planner supports mainnet
KRON swaps in the public Android release. The browser extension is unchanged.
