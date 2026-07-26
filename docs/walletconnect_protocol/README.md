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
