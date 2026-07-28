# Kaspire — Kaspa Wallet for Android

Kaspire is a native self-custody Kaspa Mainnet wallet for Android. It combines
a Flutter interface with Android platform security and a pinned Rust signing
core so that remote APIs may provide blockchain data but cannot decide what the
wallet signs.

> **Core principle:** Network services may provide data, but they are never
> trusted to decide what the wallet signs.

Kaspire supports Android 11 through Android 16 on ARM64 and ARMv7 phones,
tablets, and foldables.

## Project links

- Website: [kaspire.kaslab.space](https://kaspire.kaslab.space)
- Security deep dive:
  [Inside Kaspire](https://kaspire.kaslab.space/security/inside-kaspire)
- dApp integration:
  [Kaspire Developer Guide](https://kaspire.kaslab.space/developers)
- Privacy policy:
  [kaspire.kaslab.space/privacy](https://kaspire.kaslab.space/privacy)
- Download:
  [kaspire.kaslab.space/#download](https://kaspire.kaslab.space/#download)
- WalletConnect protocol:
  [docs/walletconnect_protocol/README.md](docs/walletconnect_protocol/README.md)
- Security invariants:
  [docs/security_invariants/README.md](docs/security_invariants/README.md)
- Release verification and signing key:
  [docs/RELEASE_VERIFICATION.md](docs/RELEASE_VERIFICATION.md)

## Current release

- Version: **0.11.0**
- Android build: **58**
- Network: **Kaspa Mainnet**
- Android package: `space.kaspire.wallet`
- License: [Apache-2.0](LICENSE)

## Features

### Wallets and recovery

- New 24-word BIP-39 wallets
- Import of 12-word and 24-word recovery phrases
- BIP-39 autocomplete and immediate word-list validation against all 2,048
  official English words
- Optional BIP-39 passphrases
- Private-key import and watch-only wallets
- Multiple independent signing and watch wallets
- Multiple BIP-44 accounts under one seed
- KasWare-compatible address-index subwallets
- Modern and legacy Kaspa derivation discovery
- Argon2id-encrypted portable backup and restore

### Kaspa assets and protocols

- KAS
- KRC-20
- KRC-721
- KNS names
- KCC20 covenant tokens
- Detailed transaction activity
- UTXO counting and compounding
- KIP-5 personal-message signatures
- WalletConnect v2 for mobile and desktop dApps
- built-in WalletConnect QR scanner and active-session manager

### Wallet experience

- Send, Receive, Copy, and Send Max
- QR payment scanning and generation
- Scanner flashlight controls for payments and dApp pairing
- Kaspa payment URIs and KNS recipients
- Encrypted local address book
- Persistent pending/accepted/confirmed/failed transaction state
- Recoverable commit/reveal workflows
- Adaptive layouts for phones, tablets, foldables, cutouts, gesture
  navigation, and three-button navigation
- Optional Privacy Mode that masks wallet, asset and activity amounts without
  hiding exact values from transaction authorization dialogs
- Configurable immediate/5/10/15-minute inactivity lock with biometric,
  Android credential and Kaspire-PIN fallback
- Midnight, Emerald, Amethyst, Sakura, Crimson, Phoenix and Cypherpunk themes
- Optional hiding of address-index subwallets in the Wallets overview
- In-app diagnostics for the configured Kaspa gateway, UTXO integrity,
  KRC/KNS and KCC20 indexers, and WalletConnect

---

# Security architecture

Wallet security is not one algorithm or one confirmation dialog. It is a chain
of controls spanning entropy, key derivation, storage, authorization,
transaction construction, untrusted RPC data, token protocols, backups, dApps,
and release engineering. Kaspire applies controls at each boundary.

## 1. Secure seed generation

New wallets use a 24-word English BIP-39 recovery phrase, representing 256 bits
of entropy plus the BIP-39 checksum.

Entropy is generated inside the native Rust core using Android's
cryptographically secure operating-system random source. Kaspire does not use
timestamps, device identifiers, application-level pseudo-random generators, or
other predictable inputs.

Before activation, the user must verify randomly selected recovery words.
Secret-bearing screens use Android `FLAG_SECURE`, preventing ordinary
screenshots and recent-app previews.

## 2. BIP-39 passphrases

Kaspire supports an optional BIP-39 passphrase, sometimes called the “25th
word.” It is part of seed derivation and creates a completely different wallet;
it is not merely encryption around the same wallet.

Standard BIP-39 uses:

- PBKDF2-HMAC-SHA512
- 2,048 iterations
- the mnemonic as input
- `"mnemonic" + passphrase` as salt

Capitalization, spacing, and every character matter. Recovery words cannot
recover a passphrase-protected wallet if the passphrase is lost. The
BIP-39-mandated iteration count must not be compared directly with Kaspire's
Argon2id backup parameters.

## 3. HD derivation, accounts, and subwallets

Modern Kaspa:

```text
m/44'/111111'/account'/change/index
```

First address:

```text
m/44'/111111'/0'/0/0
```

Legacy compatibility:

```text
m/44'/972'/account'/change/index
```

Mnemonic import performs bounded discovery for both coin types, scanning
receive and change branches with a gap limit.

Kaspire distinguishes two concepts often both called “subwallets”:

- A BIP-44 account changes the hardened account component, for example
  `m/44'/111111'/1'/0/0`.
- A KasWare-style address-index subwallet remains in the same account and
  changes the final index, for example `m/44'/111111'/0'/0/1`.

The Rust core supports accounts 0 through 100. Before registering a derived
address, the native core derives it again from the encrypted secret and
requires path and address to match. Signing uses the exact stored path for the
sender; changing the visible account cannot silently select another key.

## 4. Encryption at rest

Signing-wallet secrets are protected by:

- AES-256-GCM
- a unique random initialization vector
- a non-exportable Android Keystore key

On supported Android 11 and newer, Kaspire first requests StrongBox. If unavailable, it
uses the strongest Keystore implementation reported by that device, potentially
a Trusted Execution Environment.

The AES key is not derived from the Kaspire PIN and is not stored in Flutter
preferences. AES-GCM provides confidentiality and integrity: modified
ciphertext fails authentication instead of silently producing corrupted wallet
material. Settings report whether Android identifies the key as
hardware-backed.

## 5. Native secret boundary

Recovery phrases and private keys are intentionally kept out of:

- Flutter/Dart state
- JavaScript and WebViews
- analytics and crash reporting
- logs and clipboard

Generation, import, encryption, decryption, HD derivation, secret export,
transaction construction, and signing run through Android's native boundary
and the Rust core. Flutter receives public addresses and review data.

Rust uses zeroizing containers so key and seed buffers are overwritten when
they leave scope. JNI requires some authorized values to cross as JVM strings,
which cannot be reliably overwritten; Kaspire limits their lifetime and never
returns them to Dart, but does not claim safety on a fully compromised device.

## 6. Fresh authorization

Connecting or unlocking does not grant unlimited signing authority. Fresh
biometric or PIN authorization is required for:

- KAS, KRC-20, KRC-721, KNS, and KCC20 transfers
- UTXO compounding
- recovery-phrase and private-key export
- encrypted backup and restore
- wallet deletion
- WalletConnect payments and message signatures

The optional 4–8 digit PIN verifier uses:

- PBKDF2-HMAC-SHA256
- a random salt
- 210,000 iterations
- a 256-bit verifier

The PIN does not directly encrypt the seed. Repeated failures trigger escalating
temporary lockouts to slow application-level online guessing.

## 7. Untrusted RPC and indexer responses

Kaspire defaults to HTTPS infrastructure backed by a Kaspire-operated pruned
Kaspa node and gateway, with public fallbacks where appropriate. Owning an
endpoint does not make its answers trusted signing decisions.

For each spendable UTXO, Rust validates:

- sender ownership and script
- transaction ID and output index
- amount validity
- network and address type
- coinbase restrictions
- payload and covenant restrictions

The Rust core—not the API—selects inputs, creates recipient and change outputs,
calculates mass and fees, and produces the canonical signing payload.

## 8. Transaction reconstruction in Rust

Kaspire never asks an API for an opaque finished transaction and signs it
blindly. Supported transactions are independently built from validated inputs.

Foreign scripts, wrong-network addresses, unexpected payloads, unsupported
covenants, unresolved inputs, invalid amounts, unsafe mass, and sender
mismatches are rejected.

An unavailable or dishonest indexer therefore cannot replace the recipient,
redirect change, or silently set an arbitrary fee.

## 9. Review-hash binding

Preparation and signing are separate.

During preparation, Rust creates a canonical review containing relevant fields:

- network, sender, and recipient
- amount, total input, and change
- fee and transaction mass
- input outpoints and output scripts
- payload
- token or covenant state

The canonical review is hashed with SHA-256. After approval, the exact request
and review hash return to Rust. The transaction is reconstructed and signing is
refused if the hash differs.

This prevents outputs, fees, payloads, token amounts, or network data from
changing between review and authorization.

## 10. Local transaction-ID verification

Kaspire calculates each transaction ID locally after signing. The broadcasting
node must return the same ID. Missing or mismatching IDs are errors, preventing
a gateway from claiming that a different transaction was submitted.

## 11. Watch-only isolation

Watch-only wallets display balances and activity but cannot sign. Payments,
asset transfers, message signatures, and compounding require an encrypted
native wallet controlling the exact sender. There is no silent fallback to
another stored wallet.

## 12. UTXO compounding

Compounding consolidates fragmented standard KAS UTXOs:

1. Load and validate the UTXO set.
2. Select at most 80 inputs.
3. Construct a self-transfer in Rust.
4. Calculate mass and fees locally.
5. Display input count, resulting output, and exact fee.
6. Require fresh biometric or PIN approval.
7. Verify the node's returned transaction ID.

Large sets require multiple bounded operations rather than one unsafe
transaction.

## 13. KRC-20, KRC-721, and KNS commit/reveal safety

Kasplex-style operations use commit and reveal transactions. Kaspire constructs
canonical protocol payloads locally. Commit and reveal remain explicit stages,
and the reveal is bound to the expected commit address, script, amount, and
outpoint.

If reveal cannot finish immediately, Kaspire saves recoverable pending state
rather than hiding the incomplete operation. Local and broadcast IDs must match
for both stages.

## 14. Typed KCC20 covenant signing

KCC20 support is not a generic “sign any covenant” interface. Kaspire exposes
one typed transfer path for the vendored verified template.

Before signing, Kaspire requires:

- a verified token record
- complete live-cell mapping from `kcc20.info`, or the conservative Kascov
  fallback
- a known covenant ID and matching template hash
- valid P2PK sender and recipient
- valid token amounts and state ownership
- mass-safe standard KAS funding

Rust recompiles the vendored SilverScript template and reconstructs current and
future states. It enforces:

- token-supply and transaction-value conservation
- ownership transitions and token change
- separate token quantity and KAS reserve accounting
- reserve top-up and release
- compute, storage, transient, and fee-mass limits
- exact Toccata fee rules
- local execution of each signed covenant input

Unknown templates, generic covenant requests, minter cells, unknown payloads,
coinbase inputs, incomplete mappings, and unsafe candidates fail closed.
Kascov preflight is advisory. The local engine and receiving node gate
broadcast. Toccata wRPC preserves version-1 `computeBudget`, and the returned ID
must equal the local ID.

## 15. WalletConnect isolation

Kaspire implements WalletConnect v2 with a versioned Kaspa namespace because
Kaspa has no official WalletConnect namespace.

Supported methods:

- `kaspa_getAccounts`
- `kaspa_signPersonal`
- `kaspa_sendTransaction`
- `kaspa_sendKrc20`
- `kaspa_sendKcc20`
- `kaspa_signPskt` (generic reviewed partial transaction signing)
- `kaspa_signVaultTransaction` (policy-approved vault profiles only)

Controls include:

- Kaspa Mainnet-only chain validation
- encrypted sessions and one-use pairing topics
- pairing URIs kept out of analytics and persistent app storage
- pairing secrets redacted from errors
- no arbitrary callback URL for transaction results
- fresh approval for every payment or signature
- exact session-account and signing-wallet matching
- rejection of watch-only signing
- rejection of WalletConnect v1, unknown methods, events, and fields
- no generic `signPskt` blind signer; external SafeJSON is accepted only when a
  native Rust policy reconstructs and verifies the complete transaction

Verified Android App Links associate
`https://kaspire.kaslab.space/kaspire/wc` with Kaspire. Desktop dApps can show
that HTTPS link as a QR code; scanning opens Kaspire and starts the encrypted
pairing. Human-readable dApp metadata is never proof of transaction contents;
the Rust review remains authoritative.

See the [complete developer guide](https://kaspire.kaslab.space/developers)
for QR behavior, schemas, errors, integer amount rules, and security guidance.

## 16. KIP-5 message signing

Personal signatures follow Kaspa KIP-5. Kaspire confirms that the encrypted
wallet controls the requested address and requests fresh approval. The method
does not expose an arbitrary transaction-signing primitive.

## 17. Argon2id-encrypted backups

New exports use `kaspire-backup-v2`.

The password KDF is Argon2id v1.3 with:

- 32 MiB memory
- three iterations
- parallelism one
- a random 32-byte salt
- a 256-bit output key

That key encrypts the backup using AES-256-GCM. Argon2id iteration counts are
small relative to PBKDF2 because every pass processes the configured memory,
raising the cost of parallel GPU and ASIC guesses.

Kaspire continues to import `kaspire-backup-v1`, protected by
PBKDF2-HMAC-SHA256 with 600,000 iterations. New exports use Argon2id.

Restore verifies format, KDF and exact parameters, salt length, GCM
authentication, recovered wallet address, and every stored derivation path.
Modified backups fail instead of registering unverified metadata. No KDF
compensates for a weak password; use a long unique backup passphrase.

## 18. Screen and clipboard protection

Recovery phrases, private keys, PIN entry, and other secret-bearing screens use
Android secure-window protection. Kaspire does not automatically copy secrets.
Public addresses and transaction IDs may be copied deliberately.

## 19. Pinned native signing code

The ARM64 and ARMv7 signing core is compiled into the APK and pinned to Rusty
Kaspa `v2.0.1`; `Cargo.lock` fixes Rust dependencies. Signing code cannot be
replaced by a web or over-the-air script update.

The F-Droid recipe deletes committed native artifacts and recompiles
`libkaspa_secure_core.so` from source for both ABIs.

## 20. No ads or analytics

Kaspire contains no advertising, Firebase Analytics, Crashlytics, or
proprietary tracking SDK. Network calls necessarily expose an IP address and
queried public addresses to the selected service. F-Droid metadata therefore
declares `NonFreeNet` for WalletConnect and external indexer features.

## 21. Fail-closed behavior

Unsupported or incomplete operations are rejected rather than guessed:

- unknown scripts, covenants, or payloads
- wrong-network addresses
- unresolved or foreign UTXOs
- stale or modified reviews
- mismatching broadcast IDs
- incomplete KCC20 discovery
- unsafe mass or compute budgets
- unknown WalletConnect requests
- watch-only signing attempts

No single layer carries the whole burden. Kaspire combines OS entropy,
standards-based recovery, hardware-backed storage when available, native
validation, explicit authorization, typed signing, review binding, and
post-broadcast verification.

---

# Architecture

```text
Flutter UI
   │  public addresses, canonical reviews, explicit user actions
   ▼
Android security bridge
   │  Keystore/StrongBox, secure windows, JNI
   ▼
Pinned Rust security core
   ├── BIP-39 / BIP-32 / BIP-44
   ├── AES-GCM and Argon2id
   ├── UTXO and transaction validation
   ├── review-hash binding and Schnorr signing
   ├── Kasplex commit/reveal
   └── SilverScript/Toccata KCC20 validation

HTTPS/wRPC APIs ── untrusted data ──► validation boundary
WalletConnect  ── limited requests ─► review + fresh authorization
```

## Repository layout

```text
apps/mobile_flutter/             Flutter Android app
crates/kaspa_secure_core/        Native wallet and signing core
crates/silverscript_lang/        Vendored SilverScript compiler
docs/security_invariants/        Release-blocking security rules
docs/walletconnect_protocol/     Kaspire WalletConnect protocol
fdroid/                          Candidate F-Droid metadata
fastlane/                        Store text and screenshots
ops/kaspa-api/                   Pruned-node gateway deployment
packages/kaspa_mobile_provider/  Website provider package
scripts/build_android_rust.sh    Android Rust source build
website/                         Website source
```

---

# Build

## Requirements

- Flutter 3.44.6 / Dart 3.12.2
- Rust 1.91.0
- Java 17
- Android SDK
- Android NDK 28.2.13676358

## Native Rust core

```bash
rustup toolchain install 1.91.0
rustup target add --toolchain 1.91.0 \
  aarch64-linux-android armv7-linux-androideabi

export ANDROID_NDK_HOME=/path/to/android-sdk/ndk/28.2.13676358
./scripts/build_android_rust.sh
```

Never publish an ABI without its matching native security core.

## Tests

```bash
cd apps/mobile_flutter
flutter pub get
flutter test
```

## Development

```bash
cd apps/mobile_flutter
flutter run
```

The public Reown project identifier is in source and can be overridden:

```bash
flutter run --dart-define=REOWN_PROJECT_ID=<public-project-id>
```

Project IDs are public configuration. Pairing URIs are secrets and must never
be logged, sent to analytics, or disclosed to unrelated services.

## Unsigned F-Droid release

```bash
cd apps/mobile_flutter
flutter build apk --release \
  --target-platform android-arm,android-arm64
```

Without Play upload-key variables, the release is intentionally unsigned.
F-Droid signs it inside its own infrastructure.

## Google Play upload bundle

Set:

```text
KASPIRE_UPLOAD_STORE_FILE
KASPIRE_UPLOAD_PASSWORD_FILE
KASPIRE_UPLOAD_KEY_ALIAS
```

Then:

```bash
cd apps/mobile_flutter
flutter build appbundle --release \
  --target-platform android-arm,android-arm64
```

Never commit keystores or signing passwords.

---

# F-Droid

Candidate metadata:

```text
fdroid/metadata/space.kasvault.wallet.yml
```

The recipe pins Flutter, Rust, and NDK; deletes committed `.so` files; rebuilds
the Rust core; creates an unsigned APK; leaves signing to F-Droid; and declares
`NonFreeNet`.

Google Play and F-Droid use different certificates. Android does not permit an
in-place upgrade across them. Confirm recovery material, uninstall one
distribution, then install the other when switching channels.

---

# dApp integration

Websites can connect from Android or a desktop browser through WalletConnect.
Desktop QR codes should contain:

```text
https://kaspire.kaslab.space/kaspire/wc?uri=<URL-ENCODED-WALLETCONNECT-URI>
```

Android may open the same verified HTTPS App Link directly. Do not log pairing
URIs or use arbitrary callback URLs.

The full guide is at:
[kaspire.kaslab.space/developers](https://kaspire.kaslab.space/developers).

---

# Security and responsible use

- [Security invariants](docs/security_invariants/README.md)
- [Security deep dive](https://kaspire.kaslab.space/security/inside-kaspire)

Begin Mainnet testing with the smallest practical amount sent between addresses
you control. Keep recovery phrases and BIP-39 passphrases offline and verify a
complete restore before relying on a wallet for larger amounts.

Never submit recovery phrases, private keys, passwords, pairing URIs, or
keystores in a public issue.

# License

Unless stated otherwise, Kaspire is licensed under
[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution and asset
information. Third-party dependencies retain their upstream licenses.
