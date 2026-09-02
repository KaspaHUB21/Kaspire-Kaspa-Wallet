# Kaspire native provider evidence

Date: 2026-09-02

Scope:

- Kaspire Browser Extension 0.4.6, injected `window.kaspire` provider;
- Kaspire Android 0.11.28, WalletConnect v2 Kaspa namespace;
- native wallet behavior only, before KaspaCom's private KCOM adapter exists.

This record is suitable for KaspaCom's initial provider review. It is not
evidence that the final provider-plus-adapter integration has passed KCC20 or
Kaspiano. KaspaCom owns that adapter and the joint target-app test phase.

## Reproducible provider suite

Run from the repository root:

```bash
./scripts/kaspacom_conformance.sh
```

Latest native results:

| Layer | Result | Coverage |
| --- | --- | --- |
| Rust security core | 44 passed | all six sighashes, all three signature-script modes, every argument type, SafeJSON preservation, P2SH binding, duplicate/pre-signed rejection and review binding |
| Extension TypeScript | passed | bounded provider surface and production type contract |
| Extension unit/WASM | 26 passed | provider validation, explicit PSKT inputs, metadata preservation, ordered arguments and network/address behavior |
| Headless Chromium | passed | real injected-provider connection, auth/public-key result, normalized script-aware PSKT approval, TN10 switch/event and stale-request rejection |
| Android 0.11.28 release qualification | analyze passed; 73 tests passed | WalletConnect method/chain routing, shared native signing core and application behavior |

## Capability-to-evidence mapping

| Requested native capability | Implementation/evidence |
| --- | --- |
| Detect and initialize | `window.kaspire.isKaspire`, `kaspire#initialized`, `requestAccounts`; exercised by `apps/browser_extension/tests/browser-smoke.mjs` |
| Active address and network | `getAccounts`, `getNetwork`, `switchNetwork`; Mainnet/TN10 switch and event exercised in Chromium |
| Auth signature and public key | `signMessage` returns address, x-only `publicKey`, `signedMessage` and alias `signature`; address/key consistency exercised in Chromium and shared-core KIP-5 tests |
| Balance in KAS | `getBalance` returns `current`, `pending`, `outgoing` in KAS; `balanceChanged` uses the same normalized shape |
| KAS send | `sendKaspa` accepts exact sompi plus optional priority-fee sompi and returns a transaction ID after node-ID comparison |
| PSKT sign-only | normalized `signPskt` returns preserved `psktTransactionJson`; `submitTransaction: true` rejects explicitly so KaspaCom can backend-broadcast |
| Explicit inputs/sighashes | Rust PSKT tests cover `1`, `2`, `4`, `129`, `130`, and `132`; Chromium provider smoke uses explicit `132` |
| Script-aware signing | redeem script is independently bound to the selected P2SH UTXO before signing |
| Signature templates | Rust tests cover `wrap-signature`, `signature-first-args`, and `ordered-args` with `i64`, `data`, `byte`, `signature`, and `prefixHex` |
| Preserve transaction structure | tests retain unknown top-level, input, output and marketplace/covenant fields while mutating only requested signature scripts |
| Events | native `accountsChanged`, `networkChanged`, `balanceChanged`, and `disconnect`; WalletConnect account/network/balance events plus session deletion |
| Reject stale requests | extension and Android re-check approved account/network state after the approval UI and before signing |

## Evidence still owned by the joint phase

The following cannot be truthfully supplied before KaspaCom builds its private
adapter and exposes the target test environment:

- the KCOM adapter version and normalized application behavior;
- KCC20/Kaspiano smoke-test results;
- real target-app TN10 transaction IDs and backend-broadcast records;
- adapter monitoring behavior where KaspaCom elects not to consume native
  events;
- the small-value Mainnet production-app revalidation.

Use `evidence-template.json` for provider-native records. For a joint record,
change `evidencePhase` to `joint-integration` and fill the app and
`kaspaComAdapterVersion` fields. Never include seeds, private keys, wallet
passwords, WalletConnect pairing URIs, access tokens, or API keys.
