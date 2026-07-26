# @kaspire/connect

Typed helpers for Kaspire protocol v2 over an existing WalletConnect SignClient
session.

```ts
import {
  KaspireProvider,
  kaspirePairingLink,
  walletConnectTransport,
} from "@kaspire/connect";

const { uri, approval } = await signClient.connect({
  requiredNamespaces: {
    kaspa: {
      chains: ["kaspa:mainnet"],
      methods: ["kaspa_getAccounts", "kaspa_sendTransaction"],
      events: ["accountsChanged"],
    },
  },
});

if (uri) window.location.assign(kaspirePairingLink(uri));
const session = await approval();
const caip10 = session.namespaces.kaspa.accounts[0];
const address = `kaspa:${caip10.split(":").slice(2).join(":")}`;
const provider = new KaspireProvider(
  walletConnectTransport(signClient, session.topic),
  address,
);

await provider.sendKaspa("kaspa:q...", 100_000_000n);
```

Pairing URIs are secrets. Never log, persist, or send them to analytics.
