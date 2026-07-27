# Roadmap

## Phase 1 — security core

- [x] Pin Rusty Kaspa `v2.0.1` with a locked dependency graph.
- [x] Implement BIP39 creation/import and first-address derivation at `m/44'/111111'/0'/0/0`.
- [x] Add the JNI bridge for create/import, address derivation, transaction preparation and signing.
- [x] Encrypt seed material with AES-256-GCM under an authenticated Android Keystore key.
- [x] Add bounded external/change discovery with gap limit 20 across modern coin type 111111 and legacy coin type 972, multiple BIP-44 accounts, and address-index subwallets.

## Phase 2 — spendable Android wallet

- [x] Add an in-app diagnostic view for the configured REST gateway, UTXO
  integrity, KRC/KNS indexer, KCC20 signing capabilities and WalletConnect.
- [x] Reject malformed, foreign-address and duplicate UTXOs, impossible
  balances, negative history amounts and invalid fee estimates.
- [ ] Compare critical responses from two independent Kaspa endpoints before
  signing. Diagnostics and fail-closed validation are implemented, but
  redundant consensus is not yet implemented.
- [x] Strict standard-script UTXO selection, node fee estimation, transaction version checks and broadcast.
- [x] Confirmation UI bound to a native review hash, including recipient, amount, all selected inputs, outputs, change, fee and mass.
- [x] Add conservative Kascov discovery and safe typed handling/display/signing of the audited KCC20 version-1 covenant shape.
- [ ] Add generic watch-only decoding for other version-1 covenant/payload shapes; never expose generic signing.
- [x] Versioned encrypted portable backup/restore. New
  `kaspire-backup-v2` files use Argon2id and AES-256-GCM; legacy
  `kaspire-backup-v1` PBKDF2-SHA256 backups remain importable.
- [x] Persist pending/accepted/confirmed/failed activity, progressively load history and resume interrupted commit/reveal transfers.
- [x] Add payment-URI QR scanning, Send Max, an address book and a selectable HTTPS REST gateway.

## Phase 3 — mobile dApps

- [x] Reown WalletKit session lifecycle and one-use app-link pairing intake.
- [x] Domain/permission approval, per-request biometric/PIN approval and replay protection.
- [x] Typed KAS, KRC-20 and verified KCC20 dApp requests.
- [x] Add deterministic adversarial corpora for app links, WalletConnect
  pairing URIs, QR payment requests, UTXO responses and inscription fields.
- [ ] Complete independent provider compatibility testing and continuous
  coverage-guided fuzzing.

## Phase 4 — assurance

- [x] Pin deterministic address, signing, transaction-ID and KIP-5 vectors
  cross-checked against Rusty Kaspa v2.0.1.
- [ ] Expand differential tests to PSKT and every supported asset operation.
- [ ] Run continuous coverage-guided fuzzing for deep links, PSKT, transaction,
  covenant and inscription decoders. Deterministic hostile-input corpora now
  run in CI/local unit tests.
- [x] Add initial replay and manipulated-RPC fail-closed tests.
- [ ] Add a complete phishing suite and two-endpoint inconsistency harness.
- [ ] Complete an independent OWASP MASVS review and wallet audit before production funds.
