# Kaspire WalletConnect protocol v2

Kaspa currently has no official WalletConnect namespace or KIP defining a dApp provider API. Kaspire therefore uses a proprietary, versioned namespace and rejects every method not listed here.

```text
chain:   kaspa:mainnet
account: kaspa:mainnet:<address-payload>
methods: kaspa_getAccounts
         kaspa_signPersonal
         kaspa_sendTransaction
         kaspa_sendKrc20
         kaspa_sendKcc20
         kaspa_signPskt
         kaspa_signVaultTransaction
events:  accountsChanged
```

The CAIP-10 account stores the address payload without the redundant `kaspa:` prefix, for example `kaspa:mainnet:q...`. JSON-RPC results return the normal full `kaspa:q...` address. `kaspa_signPersonal` follows the active [KIP-5 message-signing specification](https://github.com/kaspanet/kips/blob/master/kip-0005.md).

## Pairing

The dApp creates a WalletConnect pairing URI, then opens:

```text
https://kaspire.kaslab.space/kaspire/wc?uri=<percent-encoded-pairing-uri>
```

The app link only launches the wallet. Approval, requests and responses remain inside the encrypted WalletConnect session. The `uri` must be consumed once, held in memory only, excluded from logs and analytics, and redacted from all errors.

Android verifies the `kaspire.kaslab.space` association before routing the HTTPS link to Kaspire. The canonical app link and the wallet's published WalletConnect metadata both use `https://kaspire.kaslab.space/kaspire/wc`. The legacy `kaslab.space` association remains accepted only for existing integrations. The app accepts only WalletConnect v2 `irn` pairing URIs, consumes each topic once per process and never includes pairing secrets in UI errors or logs.

## Request envelope

```json
{
  "chainId": "kaspa:mainnet",
  "request": {
    "method": "kaspa_sendTransaction",
    "params": { "to": "kaspa:q...", "amountSompi": "100000000" }
  }
}
```

KRC-20 transfers use the exact raw token amount:

```json
{
  "chainId": "kaspa:mainnet",
  "request": {
    "method": "kaspa_sendKrc20",
    "params": {
      "to": "kaspa:q...",
      "ticker": "SOULS",
      "amount": "100000000"
    }
  }
}
```

Kaspire verifies the selected wallet's indexed token balance, builds the canonical Kasplex transfer in the native Rust core, and requires separate commit and reveal authorization. The result contains both transaction IDs and their network fees. If the reveal cannot finish, the commit is saved for recovery inside Kaspire.

KCC20 requests identify the token by its 64-hex covenant ID and use an exact raw amount:

```json
{
  "chainId": "kaspa:mainnet",
  "request": {
    "method": "kaspa_sendKcc20",
    "params": {
      "to": "kaspa:q...",
      "covenantId": "d0d4ab...",
      "amount": "100000000"
    }
  }
}
```

Kaspire uses `kcc20.info` as its primary owner-balance, history and signing-data indexer. Kascov is used only when the primary service fails or explicitly reports an incomplete historical cell mapping. Kaspire accepts only indexer-verified tokens with a complete live-cell mapping. The native core recompiles each current and future KCC20 state from the vendored SilverScript source, compares the current state hashes, enforces token and transaction-value conservation, applies Toccata compute budgets and exactly 100 sompi/g, signs a typed version-1 transaction, and executes every input locally using its exact Mainnet script-unit allowance. Kascov's optional preflight is retained as advisory diagnostics; its fee field is never used. The signed transaction is broadcast through a compute-budget-preserving Toccata wRPC node, whose verdict is authoritative, and the returned transaction ID must match the locally signed ID.

The wallet fetches untrusted UTXOs itself, then the native Rust core reconstructs the transaction and derives the confirmation screen from the canonical result. Human-readable dApp metadata is never accepted as proof of transaction contents. Every payment, KRC-20 transfer and personal signature receives fresh explicit confirmation and biometric or PIN approval.

## Generic PSKT signing

Kaspire exposes `kaspa_signPskt` for dApp-independent Kaspa transaction flows,
including marketplace listings and purchases, KRC-721/KNS transfers, and
covenant interactions. It uses the Kasware-compatible SafeJSON request shape:

```json
{
  "txJsonString": "{\"version\":0,\"inputs\":[...],\"outputs\":[...]}",
  "options": {
    "signInputs": [
      { "index": 0, "sighashType": 1 }
    ]
  }
}
```

`sighashType` may be `1` (ALL), `2` (NONE), `4` (SINGLE), `129`
(ALL|ANYONECANPAY), `130` (NONE|ANYONECANPAY), or `132`
(SINGLE|ANYONECANPAY). The default is `1`. The result is the signed transaction
SafeJSON string. Kaspire never broadcasts a PSKT automatically.

This is not a blind signer. The native Rust core reconstructs the transaction
and embedded UTXOs, rejects duplicate outpoints, unknown envelope fields,
invalid values, already-signed selected inputs, invalid covenant bindings and
unsupported sighash values. It calculates the fee and wallet net effect and
binds the complete input, output, payload and signing selection to a review
hash. Kaspire displays every input, output, address or raw script, amount,
covenant ID, payload, fee, selected input and sighash. Partial signatures,
non-standard scripts and mutable sighashes receive prominent warnings. A fresh
native biometric/PIN authorization is bound to the review hash.

Kaspire guarantees that it signs exactly the transaction displayed by its
native verifier. It does not certify a dApp's business rules, marketplace
listing price, royalty logic, or covenant intent. Reown domain verification is
anti-phishing context; users must still trust the connected dApp and review the
transaction.

## Policy-verified vault transactions

Vault dApps may additionally request the stricter
`kaspa_signVaultTransaction` profile with transaction SafeJSON:

```json
{
  "txJsonString": "{\"version\":1,\"inputs\":[...]}",
  "signInputIndexes": [0, 1],
  "redeemScript": "..."
}
```

The currently accepted profiles are `vault-create-v2`,
`vault-dms-create-v2`, and `vault-dms-heartbeat-v2` for protocol
`kaslab-time-lock-vault-v1`. Create transactions must sign only input `0`.
Heartbeat transactions must sign exactly inputs `0` and `1` and include the
redeem script.

The Rust core parses the SafeJSON and embedded UTXOs, rejects duplicate
outpoints and pre-existing signatures, binds the redeem script to the P2SH
input, preserves the covenant output byte-for-byte and at the same amount,
allows change only to the session wallet, caps the total fee at 15,000,000
sompi, and binds the exact transaction to the native review hash. Unknown
protocols, profiles, scripts, output shapes and signing-index combinations fail
closed. This method is an optional protocol-specific safety profile; new dApps
and marketplaces do not need a Kaspire-specific policy and should normally use
`kaspa_signPskt`.
