# Signing-boundary hardening — private verification build

Android: `0.11.54-hardening.1` / build `189`.
Extension: `0.5.12 Security Hardening` (same extension identity; no uninstall).
No public update-manifest, website, Git push or Store upload is part of this build.
The next public Android build must have a version code greater than 189.

## Changes

- All 28 secret-bearing WASM entry points accept owned UTF-8 byte buffers,
  including P2SH, ordinary payments, EVM, PSKT, token/reveal/vault signing,
  wallet import, derivation, password KDFs and mnemonic input checks.
- The JS adapter clears its transient buffers in `finally`, including a later
  argument failing validation or the native operation returning an error.
- Rust acquires a `Zeroizing<Vec<u8>>` owner before checking encoding or
  parsing a transaction. Invalid UTF-8 and malformed requests cannot bypass Drop.
- Derived backup AES keys are no longer returned as immutable hexadecimal
  strings. The native zeroizing owner is copied into a mutable JS buffer,
  explicitly wiped/freed, and the JS buffer is wiped after WebCrypto key import.
- Vault/backup encryption and decryption wipe their mutable plaintext buffers
  on success and exceptions, including JSON parsing and crypto failures.
- Avoid unprotected mnemonic normalization/copy intermediates. Use a wiping
  secp-key wrapper for intermediate extended HD keys in the common derivation
  path, as already used for P2SH. Wipe decoded passphrase bytes on encoding errors.
- Require a matching secret-boundary ABI version so mixed old JS/new WASM files
  fail closed instead of invoking incompatible secret interfaces.

## Compatibility and limits

P2SH descriptor, derivation path, script, review/recovery hashes, address indexes,
retirement journal and backup formats/KDF parameters are unchanged. Old encrypted
vaults and v1/v2/v3 portable backups remain supported. No funds are migrated.
The timed-unlock/session implementation is unchanged: a selected unlock period
remains usable, while lock/expiry invalidate existing approvals and remove the
volatile offscreen session.

This is memory hardening, not a claim of complete browser-memory erasure. The
unlocked JS session, editable import/export UI and JSON parsing still involve
GC-managed strings. Replacing the complete session with opaque native handles
would require a separate, broader vault/session migration; this build does not
pretend that swapping FFI parameters alone achieves it. WASM/Workers are not TEEs,
and `non_secure_erase` remains subject to normal compiler/copy limitations.
P2SH hides a public key until spending; Schnorr signatures are not post-quantum.

## Independent consensus check

`tools/p2sh-consensus-check` is a separate executable with no dependency on the
wallet/signing core, RPC client or broadcast path. Its build reads the unchanged
official transaction-validator Git objects from Rusty-Kaspa v2.1.0, commit
`01b532e8b553523216471682649693af92f0fd16`, not mutable checkout files.

The running own node was also queried read-only and reported `2.1.0`, synced.
The offline checker independently parses the serialized signed REST payload,
maps synthetic UTXOs, verifies transaction ID, isolation/header/UTXO rules,
scripts, exact fee, fully signed mass and the storage-mass commitment. It mirrors
the node's mempool mass-calculation step because REST v0 payloads omit mass.

Eight cases cover fixed amount/Max, one/two/ten inputs, regular/P2SH recipients,
fee rates 1/2.5/100/1000 and both compute- and storage-dominated transactions.
Both native and actual WASM outputs are checked. Seven mutations per case must
fail: signature, sighash, redeem script, recipient amount, input amount, duplicate
input and wrong mass commitment (56 negative checks per native/WASM matrix).

This verifies the selected rules against synthetic inputs, not real UTXO
existence, peer propagation, every possible mempool policy or future consensus.
No live payment/rebroadcast was made by these checks.

Run from the repository root:

```sh
cargo test --locked -p kaspa_secure_core --lib
node scripts/check_p2sh_consensus.mjs
npm --prefix apps/browser_extension test
npm --prefix apps/browser_extension run check
npm --prefix apps/browser_extension run package
```

Run the actual Chromium suite from `apps/browser_extension`:

```sh
node tests/browser-smoke.mjs
```

The browser suite exercises timer preservation/expiry, lock-before-sign,
worker restart, encrypted backup/restore, wallet-only P2SH command rejection
from another extension page/port, forged website messages, and checks that the
synthetic seed/passwords do not appear in Chrome storage, console or network
events. It also checks that expiry closes the offscreen session. These are
focused regression tests, not an independent end-to-end security audit.

## Verification results — 2026-10-20

- 118 native Rust tests passed.
- 149 extension tests passed; TypeScript reports no errors.
- 493 Flutter tests passed; Dart analysis reports no issues.
- Actual Chromium extension smoke passed, including timed unlock, expiry,
  invalidated approvals, storage/log/network checks and encrypted backup restore.
- Actual P2SH Chromium UI passed in Midnight, HUB21, Glacier and Neptune.
- Native and WASM matrices each passed 8 official-validator positive cases and
  rejected all 56 deliberately mutated transactions.
- Published 0.5.11 reference keys match v2/v3 output for ASCII, combining Unicode
  and a 65,537-byte password. Legacy v1/v2 and current v3 backup decryptions pass.
- Both Android ABIs rebuilt; signed APK certificate/lineage verified for API
  30–32 and API 33+, with 16-KB zip alignment. No physical-device Android test
  or live transaction broadcast was performed.

APK SHA-256: `b3c6f21bb1720fbf5bfebe8eef227521779becf8d129910bc44a404f3a1b287b`.

Extension ZIP SHA-256: `10cd7279837470a4c3970e0a4d1f2dfbe259fdacadcdb09ed7f7dc639996a1af`.
