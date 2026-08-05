import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Kaspire Extension Developer Guide | Kaspa Browser Provider",
  description:
    "Integrate Kaspa dApps with the Kaspire browser extension through window.kaspire for accounts, KIP-5, KAS, assets, PSKT and policy transactions.",
};

const detectCode = `function detectKaspire(timeoutMs = 3000) {
  if (window.kaspire?.isKaspire) return Promise.resolve(window.kaspire);

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Kaspire Extension was not detected.")),
      timeoutMs
    );
    window.addEventListener("kaspire#initialized", () => {
      clearTimeout(timeout);
      resolve(window.kaspire);
    }, { once: true });
  });
}

const kaspire = await detectKaspire();`;

const typesCode = `type KaspireError = Error & { code?: number };

interface KaspireProvider {
  readonly isKaspire: true;
  readonly version: string;
  request<T = unknown>(input: {
    method: string;
    params?: unknown;
  }): Promise<T>;
  on(event: "accountsChanged" | "networkChanged" | "disconnect",
     listener: (data: unknown) => void): this;
  removeListener(event: string, listener: (data: unknown) => void): this;
}`;

const connectCode = `const accounts = await kaspire.request<string[]>({
  method: "requestAccounts"
});

// The user reviews the requesting origin in an extension-owned window.
const address = accounts[0]; // full kaspa:q... address
if (!address) throw new Error("No Kaspire account was approved.");`;

const restoreCode = `const accounts = await kaspire.request<string[]>({
  method: "getAccounts"
});

if (accounts.length === 0) {
  // This origin is not connected. Show a Connect Kaspire button.
}

const network = await kaspire.request<string>({ method: "getNetwork" });
// Kaspire Extension 0.3.17 is Mainnet-only: network === "mainnet"`;

const eventsCode = `const onAccounts = (accounts) => {
  selectedAddress = accounts[0] ?? null;
  renderWalletState();
};

kaspire.on("accountsChanged", onAccounts);
kaspire.on("disconnect", () => {
  selectedAddress = null;
  renderDisconnectedState();
});

// When your component unmounts:
kaspire.removeListener("accountsChanged", onAccounts);`;

const readsCode = `const publicKey = await kaspire.request<string>({
  method: "getPublicKey"
});

const snapshot = await kaspire.request({ method: "getBalance" });
// {
//   balanceSompi, balanceKas, utxoCount, utxos,
//   assets: { tokens, domains, krc721, kcc20, transactions },
//   transactions
// }

const utxos = await kaspire.request({ method: "getUtxoEntries" });`;

const signCode = `const result = await kaspire.request<{
  address: string;
  signature: string;
}>({
  method: "signMessage",
  params: {
    address,
    message: [
      "Sign in to Example dApp",
      "Domain: " + location.host,
      "Address: " + address,
      "Nonce: " + serverNonce,
      "Issued At: " + new Date().toISOString()
    ].join("\\n")
  }
});`;

const kasCode = `const transactionId = await kaspire.request<string>({
  method: "sendKaspa",
  params: {
    from: address,
    to: "kaspa:q...",
    amountSompi: "100000000"
  }
});`;

const krc20Code = `const result = await kaspire.request({
  method: "sendKRC20",
  params: {
    from: address,
    to: "kaspa:q...",
    ticker: "KASBTC",
    amount: "100000000"
  }
});

// {
//   kind: "krc20", commitTransactionId, revealTransactionId,
//   commitFeeSompi, revealFeeSompi
// }`;

const nftCode = `const nft = await kaspire.request({
  method: "transferKRC721",
  params: {
    from: address,
    to: "kaspa:q...",
    ticker: "COLLECTION",
    tokenId: "the exact owned token ID"
  }
});

const name = await kaspire.request({
  method: "transferKNS",
  params: {
    from: address,
    to: "kaspa:q...",
    assetId: "64 lowercase hexadecimal characters followed by i0"
  }
});`;

const kcc20Code = `const transactionId = await kaspire.request<string>({
  method: "sendKCC20",
  params: {
    from: address,
    to: "kaspa:q...",
    covenantId: "64 lowercase hexadecimal characters",
    amount: "100000000"
  }
});

// The same method supports verified legacy KCC20 and KRON-native tokens.
// Kaspire discovers the standard from the covenant ID; never trust a ticker
// supplied by the dApp as the asset identity.`;

const psktCode = `const signedTxJson = await kaspire.request<string>({
  method: "signPskt",
  params: {
    sender: address,
    txJsonString: draft.txJson,
    options: {
      signInputs: [
        { index: 0, sighashType: 1 } // SIGHASH_ALL
      ]
    }
  }
});

// Kaspire signs only the reviewed input set. Your dApp may combine/finalize
// the PSKT and deliberately request broadcast afterwards.`;

const policyCode = `const signed = await kaspire.request({
  method: "signPolicyTransaction",
  params: {
    sender: address,
    txJsonString: draft.txJson,
    signInputIndexes: [0, 1],
    redeemScript: draft.redeemScript
  }
});
// { signedTxJson, profile, reviewHash }

const transactionId = await kaspire.request<string>({
  method: "pushTx",
  params: signed.signedTxJson
});`;

const disconnectCode = `await kaspire.request({ method: "disconnect" });
// The extension removes the permission for this exact origin and emits
// accountsChanged([]) plus disconnect to the page.`;

const errorCode = `try {
  await kaspire.request({ method: "sendKaspa", params });
} catch (error) {
  const failure = error as KaspireError;
  if (failure.code === 4001) {
    showStatus("Request rejected by the user.");
  } else if (failure.code === 4100) {
    showStatus("Connect or unlock Kaspire first.");
  } else {
    showStatus(failure.message);
  }
}`;

function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="developer-code">
      <code>{children}</code>
    </pre>
  );
}

export default function ExtensionDevelopersPage() {
  return (
    <>
      <a className="skip-link" href="#extension-guide">Skip to guide</a>
      <header className="site-header article-header">
        <div className="shell header-inner">
          <a className="header-brand" href="/" aria-label="Kaspire home">
            <img className="header-brand-symbol" src="/kaspire-logo.png" alt="" />
            <img className="header-brand-wordmark" src="/kaspire-wordmark.png" alt="Kaspire" />
          </a>
          <nav aria-label="Extension guide navigation">
            <a href="/developers">Mobile guide</a>
            <a href="#quick-start">Quick start</a>
            <a href="#methods">Methods</a>
            <a href="#security">Security</a>
          </nav>
          <a className="header-download" href="/">Back home</a>
        </div>
      </header>

      <main id="extension-guide" className="developer-page">
        <section className="developer-hero">
          <div className="shell developer-hero-inner">
            <p className="kicker">Kaspire Extension provider v1 · Kaspa Mainnet</p>
            <h1>Connect to Kaspire Extension.</h1>
            <p>
              Use the injected <code>window.kaspire</code> provider for direct,
              origin-bound browser connections. No WalletConnect project,
              pairing URI, QR code, relay, or mobile handoff is required.
            </p>
            <div className="article-meta">
              <span>Manifest V3</span><span>window.kaspire</span>
              <span>Origin-bound approval</span><span>Native Rust via WASM</span>
            </div>
            <div className="developer-guide-switch" aria-label="Choose a Kaspire integration">
              <a href="/developers">
                <span>Android app</span>
                <strong>Kaspire Mobile</strong>
                <small>WalletConnect, App Links and desktop QR pairing</small>
              </a>
              <a className="active" href="/developers/extension">
                <span>Chrome extension</span>
                <strong>Kaspire Extension</strong>
                <small>Injected window.kaspire browser provider</small>
              </a>
            </div>
          </div>
        </section>

        <div className="shell developer-layout">
          <aside className="developer-toc" aria-label="On this page">
            <strong>Extension guide</strong>
            <a href="#choose">Choose the right integration</a>
            <a href="#quick-start">Detect and connect</a>
            <a href="#sessions">Permissions and events</a>
            <a href="#methods">Provider methods</a>
            <a href="#assets">Asset transfers</a>
            <a href="#pskt">PSKT and policies</a>
            <a href="#errors">Errors</a>
            <a href="#security">Security checklist</a>
            <a href="#testing">Testing</a>
          </aside>

          <article className="developer-content">
            <section id="choose">
              <span className="developer-label">01 / Architecture</span>
              <h2>Extension and Mobile are separate transports</h2>
              <p>
                Choose the Extension provider when the dApp and wallet run in
                the same desktop browser. Choose Kaspire Mobile when an Android
                wallet connects to a mobile or desktop website through an
                encrypted WalletConnect session. A dApp may offer both buttons.
              </p>
              <div className="developer-methods">
                <div><code>Kaspire Extension</code><p>Detect <code>window.kaspire</code>, call the provider, and receive origin-scoped approval.</p></div>
                <div><code>Kaspire Mobile</code><p>Create WalletConnect v2 sessions and use the verified Kaspire App Link or desktop QR flow.</p></div>
              </div>
              <div className="developer-note developer-note-emphasis">
                <strong>Do not use WalletConnect for the extension</strong>
                <p>
                  The browser extension has its own provider. Do not generate a
                  <code>wc:</code> URI, show a QR code, or redirect to the mobile
                  download page when <code>window.kaspire?.isKaspire</code> is
                  available.
                </p>
              </div>
            </section>

            <section id="quick-start">
              <span className="developer-label">02 / Quick start</span>
              <h2>Detect the provider and request an account</h2>
              <p>
                Kaspire injects the provider at document start. Check the
                property immediately and also listen for
                <code> kaspire#initialized</code> so asynchronous page bundles
                work consistently.
              </p>
              <CodeBlock>{detectCode}</CodeBlock>
              <CodeBlock>{typesCode}</CodeBlock>
              <CodeBlock>{connectCode}</CodeBlock>
              <p>
                Call <code>requestAccounts</code> only after the user clicks a
                visible “Connect Kaspire Extension” button. Kaspire opens an
                extension-owned approval window showing the exact requesting
                origin and selected public address.
              </p>
            </section>

            <section id="sessions">
              <span className="developer-label">03 / Connections</span>
              <h2>Restore permission and follow wallet changes</h2>
              <p>
                Permissions are scoped to the exact origin. Subdomains, ports,
                HTTP and HTTPS origins are distinct. <code>getAccounts</code>
                never opens an approval window and returns an empty array when
                the current origin is disconnected.
              </p>
              <CodeBlock>{restoreCode}</CodeBlock>
              <CodeBlock>{eventsCode}</CodeBlock>
              <CodeBlock>{disconnectCode}</CodeBlock>
              <div className="developer-note">
                <strong>Addresses are opaque account identifiers</strong>
                <p>
                  The selected address may belong to a BIP-44 account or an
                  address-index subwallet. Never infer a derivation path. Always
                  use the returned full <code>kaspa:q...</code> address and
                  replace cached UI state after <code>accountsChanged</code>.
                </p>
              </div>
            </section>

            <section id="methods">
              <span className="developer-label">04 / Provider API</span>
              <h2>Supported methods</h2>
              <div className="developer-methods">
                <div><code>requestAccounts</code><p>Prompts the user and grants this origin access to the selected address.</p></div>
                <div><code>getAccounts</code><p>Returns the connected address or an empty array without prompting.</p></div>
                <div><code>getNetwork</code><p>Returns <code>mainnet</code> in the current store build.</p></div>
                <div><code>getPublicKey</code><p>Returns the selected signing wallet&apos;s x-only public key.</p></div>
                <div><code>getBalance</code><p>Returns verified KAS, UTXO, asset and activity snapshot data.</p></div>
                <div><code>getUtxoEntries</code><p>Returns live UTXOs for transaction builders.</p></div>
                <div><code>signMessage</code><p>Creates a reviewed KIP-5 personal-message signature.</p></div>
                <div><code>sendKaspa</code><p>Builds, reviews, signs and broadcasts a native KAS payment.</p></div>
                <div><code>sendKRC20</code><p>Performs the reviewed KRC-20 commit/reveal flow.</p></div>
                <div><code>transferKRC721</code><p>Transfers an exactly identified NFT owned by the selected wallet.</p></div>
                <div><code>transferKNS</code><p>Transfers an exactly identified KNS asset owned by the selected wallet.</p></div>
                <div><code>sendKCC20</code><p>Transfers verified legacy KCC20 or KRON-native covenant tokens.</p></div>
                <div><code>signPskt</code><p>Reviews SafeJSON and signs only the explicitly selected inputs.</p></div>
                <div><code>signPolicyTransaction</code><p>Uses the stricter native KasCoven create/heartbeat policy.</p></div>
                <div><code>pushTx</code><p>Broadcasts a complete signed SafeJSON transaction deliberately supplied by the dApp.</p></div>
                <div><code>disconnect</code><p>Revokes the current origin&apos;s connection.</p></div>
              </div>

              <h3>Read wallet state</h3>
              <CodeBlock>{readsCode}</CodeBlock>
              <p>
                Treat snapshot metadata as display data. Before signing, Kaspire
                independently reloads and validates the data required by the
                requested operation.
              </p>
              <h3>KIP-5 personal signatures</h3>
              <CodeBlock>{signCode}</CodeBlock>
              <p>
                Generate login nonces server-side, bind them to the domain and
                account, expire them quickly, verify the signature server-side,
                and consume each nonce exactly once.
              </p>
              <h3>Native KAS</h3>
              <CodeBlock>{kasCode}</CodeBlock>
            </section>

            <section id="assets">
              <span className="developer-label">05 / Assets</span>
              <h2>Use exact asset identifiers and raw units</h2>
              <p>
                Asset methods verify that the selected wallet owns enough of
                the requested asset. They open extension-owned reviews and never
                expose seed material to the dApp. Recipient values must be full
                Mainnet addresses; resolve a KNS recipient in your dApp before
                submitting the request.
              </p>
              <h3>KRC-20</h3>
              <CodeBlock>{krc20Code}</CodeBlock>
              <h3>KRC-721 and KNS</h3>
              <CodeBlock>{nftCode}</CodeBlock>
              <h3>Legacy KCC20 and KRON</h3>
              <CodeBlock>{kcc20Code}</CodeBlock>
              <ul>
                <li>Use base-10 integer strings representing raw token units.</li>
                <li>Use uppercase tickers where a ticker is required.</li>
                <li>Use the covenant ID—not a ticker—as KCC20/KRON identity.</li>
                <li>Do not infer completion until the provider promise resolves.</li>
                <li>KRC transfers require commit and reveal approvals and may remain pending while the commit confirms.</li>
              </ul>
            </section>

            <section id="pskt">
              <span className="developer-label">06 / Transaction builders</span>
              <h2>Generic PSKT, policies and broadcast</h2>
              <CodeBlock>{psktCode}</CodeBlock>
              <p>
                <code>signPskt</code> is dApp-independent and is the correct
                method for marketplaces, listings, purchases, KRC-721/KNS
                transaction builders and general covenant flows. Kaspire parses
                every embedded UTXO, rejects duplicate outpoints and inconsistent
                fields, calculates wallet effects and fees, shows every output,
                binds the review hash, and signs only the selected inputs.
              </p>
              <div className="developer-note developer-note-emphasis">
                <strong>Signing is not broadcasting</strong>
                <p>
                  <code>signPskt</code> returns signed SafeJSON but does not
                  broadcast it. This allows multisigner and marketplace flows
                  to combine signatures. Call <code>pushTx</code> only when your
                  protocol has a complete transaction and the user deliberately
                  initiated submission.
                </p>
              </div>
              <CodeBlock>{policyCode}</CodeBlock>
              <p>
                Use <code>signPolicyTransaction</code> only for the recognized
                KasCoven vault create and DMS heartbeat profiles. Other dApps
                should use generic <code>signPskt</code> rather than requesting a
                custom Kaspire-specific integration.
              </p>
            </section>

            <section id="errors">
              <span className="developer-label">07 / Errors</span>
              <h2>Handle rejection and locked state explicitly</h2>
              <div className="developer-error-table">
                <div><code>4001</code><span>User rejected the connection, signature or transaction</span></div>
                <div><code>4100</code><span>Origin not connected, wallet locked, unavailable or watch-only</span></div>
                <div><code>4200</code><span>Unsupported method, network or asset operation</span></div>
                <div><code>-32602</code><span>Malformed parameters, wrong account or invalid asset identifier</span></div>
                <div><code>-32000</code><span>Signing, verification or broadcast failed safely</span></div>
                <div><code>-32603</code><span>The extension background service could not complete the request</span></div>
              </div>
              <CodeBlock>{errorCode}</CodeBlock>
              <p>
                Never retry a signature or payment automatically. Keep a visible
                pending state while approval is open, clear it on rejection, and
                require a new user action for every retry. Provider requests may
                remain open for multi-step confirmation; use a six-minute UI
                timeout rather than a short HTTP-style timeout.
              </p>
            </section>

            <section id="security">
              <span className="developer-label">08 / Security</span>
              <h2>Production checklist</h2>
              <ul className="developer-checklist">
                <li>Offer separate “Kaspire Mobile” and “Kaspire Extension” buttons.</li>
                <li>Call <code>requestAccounts</code> only after a deliberate click.</li>
                <li>Never ask users to paste recovery phrases or private keys into a dApp.</li>
                <li>Never request a signature whose exact meaning is hidden from the user.</li>
                <li>Use server-generated, expiring, one-time nonces for authentication.</li>
                <li>Represent KAS and token amounts as base-10 raw integer strings.</li>
                <li>Validate addresses and asset identifiers before opening the wallet.</li>
                <li>Bind application state to the returned account and current origin.</li>
                <li>React to <code>accountsChanged</code> and <code>disconnect</code>.</li>
                <li>Do not treat a resolved promise as an on-chain confirmation unless the method documents broadcast.</li>
                <li>Do not automatically call <code>pushTx</code> after a generic PSKT signature unless that is the user-visible flow.</li>
              </ul>
              <p>
                Kaspire guarantees that its extension-owned review is bound to
                the locally reconstructed transaction. It cannot certify a
                dApp&apos;s marketplace price, royalty model, contract intent or
                business rules. The user must still verify the requesting domain
                and displayed transaction.
              </p>
            </section>

            <section id="testing">
              <span className="developer-label">09 / Testing</span>
              <h2>Test connection, approval and recovery paths</h2>
              <ul>
                <li>Extension missing, installed but locked, and watch-only wallet</li>
                <li>Connection approval and rejection for each production origin</li>
                <li>Wallet switching, account changes and explicit disconnect</li>
                <li>Malformed address, amount, covenant ID, NFT ID and KNS asset ID</li>
                <li>Insufficient KAS, token balance, fragmented UTXOs and indexer failure</li>
                <li>Rejected KRC commit, delayed commit confirmation and rejected/resumed reveal</li>
                <li>PSKT duplicate outpoints, wrong sender, mutable sighash warnings and partial signatures</li>
                <li>Background service-worker restart while a wallet session is unlocked</li>
                <li>Broadcast rejection and mismatching transaction IDs</li>
              </ul>
              <p>
                Start with a low-value Mainnet wallet. The current public
                extension is Mainnet-only even though reserved testnet plumbing
                remains in the source for future releases.
              </p>
              <div className="developer-links">
                <a href="https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/tree/main/apps/browser_extension">Extension source</a>
                <a href="/developers">Kaspire Mobile guide</a>
                <a href="/security/inside-kaspire">Security architecture</a>
                <a href="/privacy">Privacy policy</a>
              </div>
            </section>
          </article>
        </div>
      </main>

      <footer>
        <div className="shell footer-inner">
          <img src="/kaspire-wordmark.png" alt="Kaspire" />
          <p>Native self-custody for the Kaspa ecosystem.</p>
          <div>
            <a href="/">Home</a><a href="/developers">Mobile Guide</a>
            <a href="/developers/extension">Extension Guide</a>
            <a href="/privacy">Privacy</a><a href="https://kaslab.space">HUB21</a>
          </div>
        </div>
      </footer>
    </>
  );
}
