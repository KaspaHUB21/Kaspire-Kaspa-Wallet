# KaspaCom compatibility evidence

This directory is the hand-off record required by the KaspaCom wallet-provider
guides dated 2026-08-23. It separates reproducible Kaspire conformance evidence
from evidence that only KaspaCom can produce in its current target apps.

## Scope

- Wallets: Kaspire Browser Extension 0.4.6 and Kaspire Android 0.11.28
- App surfaces: KaspaCom KCC20 and Kaspiano
- Networks: Testnet 10 private pilot, followed by a small-value Mainnet smoke
  test before public listing
- Broadcast mode: sign-only plus KaspaCom backend broadcast. Generic wallet
  PSKT broadcast is not advertised.

KaspaCom's named KCC20 and Kaspiano `origin/develop` repositories were not
provided and could not be found among KaspaCom's public repositories on
2026-08-24. The guide explicitly requires repo-dependent checks to be marked
unavailable in this situation. The legacy public `front-interface-v1` is not a
substitute for the target versions.

## Current matrix

| Primitive | Extension | Android | Local evidence | KaspaCom TN10 evidence |
| --- | --- | --- | --- | --- |
| Availability and initialize | Pass | Pass through WalletConnect | Chromium onboarding and origin approval; WalletConnect proposal tests | Pending target app |
| Address and network | Pass | Pass | Mainnet/TN10 prefix and chain tests | Pending target app |
| Switch network or reject | Pass | Pass | Chromium switch event; Android `kaspa_switchNetwork` and chain routing | Pending target app |
| Auth and public key consistency | Pass | Pass | Real extension approval plus shared-core KIP-5 tests | Pending target app |
| Disconnect | Pass | Pass | Provider disconnect event; WalletConnect session deletion | Pending target app |
| Balance in KAS | Pass | Pass | Normalized provider results and monitored events | Pending funded wallet |
| KAS send and priority fee | Pass | Pass | Transaction-core and provider request tests | Pending TN10 txid |
| PSKT sign-only | Pass | Pass | Provider-level Chromium PSKT and native-core tests | Pending target app |
| Explicit inputs and sighashes | Pass | Pass | All six values tested; provider smoke uses 132 | Pending target app |
| Script-aware signing | Pass | Pass | P2SH binding and provider request test | Pending target app |
| All signature-script templates | Pass | Pass | Rust tests cover all three templates and every argument type | Pending target app |
| PSKT preservation | Pass | Pass | Input/output/top-level metadata and covenant output tests | Pending target app |
| Backend broadcast | Supported | Supported | Signed SafeJSON returned unchanged except requested scripts | Pending KaspaCom backend txid |
| Account/network/balance/disconnect updates | Pass | Pass | Native events or bounded monitoring; stale-network browser test | Pending target app |
| Stale request rejection | Pass | Pass | Chromium mutation test and Android pre/post-approval binding | Pending target app |

Recommendation: **private pilot**. Change this to **list** only after every
`Pending` cell has a real evidence record and KaspaCom confirms the exact app
versions used.

## Reproducible local suite

Run from the repository root:

```bash
./scripts/kaspacom_conformance.sh
```

The browser smoke test loads the packaged Manifest V3 extension in Chromium,
creates and verifies a temporary wallet, approves a real injected-provider
connection, checks auth/public-key output, signs a normalized script-aware
PSKT, verifies SafeJSON preservation, switches to TN10, observes the network
event and proves that changing networks during approval rejects the stale
signature request.

## Collecting live evidence

Copy `evidence-template.json` once for every primitive and transport. Complete
it using the actual KCC20 or Kaspiano test environment. For a broadcast, include
the public TN10 transaction ID and whether the wallet or backend broadcast it.
For sign-only, store the redacted signed PSKT fixture separately. For events,
record the event name and non-secret payload.

Never store recovery phrases, private keys, wallet passwords, WalletConnect
pairing URIs, access tokens or API keys. After KaspaCom has accepted all TN10
records, repeat the minimum transaction subset with small values on the exact
production app version before Mainnet listing.
