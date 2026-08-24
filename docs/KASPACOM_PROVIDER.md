# KaspaCom-compatible provider profile

Kaspire exposes the same reviewed transaction primitives through two transports:

- Browser extension: `window.kaspire`
- Android app: WalletConnect v2, Kaspa namespace

A complete normalization example for the browser side is available in
[`docs/examples/kaspacom-kaspire-adapter.ts`](examples/kaspacom-kaspire-adapter.ts).

KaspaCom and other marketplaces remain responsible for listing, buying, cancelling, royalty and DEX product logic. Kaspire does not require a marketplace-specific signing method. It reconstructs the supplied Kaspa SafeJSON in the shared Rust core, presents the resulting inputs, outputs, fee, wallet effect, scripts and sighashes to the user, and signs only the requested inputs.

## Provider mapping

| Primitive | Extension | Android WalletConnect |
| --- | --- | --- |
| Connect/account | `requestAccounts` | `kaspa_getAccounts` |
| Network | `getNetwork`, `switchNetwork` | `kaspa_getNetwork`, `kaspa_switchNetwork` |
| Public key | `getPublicKey` | `kaspa_getPublicKey` |
| Auth signature | `signMessage` | `kaspa_signAuth` |
| Balance | `getBalance` | `kaspa_getBalance` |
| KAS send | `sendKaspa` | `kaspa_sendTransaction` |
| PSKT sign-only | `signPskt` | `kaspa_signPskt` |
| Backend broadcast | the dApp backend | the dApp backend |
| Disconnect | `disconnect` | WalletConnect session disconnect |

Both transports support Mainnet and TN10 for generic Kaspa primitives. The
extension reports `mainnet` or `testnet-10`; WalletConnect uses
`kaspa:mainnet` and `kaspa:testnet-10` CAIP-2 chains and returns the same
labels. A request for an approved Kaspa chain switches the Android app to that
network before it is handled. Unsupported Testnet 11 and Devnet requests are
rejected explicitly. Kasplex and Igra use their separate `eip155` namespaces.
The human-facing selector calls Kaspa Mainnet **Layer 1** so it cannot be
confused with the Kasplex and Igra mainnets. This is presentation only: the
provider value remains the KaspaCom-compatible `mainnet`, and no protocol,
chain ID, address prefix or signing rule is renamed.

## Authentication result

The normalized authentication result contains the signing public key and KIP-5 Schnorr signature:

```json
{
  "publicKey": "<32-byte x-only public key hex>",
  "signedMessage": "<64-byte signature hex>",
  "signature": "<legacy alias>"
}
```

The address, public key and signing key are derived from the same selected wallet path. Kaspire rejects the operation if the selected account or network changes while an approval is open.

## Balance and KAS send

`getBalance`/`kaspa_getBalance` include the normalized KAS-unit fields:

```json
{ "current": 12.5, "pending": 0, "outgoing": 0 }
```

The extension may include its additional native snapshot fields. KAS send accepts exact `amountSompi` and optional `priorityFeeSompi`. Legacy callers receive a transaction-ID string; normalized priority-fee calls receive `{ "transactionId": "..." }`.

## Normalized PSKT request

Both transports accept the KaspaCom normalized shape. The legacy Kaspire/Kasware-compatible `txJsonString` plus `options.signInputs` shape remains supported.

```json
{
  "psktTransactionJson": "{\"version\":0,\"inputs\":[...],\"outputs\":[...]}",
  "submitTransaction": false,
  "signInputs": [
    { "index": 0, "sighashType": 132 }
  ],
  "scripts": [
    {
      "inputIndex": 0,
      "scriptHex": "<redeem script hex>",
      "signType": 132,
      "signatureScript": {
        "mode": "ordered-args",
        "args": [
          { "type": "byte", "value": 1 },
          { "type": "signature", "prefixHex": "" }
        ]
      }
    }
  ]
}
```

Supported sighashes are `1`, `2`, `4`, `129`, `130` and `132`. A script entry may select an input by itself; when both `signInputs` and `scripts` select the same input, their sighash values must agree.

Script modes:

- `wrap-signature`: the 65-byte Schnorr signature plus sighash is the only argument.
- `signature-first-args`: the signature is first, followed by the declared `i64`, hex `data` and one-byte `byte` arguments.
- `ordered-args`: arguments are emitted exactly in order and must contain exactly one `signature` argument; `prefixHex` is prepended to its signature bytes.

Kaspire appends `scriptHex` as the P2SH redeem script and independently verifies that its hash equals the selected embedded UTXO script public key. A mismatching script is rejected before approval.

The normalized sign-only response is:

```json
{ "psktTransactionJson": "<signed, preserved SafeJSON>" }
```

`submitTransaction: true` is deliberately rejected for generic PSKTs. KaspaCom should use sign-only mode and broadcast the returned transaction through its backend. This keeps arbitrary covenant transport outside the wallet while supporting the required backend-broadcast flow.

## Preservation and review guarantees

The Rust core preserves app-built inputs, outputs, covenant bindings and unknown safe metadata. Only the requested input `signatureScript` fields change. It does not reorder inputs or outputs. The review hash binds:

- the complete original SafeJSON, including preserved metadata;
- all parsed inputs, embedded UTXOs and outputs;
- covenant IDs and authorizing-input indexes;
- selected input indexes and sighash types;
- redeem scripts and signature-script templates;
- fee, wallet net effect and payload.

Duplicate outpoints, pre-signed selected inputs, malformed integers, invalid scripts, P2SH mismatches, conflicting sighashes, unsupported template shapes and stale account/network state fail closed.

## Events

The extension emits `accountsChanged`, `networkChanged`, `chainChanged` and `disconnect`; `balanceChanged` is produced by a bounded 15-second provider monitor while a listener is registered. Android WalletConnect supports `accountsChanged`, `networkChanged` and `balanceChanged`; the app publishes changes to sessions that negotiated those events. WalletConnect session deletion is the connection-state signal.

## Integration rule

Do not ask Kaspire to implement marketplace-specific listing or DEX business methods. Build and validate the PSKT in the dApp, request only the necessary input signatures, show the dApp's own product review, then let Kaspire independently show and authorize the transaction-level review. Domain verification is phishing context, not a guarantee that a listing or trade is economically safe.

## Verification status

Kaspire's local compatibility suite covers the complete provider request path,
not only the Rust functions:

- Extension onboarding, availability, origin approval and KIP-5 auth in a real
  headless Chromium instance;
- normalized script-aware PSKT signing through `window.kaspire` with
  `SingleAnyOneCanPay`, `ordered-args`, `data`, `i64`, `byte`, `signature` and
  `prefixHex`;
- preservation of marketplace input, output and top-level SafeJSON metadata;
- Mainnet/TN10 switching, the `networkChanged` event and rejection of a PSKT
  whose approved network changed while the confirmation window was open;
- shared-core tests for all six sighashes and all three signature-script
  templates, including every normalized argument type;
- Android method/chain advertisement, Mainnet/TN10 address conversion and the
  same shared native PSKT core.

The current recommendation is **private pilot**, not public listing. The
KaspaCom guide requires KaspaCom itself to test the complete adapter in the
current KCC20 and Kaspiano `origin/develop` applications and requires public
TN10 evidence with real transaction IDs. Those application repositories and a
funded KaspaCom test environment were not supplied with this integration. Do
not replace these records with invented transactions or provider-only unit
tests. Use [the evidence procedure](kaspacom-evidence/README.md) when KaspaCom
provides the target builds.
