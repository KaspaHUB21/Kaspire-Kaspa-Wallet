# Kaspire provider API hand-off for KaspaCom

This document is the provider API documentation KaspaCom requested for its
wallet review. It documents Kaspire-owned native capabilities and transports;
it is **not** a KCOM adapter, SDK, or KaspaCom application integration.

## Responsibility boundary

- **Kaspire owns:** the injected extension provider and Android WalletConnect
  methods, account/network state, user approval, native transaction review,
  signing, returned signed PSKT JSON, optional typed-wallet broadcasts, and
  provider events.
- **KaspaCom owns:** its internal KCOM adapter, mapping the Kaspire API onto
  KaspaCom's shared wallet contract, application transaction construction,
  product/business validation, backend broadcast, and final target-app tests.
- **Joint work:** after KaspaCom has implemented its internal adapter, both
  teams run provider-plus-adapter smoke tests and collect TN10/Mainnet evidence.

The existing Kasware and Kastle adapters are KaspaCom-internal reference
implementations. Kaspire neither needs access to them nor publishes a
replacement for them.

Kaspire exposes the same reviewed transaction primitives through two transports:

- Browser extension: `window.kaspire`
- Android app: WalletConnect v2, Kaspa namespace

A provider-consumer example for the browser side is available in
[`docs/examples/kaspire-provider-client.ts`](examples/kaspire-provider-client.ts).
It demonstrates the native request and response shapes only. It deliberately
does not claim to implement KaspaCom's internal shared-wallet adapter.

KaspaCom and other marketplaces remain responsible for listing, buying, cancelling, royalty and DEX product logic. Kaspire does not require a marketplace-specific signing method. It reconstructs the supplied Kaspa SafeJSON in the shared Rust core, presents the resulting inputs, outputs, fee, wallet effect, scripts and sighashes to the user, and signs only the requested inputs.

## Native provider mapping

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

## Browser-extension discovery and request envelope

Kaspire injects `window.kaspire` into the page and dispatches
`kaspire#initialized` when the provider becomes available. A dApp can verify:

```ts
const provider = window.kaspire;
if (!provider?.isKaspire || typeof provider.request !== "function") {
  throw new Error("Kaspire extension is not available");
}
```

The current injected-provider protocol version is available as
`window.kaspire.version`. Requests use an EIP-1193-style envelope:

```ts
const result = await window.kaspire.request({
  method: "getNetwork",
  params: undefined,
});
```

Kaspire exposes convenience methods such as `requestAccounts()`,
`getAccounts()`, `getNetwork()`, `switchNetwork(network)`, `getPublicKey()`,
`getBalance()`, `signMessage(message, address?)`, `sendKaspa(params)`,
`signPskt(request)`, and `disconnect()`. Direct `request()` calls and the
convenience methods reach the same origin-bound implementation.

### Extension method contract used by KaspaCom

| Method | Params | Result |
| --- | --- | --- |
| `requestAccounts` | none | one approved full Kaspa address in `string[]` |
| `getAccounts` | none | the connected address in `string[]`, otherwise `[]` |
| `getNetwork` | none | `"mainnet"` or `"testnet-10"` for Kaspa primitives |
| `switchNetwork` | `{ "network": "mainnet" | "testnet-10" }` | approved network label; unsupported labels reject |
| `getPublicKey` | none | selected 32-byte x-only public key as 64 hex characters |
| `signMessage` | `{ "message": string, "address"?: string }` | `{ address, publicKey, signedMessage, signature }` |
| `getBalance` | optional `{ network }` | native snapshot plus `{ current, pending, outgoing }` in KAS |
| `sendKaspa` | `{ to, amountSompi, from?, priorityFeeSompi? }` | legacy txid string, or `{ transactionId }` when priority-fee shape is used |
| `signPskt` | normalized request documented below | `{ psktTransactionJson }` |
| `disconnect` | none | `true`, followed by local disconnect/account events |

The `address`/`from` value, when supplied, must equal the selected connected
account. Numeric transaction values are exact sompi integers; they are not KAS
decimal strings.

### Extension errors

Provider rejections contain a numeric `code` and human-readable `message`.
Important codes for an internal adapter are:

| Code | Meaning |
| --- | --- |
| `4001` | user rejected the connection, switch, signature, or transaction |
| `4100` | origin/account is not connected, wallet is locked, or selected wallet cannot sign |
| `4200` | method or requested mode is intentionally unsupported, including generic wallet-side PSKT broadcast |
| `-32601` | method is unavailable for the selected network/type |
| `-32602` | malformed or inconsistent request |
| `-32000` | node, broadcast, or verified execution failure |

KaspaCom should preserve these distinctions in its internal adapter rather than
turning every failure into a generic rejection.

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

Extension payloads relevant to KaspaCom are:

| Event | Payload |
| --- | --- |
| `accountsChanged` | connected full Kaspa address in `string[]`, or `[]` after disconnect |
| `networkChanged` | `"mainnet"` or `"testnet-10"` |
| `balanceChanged` | `{ current, pending, outgoing }` in KAS |
| `disconnect` | `{ code: 4900, message: string }` |

Listeners use `provider.on(event, listener)` and are removed with
`provider.removeListener(event, listener)`. Account or network mutation during
an open approval invalidates the signing context and the request is rejected.

## Integration rule

Do not ask Kaspire to implement marketplace-specific listing or DEX business methods. Build and validate the PSKT in the dApp, request only the necessary input signatures, show the dApp's own product review, then let Kaspire independently show and authorize the transaction-level review. Domain verification is phishing context, not a guarantee that a listing or trade is economically safe.

KaspaCom should implement the Kaspire mapping inside its private KCOM adapter
after reviewing this API. Changes required in that adapter belong to the
KaspaCom application repositories, not to the Kaspire wallet repository.

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

The Kaspire-native provider hand-off is ready for KaspaCom review. This is not
the same as declaring the complete KaspaCom integration ready for listing.
KaspaCom must first build its private KCOM adapter, after which both teams must
test the provider-plus-adapter result in the current KCC20 and Kaspiano target
applications and collect TN10 evidence with real transaction IDs. Do not
replace those records with invented transactions or provider-only unit tests.
Use [the evidence procedure](kaspacom-evidence/README.md) for the two-stage
handoff and joint validation.
