# Covenant Vaults

The home-screen Vaults action uses the same `covenant_vault.rs`, `.sil` contracts,
transaction reconstruction, review binding, local consensus simulation and
`vault_recovery.rs` envelope as Android and Windows. It does not open a website.

The official SilverScript compiler remains pinned to
`3ed973335b59269293564805cc2c58a14595ec03`. For WASM, `build.rs` compiles these exact
sources on the build host and emits constructor-push substitution code. This
avoids duplicate WASM symbols from the compiler's older Rusty-Kaspa dependency.
No contract instruction is handwritten in the browser. Native tests compare
bytecode, dispatch tags and template hashes at integer encoding boundaries;
cross-runtime tests compare every action's complete review and transaction ID.
Large sompi integers cross the browser boundary as decimal strings, never rounded
JavaScript numbers. The recovery envelope itself is unchanged.

## Authorization and persistence

- Commands are internal to `wallet.html`, not provider/dApp methods.
- Reviews bind the unlock generation, context revision, wallet, derivation path,
  account and Mainnet. Lock clears cached reviews. Secrets are derived only after
  explicit approval and fresh own-node UTXO checks, immediately before signing.
- The encrypted portable recovery file must be downloaded and acknowledged
  before a creation signature is requested. It contains no wallet signing key.
- Public vault records and exact signed bytes are stored durably before broadcast
  in `chrome.storage.local.covenantVaultsV1`. Do not erase this catalogue when
  upgrading. State updates reject stale concurrent-window writes.
- Node acceptance, not broadcast acknowledgement, clears pending bytes. Resume
  broadcasts only those same bytes and never signs a replacement deposit. A
  missing UTXO, network failure or empty history never alone proves a payout.
- Confirmed opened vaults are hidden, not deleted. Recovery import never replaces
  a newer journal. DAG discovery reconstructs and verifies the local descriptor.
- Background confirmation polling does not extend the user's timed unlock.

## Recovery

The unchanged `kaspire-vault-recovery-pq-v1` envelope uses Argon2id (64 MiB,
3 iterations), XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87. Native and browser
exports can be imported interchangeably with the same password and relevant
owner/beneficiary wallet. This protects recovery metadata, not the on-chain
Schnorr signature scheme. A strong password and a separate saved file remain
essential. JavaScript/DOM secrets cannot be guaranteed to be physically erased
by the browser GC; temporary byte buffers are wiped and Rust owns zeroizing
password/KDF buffers.

## Verification

`npm test`, `npm run check`, `node tests/covenant-vaults-browser.mjs` and
`node tests/browser-smoke.mjs`. Public fixture keys are deliberately unfunded;
none of these checks broadcasts a real vault or moves user funds.
