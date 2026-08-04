import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Kaspire Mobile Developer Guide | WalletConnect for Kaspa dApps",
  description:
    "Integrate Kaspire with a website using WalletConnect v2 for accounts, signatures, KAS, tokens, generic PSKT flows, and vault transactions.",
};

const installCode = `npm install @walletconnect/sign-client`;

const initializeCode = `import SignClient from "@walletconnect/sign-client";

const signClient = await SignClient.init({
  projectId: import.meta.env.VITE_REOWN_PROJECT_ID,
  metadata: {
    name: "Example Kaspa dApp",
    description: "Connect to Kaspire",
    url: window.location.origin,
    icons: [window.location.origin + "/icon.png"]
  }
});`;

const connectCode = `const { uri, approval } = await signClient.connect({
  requiredNamespaces: {
    kaspa: {
      chains: ["kaspa:mainnet"],
      methods: [
        "kaspa_getAccounts",
        "kaspa_signPersonal",
        "kaspa_sendTransaction",
        "kaspa_sendKrc20",
        "kaspa_sendKcc20",
        "kaspa_signPskt",
        "kaspa_signVaultTransaction"
      ],
      events: ["accountsChanged"]
    }
  }
});

if (!uri) throw new Error("WalletConnect did not return a pairing URI");

// Important: use this HTTPS App Link as the QR payload.
// Do not put the raw wc: URI into the Kaspire QR code.
const kaspireLink =
  "https://kaspire.kaslab.space/kaspire/wc?uri=" +
  encodeURIComponent(uri);
const kaspireIntent =
  "intent://wc?uri=" + encodeURIComponent(uri) +
  "#Intent;scheme=kaspire;package=space.kaspire.wallet;" +
  "S.browser_fallback_url=" + encodeURIComponent(kaspireLink) + ";end";

if (/Android/i.test(navigator.userAgent)) {
  window.location.assign(kaspireIntent);
} else {
  renderKaspireQrCode(kaspireLink);
}

const session = await approval();`;

const restoreCode = `const sessions = signClient.session.getAll();
const session = sessions.find(
  item => item.namespaces.kaspa?.accounts?.length
);

const caip10 = session?.namespaces.kaspa.accounts[0];
// kaspa:mainnet:q...
const address = caip10
  ? "kaspa:" + caip10.split(":").slice(2).join(":")
  : null;`;

const accountsCode = `const accounts = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_getAccounts",
    params: {}
  }
});
// ["kaspa:q..."]`;

const signCode = `const message = [
  "Sign in to Example dApp",
  "Domain: example.com",
  "Address: " + address,
  "Nonce: " + serverNonce,
  "Issued At: " + new Date().toISOString(),
  "Expiration Time: " + expiresAt
].join("\\n");

const signature = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_signPersonal",
    params: { address, message }
  }
});`;

const kasCode = `const transactionId = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_sendTransaction",
    params: {
      from: address,
      to: "kaspa:q...",
      amountSompi: "100000000"
    }
  }
});`;

const krc20Code = `const result = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_sendKrc20",
    params: {
      from: address,
      to: "kaspa:q...",
      ticker: "SOULS",
      amount: "100000000"
    }
  }
});

// result:
// {
//   ticker, amount,
//   commitTransactionId, revealTransactionId,
//   commitFeeSompi, revealFeeSompi
// }`;

const kcc20Code = `const result = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_sendKcc20",
    params: {
      from: address,
      to: "kaspa:q...",
      covenantId: "64 lowercase hexadecimal characters",
      amount: "100000000"
    }
  }
});

// result:
// {
//   transactionId, covenantId, ticker, amount,
//   feeSompi, mass, validation: "toccata-node"
// }`;

const vaultCode = `const result = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_signVaultTransaction",
    params: {
      txJsonString: draft.txJson,
      signInputIndexes: [0, 1],
      redeemScript: draft.redeemScript
    }
  }
});

// result: { signedTxJson, profile, reviewHash }
// Creation profiles use signInputIndexes: [0] and redeemScript: "".
// Heartbeats must use exactly [0, 1] and the covenant redeem script.`;

const psktCode = `const signedTxJson = await signClient.request({
  topic: session.topic,
  chainId: "kaspa:mainnet",
  request: {
    method: "kaspa_signPskt",
    params: {
      txJsonString: draft.txJson,
      options: {
        signInputs: [
          { index: 0, sighashType: 1 } // SIGHASH_ALL
        ]
      }
    }
  }
});

// Kaspire returns the signed SafeJSON string.
// Your dApp finalizes or combines the PSKT and decides when to broadcast.`;

const eventsCode = `signClient.on("session_event", ({ params }) => {
  if (params.event.name === "accountsChanged") {
    const accounts = params.event.data;
    // Update the selected account in your application.
  }
});

signClient.on("session_delete", ({ topic }) => {
  // Clear local UI state for this topic.
});`;

function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="developer-code">
      <code>{children}</code>
    </pre>
  );
}

export default function DevelopersPage() {
  return (
    <>
      <a className="skip-link" href="#developer-guide">
        Skip to guide
      </a>
      <header className="site-header article-header">
        <div className="shell header-inner">
          <a className="header-brand" href="/" aria-label="Kaspire home">
            <img className="header-brand-symbol" src="/kaspire-logo.png" alt="" />
            <img className="header-brand-wordmark" src="/kaspire-wordmark.png" alt="Kaspire" />
          </a>
          <nav aria-label="Developer guide navigation">
            <a href="/developers/extension">Extension guide</a>
            <a href="#quick-start">Quick start</a>
            <a href="#desktop-qr">Desktop QR</a>
            <a href="#methods">Methods</a>
            <a href="#security-checklist">Security</a>
          </nav>
          <a className="header-download" href="/">Back home</a>
        </div>
      </header>

      <main id="developer-guide" className="developer-page">
        <section className="developer-hero">
          <div className="shell developer-hero-inner">
            <p className="kicker">Kaspire Mobile · WalletConnect v2 · Kaspa Mainnet</p>
            <h1>Connect to Kaspire Mobile.</h1>
            <p>
              Connect websites to a selected Kaspire account through an encrypted
              WalletConnect v2 session. Request accounts, KIP-5 signatures, KAS
              payments, token transfers, and reviewed PSKT marketplace or
              covenant flows without exposing private keys to the browser.
            </p>
            <div className="article-meta">
              <span>Android App Link</span><span>WalletConnect v2</span>
              <span>Explicit approval</span><span>Raw integer amounts</span>
            </div>
            <div className="developer-guide-switch" aria-label="Choose a Kaspire integration">
              <a className="active" href="/developers">
                <span>Android app</span>
                <strong>Kaspire Mobile</strong>
                <small>WalletConnect, App Links and desktop QR pairing</small>
              </a>
              <a href="/developers/extension">
                <span>Chrome extension</span>
                <strong>Kaspire Extension</strong>
                <small>Injected window.kaspire browser provider</small>
              </a>
            </div>
          </div>
        </section>

        <div className="shell developer-layout">
          <aside className="developer-toc" aria-label="On this page">
            <strong>On this page</strong>
            <a href="#requirements">Requirements</a>
            <a href="#quick-start">Quick start</a>
            <a href="#desktop-qr">Desktop QR and Android</a>
            <a href="#sessions">Sessions and accounts</a>
            <a href="#methods">RPC methods</a>
            <a href="#responses">Amounts and responses</a>
            <a href="#errors">Errors</a>
            <a href="#security-checklist">Security checklist</a>
            <a href="#testing">Testing</a>
          </aside>

          <article className="developer-content">
            <section id="requirements">
              <span className="developer-label">01 / Requirements</span>
              <h2>What your project needs</h2>
              <p>
                Create a Reown project ID, allowlist every production origin,
                and initialize a WalletConnect-compatible SignClient. Kaspire
                currently supports Android and Kaspa Mainnet only.
              </p>
              <ul>
                <li>A Reown project ID with your website origins allowlisted</li>
                <li>WalletConnect v2 using the <code>irn</code> relay</li>
                <li>A dedicated Kaspire QR-code view for desktop visitors</li>
                <li>The explicit Kaspire Android intent with the verified HTTPS fallback</li>
              </ul>
              <CodeBlock>{installCode}</CodeBlock>
              <p>
                The project ID is public application configuration. Pairing URIs
                are secrets and must never be logged, persisted, placed in
                analytics, or sent to unrelated services.
              </p>
            </section>

            <section id="quick-start">
              <span className="developer-label">02 / Quick start</span>
              <h2>Initialize and connect</h2>
              <CodeBlock>{initializeCode}</CodeBlock>
              <p>
                Request only the methods your dApp really uses. A sign-in-only
                integration should request only <code>kaspa_getAccounts</code>{" "}
                and <code>kaspa_signPersonal</code>.
              </p>
              <CodeBlock>{connectCode}</CodeBlock>
            </section>

            <section id="desktop-qr">
              <span className="developer-label">03 / Desktop QR and Android</span>
              <h2>Do not use the generic wallet QR for Kaspire</h2>
              <p>
                Kaspire accepts WalletConnect v2 pairings. However, a generic
                WalletConnect modal commonly puts the raw <code>wc:</code> URI
                in its QR code or sends the user to Reown&apos;s wallet-selection
                screen after scanning.
              </p>
              <p>
                Kaspire is not currently registered in the Reown WalletGuide.
                The generic picker can therefore offer MetaMask and other listed
                wallets without showing Kaspire, even when Kaspire is installed.
                This is expected and does not indicate an installation problem.
              </p>
              <div className="developer-note developer-note-emphasis">
                <strong>Required Kaspire QR payload</strong>
                <code>
                  https://kaspire.kaslab.space/kaspire/wc?uri=&lt;URL-ENCODED-WALLETCONNECT-URI&gt;
                </code>
                <p>
                  Provide a dedicated <strong>Connect with Kaspire</strong>{" "}
                  button. On desktop, encode this complete HTTPS link in your QR
                  code. On Android, open the explicit <code>intent://wc</code> URL shown in the quick start so the installed app wins; keep the verified HTTPS link as its browser fallback. Never encode
                  only the raw <code>wc:</code> URI in the Kaspire QR code.
                </p>
              </div>
              <CodeBlock>{connectCode}</CodeBlock>
              <div className="developer-pairing-flow" aria-label="Kaspire pairing flow">
                <span>QR code</span>
                <b aria-hidden="true">→</b>
                <span>Verified Kaspire App Link</span>
                <b aria-hidden="true">→</b>
                <span>Android opens Kaspire</span>
                <b aria-hidden="true">→</b>
                <span>Kaspire processes the wc: URI</span>
                <b aria-hidden="true">→</b>
                <span>“Connect dApp?” approval</span>
              </div>
              <p>
                If Kaspire is not installed, Android opens the HTTPS fallback
                page instead. That page links to the current official APK. After
                installation, the user should return to the dApp and generate a
                new pairing QR code.
              </p>
              <p>
                If your dApp also supports other WalletConnect wallets, expose a
                separate <strong>Other WalletConnect wallets</strong> action for
                the generic Reown modal.
              </p>
              <div className="developer-note">
                <strong>Canonical launch URL</strong>
                <code>
                  https://kaspire.kaslab.space/kaspire/wc?uri=&lt;encoded wc: URI&gt;
                </code>
                <p>
                  The legacy <code>kaslab.space/kaspire/wc</code> route remains
                  accepted for existing integrations. New integrations should
                  always use the canonical Kaspire subdomain.
                </p>
              </div>
            </section>

            <section id="sessions">
              <span className="developer-label">04 / Sessions</span>
              <h2>Restore the selected account</h2>
              <p>
                Kaspire publishes the account as CAIP-10:
                <code> kaspa:mainnet:q...</code>. RPC results return the normal
                full address <code>kaspa:q...</code>.
              </p>
              <div className="developer-note">
                <strong>Accounts versus subwallets</strong>
                <p>
                  A selected address may be the first address of a BIP-44
                  account, such as <code>m/44&apos;/111111&apos;/1&apos;/0/0</code>,
                  or an address-index subwallet such as
                  <code> m/44&apos;/111111&apos;/0&apos;/0/2</code>. Treat the
                  returned Kaspa address as the authoritative opaque account
                  identifier. Never infer or request a derivation path, and
                  update your UI when Kaspire emits <code>accountsChanged</code>.
                </p>
              </div>
              <CodeBlock>{restoreCode}</CodeBlock>
              <CodeBlock>{accountsCode}</CodeBlock>
              <CodeBlock>{eventsCode}</CodeBlock>
            </section>

            <section id="methods">
              <span className="developer-label">05 / Methods</span>
              <h2>Supported JSON-RPC requests</h2>
              <div className="developer-methods">
                <div><code>kaspa_getAccounts</code><p>Returns the approved full Kaspa address.</p></div>
                <div><code>kaspa_signPersonal</code><p>Creates a user-approved KIP-5 personal-message signature.</p></div>
                <div><code>kaspa_sendTransaction</code><p>Builds, reviews, signs, and broadcasts a native KAS payment.</p></div>
                <div><code>kaspa_sendKrc20</code><p>Executes the complete KRC-20 commit/reveal transfer flow.</p></div>
                <div><code>kaspa_sendKcc20</code><p>Validates and executes a typed KCC20 covenant transfer.</p></div>
                <div><code>kaspa_signPskt</code><p>Signs selected inputs of a fully reviewed Kaspa SafeJSON transaction.</p></div>
                <div><code>kaspa_signVaultTransaction</code><p>Signs only a native Rust policy-approved vault create or DMS heartbeat transaction.</p></div>
              </div>

              <h3>KIP-5 sign-in</h3>
              <CodeBlock>{signCode}</CodeBlock>
              <p>
                Generate the nonce on your server, bind it to the intended
                domain and address, verify the KIP-5 signature server-side, and
                consume the nonce exactly once.
              </p>
              <h3>Native KAS</h3>
              <CodeBlock>{kasCode}</CodeBlock>
              <h3>KRC-20</h3>
              <CodeBlock>{krc20Code}</CodeBlock>
              <p>
                Commit and reveal require two authorization steps. Keep the
                request pending while Kaspire waits for the commit output. A
                delayed reveal can be resumed safely inside Kaspire.
              </p>
              <h3>KCC20</h3>
              <CodeBlock>{kcc20Code}</CodeBlock>
              <p>
                Identify KCC20 assets by their complete covenant ID—not by
                ticker. Kaspire accepts only a verified balance with a complete
                live-cell mapping and reconstructs the covenant transition
                locally before signing.
              </p>
              <h3>Generic PSKT: marketplaces, KRC-721, KNS and covenants</h3>
              <CodeBlock>{psktCode}</CodeBlock>
              <p>
                Use <code>kaspa_signPskt</code> when your dApp has already
                constructed a Kaspa transaction and needs Kaspire to sign only
                specified inputs. This method is dApp-independent: no
                KaspaCom-specific, marketplace-specific, or vault-specific
                cooperation is required. It supports transaction versions 0
                and 1 and sighash values <code>1</code>, <code>2</code>,
                <code>4</code>, <code>129</code>, <code>130</code>, and
                <code>132</code>.
              </p>
              <div className="developer-note developer-note-emphasis">
                <strong>Not a blind signer</strong>
                <p>
                  Kaspire&apos;s native Rust core parses the SafeJSON and every
                  embedded UTXO, rejects duplicate outpoints and inconsistent
                  fields, calculates the fee and wallet net effect, and binds
                  all inputs, outputs, payload, covenant bindings and selected
                  sighashes to the approval. The wallet displays every output
                  and warns for partial signatures, non-standard scripts, and
                  mutable sighashes. It signs only the requested inputs and
                  never broadcasts automatically.
                </p>
                <p>
                  Kaspire guarantees that the displayed transaction is the one
                  signed. It cannot certify your dApp&apos;s marketplace price,
                  royalty policy, listing semantics, or covenant intent.
                  Reown&apos;s verified domain is anti-phishing context, not a
                  substitute for user review.
                </p>
              </div>
              <h3>Vault policy transactions</h3>
              <CodeBlock>{vaultCode}</CodeBlock>
              <p>
                This is an optional stricter profile for the version-2 KasLab
                time-lock create, DMS create, and DMS heartbeat flows. Other
                dApps should use <code>kaspa_signPskt</code>; they do not need a
                dedicated Kaspire policy.
              </p>
            </section>

            <section id="responses">
              <span className="developer-label">06 / Data rules</span>
              <h2>Amounts, addresses, and responses</h2>
              <ul>
                <li>Send integer strings, never floating-point values. One KAS is <code>100000000</code> sompi.</li>
                <li>KRC-20 and KCC20 amounts are exact raw token units before applying token decimals.</li>
                <li>Recipient and optional <code>from</code> values must be full <code>kaspa:q...</code> Mainnet addresses.</li>
                <li>If supplied, <code>from</code> must exactly match the account approved for the session.</li>
                <li>Do not treat human-readable ticker or metadata as asset identity. Use the covenant ID for KCC20.</li>
              </ul>
            </section>

            <section id="errors">
              <span className="developer-label">07 / Errors</span>
              <h2>Handle rejection without retry loops</h2>
              <div className="developer-error-table">
                <div><code>4001</code><span>User rejected the request</span></div>
                <div><code>-32600</code><span>Duplicate or malformed request</span></div>
                <div><code>-32601</code><span>Unsupported method or chain</span></div>
                <div><code>-32602</code><span>Invalid session account</span></div>
                <div><code>-32000</code><span>Request failed safely in Kaspire</span></div>
                <div><code>5000</code><span>Session proposal rejected</span></div>
                <div><code>6000</code><span>Session disconnected</span></div>
              </div>
              <p>
                Never automatically resubmit a rejected payment or signature.
                Show a clear status, let the user correct the request, and
                require a new deliberate action.
              </p>
            </section>

            <section id="security-checklist">
              <span className="developer-label">08 / Security</span>
              <h2>Production checklist</h2>
              <ul className="developer-checklist">
                <li>Allowlist every legitimate production origin in Reown.</li>
                <li>Request the minimum methods required by the current flow.</li>
                <li>Never log or persist a <code>wc:</code> pairing URI.</li>
                <li>Percent-encode the entire URI exactly once in the App Link.</li>
                <li>Use a server nonce with expiry and one-time consumption for login.</li>
                <li>Verify KIP-5 signatures on the server before creating a session.</li>
                <li>Represent every amount as a base-10 integer string.</li>
                <li>Bind UI state to the WalletConnect topic and approved account.</li>
                <li>Clear local connection state on session deletion or expiry.</li>
                <li>Never infer successful payment before receiving the RPC result.</li>
              </ul>
            </section>

            <section id="testing">
              <span className="developer-label">09 / Testing</span>
              <h2>Test the unhappy paths</h2>
              <p>
                Begin with a low-value Mainnet wallet. Test approval, rejection,
                app switching, expired pairings, disconnected sessions,
                insufficient funds, malformed addresses, unsupported methods,
                duplicate requests, interrupted KRC-20 reveal, and background
                return to the browser.
              </p>
              <p>
                Kaspa does not currently define an official WalletConnect
                namespace for these methods. The API on this page is Kaspire
                protocol v2 and should be version-pinned in your integration.
              </p>
              <div className="developer-links">
                <a href="https://docs.reown.com/advanced/api/sign/dapp-usage">Reown SignClient documentation</a>
                <a href="/security/inside-kaspire">Kaspire security architecture</a>
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
            <a href="/">Home</a><a href="/#security">Security</a>
            <a href="/#download">Download</a><a href="/developers">For Developers</a>
            <a href="/privacy">Privacy</a>
            <a href="https://kaslab.space">HUB21</a>
          </div>
        </div>
      </footer>
    </>
  );
}
