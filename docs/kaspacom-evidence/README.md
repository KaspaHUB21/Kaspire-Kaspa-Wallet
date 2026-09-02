# KaspaCom compatibility evidence

This directory is the hand-off record required by the KaspaCom wallet-provider
guide dated 2026-08-23 and clarified directly by KaspaCom. The KCOM adapter is
not a public SDK or a Kaspire deliverable. KaspaCom builds that wallet-specific
integration layer privately after reviewing Kaspire's provider API.

The evidence is therefore collected in two distinct phases:

1. **Provider-native hand-off:** Kaspire supplies API documentation and
   reproducible evidence for its own extension and Android capabilities.
2. **Joint integration evidence:** after KaspaCom builds its private adapter,
   KaspaCom and Kaspire run the complete provider-plus-adapter tests in the
   current target applications.

## Scope

- Wallets: Kaspire Browser Extension 0.4.6 and Kaspire Android 0.11.28
- App surfaces: KaspaCom KCC20 and Kaspiano
- Networks: Testnet 10 private pilot, followed by a small-value Mainnet smoke
  test before public listing
- Broadcast mode: sign-only plus KaspaCom backend broadcast. Generic wallet
  PSKT broadcast is not advertised.

No KCOM adapter source is expected from Kaspire. KaspaCom's current KCC20 and
Kaspiano target builds and its internal Kasware/Kastle reference adapters are
private, so app-dependent checks remain pending until KaspaCom supplies a test
environment or runs them jointly. The legacy public `front-interface-v1` is
not a substitute for the target versions.

## Current matrix

| Primitive | Extension | Android | Kaspire-native evidence | Joint KaspaCom evidence |
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

Provider hand-off status: **ready for KaspaCom review**. Listing status remains
**private pilot** until KaspaCom has built its internal adapter and every
`Pending` joint-evidence cell has a real record tied to exact app and adapter
versions.

## Provider hand-off package

Send KaspaCom these repository files:

- [`../KASPACOM_PROVIDER.md`](../KASPACOM_PROVIDER.md): exact extension and
  Android methods, schemas, network labels, events, signing behavior and
  security constraints;
- [`../examples/kaspire-provider-client.ts`](../examples/kaspire-provider-client.ts):
  non-adapter provider-consumer example;
- [`provider-native-evidence.md`](provider-native-evidence.md): versioned native
  capability evidence and exact test/source mapping;
- this capability matrix and the output of `./scripts/kaspacom_conformance.sh`;
- redacted request/response fixtures requested during KaspaCom's review.

Do not describe the example as a KCOM adapter. KaspaCom owns the production
adapter and decides how to normalize provider-native units, events and errors
inside its applications.

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

## Collecting joint live evidence

After KaspaCom has implemented its adapter, copy `evidence-template.json` once
for every primitive and transport. Complete it using the actual KCC20 or
Kaspiano test environment and record the KaspaCom adapter/app version. For a
broadcast, include the public TN10 transaction ID and whether the wallet or
backend broadcast it. For sign-only, store the redacted signed PSKT fixture
separately. For events, record the event name and non-secret payload.

Never store recovery phrases, private keys, wallet passwords, WalletConnect
pairing URIs, access tokens or API keys. After KaspaCom has accepted all TN10
records, repeat the minimum transaction subset with small values on the exact
production app version before Mainnet listing.
