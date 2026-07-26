# Roadmap

## Phase 1 — security core

- [x] Pin Rusty Kaspa `v2.0.1` with a locked dependency graph.
- [x] Implement BIP39 creation/import and first-address derivation at `m/44'/111111'/0'/0/0`.
- [x] Add the JNI bridge for create/import, address derivation, transaction preparation and signing.
- [x] Encrypt seed material with AES-256-GCM under an authenticated Android Keystore key.
- [x] Add bounded external/change discovery with gap limit 20 across modern coin type 111111 and legacy coin type 972, multiple BIP-44 accounts, and address-index subwallets.

## Phase 2 — spendable Android wallet

- [ ] Redundant wRPC/REST endpoint health and response consistency checks.
- [x] Strict standard-script UTXO selection, node fee estimation, transaction version checks and broadcast.
- [x] Confirmation UI bound to a native review hash, including recipient, amount, all selected inputs, outputs, change, fee and mass.
- [x] Add conservative Kascov discovery and safe typed handling/display/signing of the audited KCC20 version-1 covenant shape.
- [ ] Add generic watch-only decoding for other version-1 covenant/payload shapes; never expose generic signing.
- [x] Encrypted portable backup/restore with PBKDF2-SHA256, AES-256-GCM and explicit recovery-word/passphrase verification.
- [x] Persist pending/accepted/confirmed/failed activity, progressively load history and resume interrupted commit/reveal transfers.
- [x] Add payment-URI QR scanning, Send Max, an address book and a selectable HTTPS REST gateway.

## Phase 3 — mobile dApps

- [x] Reown WalletKit session lifecycle and one-use app-link pairing intake.
- [x] Domain/permission approval, per-request biometric/PIN approval and replay protection.
- [x] Typed KAS, KRC-20 and verified KCC20 dApp requests.
- [ ] Independent provider compatibility and adversarial dApp tests.

## Phase 4 — assurance

- Differential tests against Rusty Kaspa reference tools.
- Fuzz deep links, PSKT and transaction decoders.
- Phishing, replay and manipulated-RPC test suites.
- [x] Document an initial OWASP MASVS engineering self-assessment.
- [ ] Complete an independent OWASP MASVS review and wallet audit before production funds.
