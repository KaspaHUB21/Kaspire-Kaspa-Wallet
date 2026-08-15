import DagField from "./dag-field";
import { currentRelease, extensionRelease } from "./release";

const downloadUrl =
  `https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v${currentRelease.version}/Kaspire-Android-mainnet-v${currentRelease.version}.apk`;
const extensionStoreUrl =
  "https://chromewebstore.google.com/detail/kaspire-wallet/ldjonnkfjmcingabncepnibledcanmoe";

const highlights = [
  {
    number: "01",
    title: "One wallet. Every L1 Kaspa asset.",
    copy: "Hold and move KAS, KRC20, KRC721, KNS and KCC20 covenant assets from one focused Android wallet or browser extension.",
    tags: ["KAS", "KRC-20", "KRC-721", "KNS", "KCC20"],
  },
  {
    number: "02",
    title: "Native signing, human review.",
    copy: "Transactions are reconstructed in a pinned Rust core. Recipient, value, change, fee, mass and token state are bound to what you approve.",
    tags: ["Rust core", "Review hash", "Fail closed"],
  },
  {
    number: "03",
    title: "Built for real wallet history.",
    copy: "A rich activity feed opens every transfer in-app with sender, recipient, asset data, fees, inputs, outputs, DAA score and transaction ID.",
    tags: ["Activity", "TX details", "Local node"],
  },
  {
    number: "04",
    title: "Connect without surrendering control.",
    copy: "Scan a dApp's WalletConnect QR code directly inside Kaspire, inspect its verified origin and permissions, and manage active encrypted sessions. Every signature still needs fresh approval.",
    tags: ["In-app QR pairing", "WalletConnect", "Per-request approval"],
  },
  {
    number: "05",
    title: "Accounts and subwallets that travel with your seed.",
    copy: "Modern and legacy BIP-44 discovery restores both separate accounts and KasWare-compatible address-index subwallets under one recovery phrase.",
    tags: ["111111", "Legacy 972", "Accounts", "Subwallets"],
  },
  {
    number: "06",
    title: "Keep UTXOs under control.",
    copy: "See your wallet's UTXO count and consolidate fragmented outputs through a reviewed, authenticated self-transfer.",
    tags: ["UTXO count", "Compound", "Fee preview"],
  },
  {
    number: "07",
    title: "Kaspa L2 networks, one familiar wallet.",
    copy: "Switch between Kaspa Mainnet, TN10, Kasplex and Igra while keeping the same wallet identity, receive flow, asset layout and native review model.",
    tags: ["Kasplex L2", "Igra L2", "EVM", "Native review"],
  },
];

const securityChapters = [
  {
    eyebrow: "01 / Keys",
    title: "Secure seed generation",
    body: (
      <>
        <p>
          New Kaspire wallets use 24-word English BIP-39 recovery phrases. A
          phrase represents 256 bits of entropy plus its BIP-39 checksum. The
          entropy is generated inside the shared Rust security core using the
          platform cryptographic random source: Android&apos;s operating-system
          CSPRNG in the app and Web Crypto in the browser extension—not
          timestamps, device IDs or application-level pseudo-random values.
        </p>
        <p>
          Before storage, Kaspire asks the user to verify randomly selected
          recovery words. Sensitive recovery screens use Android
          <code> FLAG_SECURE</code> to block normal screenshots and recent-app
          previews.
        </p>
      </>
    ),
  },
  {
    eyebrow: "02 / Recovery",
    title: "BIP-39 passphrases and HD compatibility",
    body: (
      <>
        <p>
          An optional BIP-39 passphrase becomes part of seed derivation and
          creates a completely different wallet. Kaspire follows the BIP-39
          standard with PBKDF2-HMAC-SHA512 and 2,048 iterations. Every
          character, space and capitalization choice matters.
        </p>
        <p>
          Modern accounts follow
          <code> m/44&apos;/111111&apos;/account&apos;/change/index</code>.
          Imports also discover legacy coin type <code>972</code>, receive and
          change branches, and multiple accounts. The Rust core supports
          account numbers 0 through 100.
        </p>
        <p>
          Kaspire keeps BIP-44 accounts and address-index subwallets distinct.
          For example, <code>…/0&apos;/0/1</code> is Subwallet 1 inside
          Account 0, while <code>…/1&apos;/0/0</code> is the first address of
          a separate Account 1. This restores the layout used by KasWare
          without silently changing derivation paths.
        </p>
      </>
    ),
  },
  {
    eyebrow: "03 / Storage",
    title: "Platform vault encryption",
    body: (
      <>
        <p>
          Every signing wallet is encrypted at rest with AES-256-GCM and a
          randomized initialization vector. In the Android app, the
          non-exportable wrapping key is generated in Android Keystore. On
          supported devices Kaspire first attempts StrongBox, then falls back
          to the device&apos;s secure Keystore implementation.
        </p>
        <p>
          The browser extension stores secrets in a versioned local vault
          protected by an Argon2id-derived key and AES-256-GCM. Decrypted vault
          material exists only in the extension&apos;s isolated session context
          while unlocked and is discarded on locking or browser-session end.
          AES-GCM authenticates as well as encrypts: modified ciphertext fails
          instead of silently yielding corrupted secrets.
        </p>
      </>
    ),
  },
  {
    eyebrow: "04 / Boundary",
    title: "Platform-specific secret boundaries",
    body: (
      <>
        <p>
          In the Android app, recovery phrases and private keys stay out of
          Dart, WebViews, analytics and the clipboard. Creation, import,
          encrypted storage, HD derivation and signing are handled by
          Android&apos;s native layer and the Rust core. Only public addresses and
          reviewed transaction data return to Flutter.
        </p>
        <p>
          In the extension, the encrypted vault and unlocked session are
          isolated inside extension-owned storage and background contexts;
          websites can reach only the bounded <code>window.kaspire</code>
          provider. Seed generation, derivation, transaction review and signing
          use the packaged Rust WebAssembly core. Neither platform exposes
          private keys or recovery phrases to dApps.
        </p>
      </>
    ),
  },
  {
    eyebrow: "05 / Approval",
    title: "Fresh authorization for value-moving actions",
    body: (
      <>
        <p>
          In the app, sending assets, compounding UTXOs, signing messages,
          importing, exporting or deleting wallets require fresh biometric or
          Kaspire PIN approval. In the extension, value-moving and signing
          requests open an extension-owned review and require the unlocked
          encrypted vault. Connecting a dApp never pre-authorizes a later
          transaction on either platform.
        </p>
        <p>
          The optional 4–8 digit PIN uses PBKDF2-HMAC-SHA256, a random salt and
          210,000 iterations. Repeated failures trigger an escalating temporary
          lockout. The PIN is an authorization verifier; Android Keystore
          remains responsible for seed encryption.
        </p>
      </>
    ),
  },
  {
    eyebrow: "06 / Signing",
    title: "Untrusted RPC, deterministic construction",
    body: (
      <>
        <p>
          Kaspire treats node and indexer responses as untrusted input. The
          Rust core verifies UTXO ownership, sender scripts, outpoints, amounts
          and coinbase state, then independently selects inputs, builds outputs
          and change, calculates mass and derives the fee.
        </p>
        <p>
          The server never chooses the final signed recipient output, change
          output or fee. Watch-only addresses remain isolated and can never
          silently fall back to another stored signing wallet.
        </p>
      </>
    ),
  },
  {
    eyebrow: "07 / Integrity",
    title: "Review-hash and transaction-ID binding",
    body: (
      <>
        <p>
          Preparation produces a canonical review containing network, sender,
          recipient, value, inputs, outputs, change, fee, mass, scripts,
          payload and token state. A SHA-256 review hash binds the user&apos;s
          approval to those exact fields.
        </p>
        <p>
          The signer reconstructs everything and rejects any mismatch. After
          broadcast, the node-returned transaction ID must equal the ID
          calculated locally from the signed transaction.
        </p>
      </>
    ),
  },
  {
    eyebrow: "08 / Protocols",
    title: "Typed token and covenant flows",
    body: (
      <>
        <p>
          KRC-20, KRC-721 and KNS operations use locally constructed canonical
          commit/reveal payloads with separate authorization. Reveal data is
          bound to the expected commit address, script, amount and outpoint.
        </p>
        <p>
          KCC20 is deliberately typed rather than generic. Kaspire requires
          verified discovery and complete live-cell mapping, recompiles the
          vendored SilverScript template, enforces token and KAS conservation,
          checks ownership transitions and Toccata limits, and executes every
          signed input locally before broadcast.
        </p>
      </>
    ),
  },
  {
    eyebrow: "09 / dApps",
    title: "Narrow dApp authority on mobile and desktop",
    body: (
      <>
        <p>
          Kaspire Mobile uses encrypted WalletConnect v2 sessions and advertises
          only a small, versioned Kaspa method set. The browser extension uses
          an origin-bound <code>window.kaspire</code> provider with an explicit,
          bounded method registry. Unknown methods, invalid chains,
          unauthorized origins and watch-only signing accounts are rejected.
        </p>
        <p>
          Mobile pairing topics are one-use and memory-only, pairing secrets are
          redacted, and results return through the encrypted session—not an
          arbitrary callback. Extension permissions are stored per exact web
          origin and can be disconnected independently. Personal signatures on
          both platforms follow KIP-5 and require fresh review.
        </p>
      </>
    ),
  },
  {
    eyebrow: "10 / Backups",
    title: "Memory-hard encrypted backups",
    body: (
      <>
        <p>
          New <code>kaspire-backup-v2</code> exports in the Android app and
          browser extension derive a 256-bit key with
          Argon2id v1.3, a random 32-byte salt, 32 MiB of memory, three passes
          and parallelism one. The backup is encrypted and authenticated with
          AES-256-GCM.
        </p>
        <p>
          Older PBKDF2-SHA256 backup-v1 files remain importable. Restore checks
          the format, exact KDF parameters, salt, GCM authentication, recovered
          address and every registered HD path before accepting the wallet.
        </p>
      </>
    ),
  },
  {
    eyebrow: "11 / Delivery",
    title: "Pinned packaged code and local infrastructure",
    body: (
      <>
        <p>
          The ARM64 and ARMv7 signing core is compiled into the Android app;
          the browser extension includes the corresponding Rust WebAssembly
          core inside its reviewed package. Both are pinned to Rusty Kaspa
          v2.0.1 and locked dependencies. The extension executes no remote code.
        </p>
        <p>
          Kaspire defaults to its own HTTPS gateway, pruned Kaspa node and local
          indexer infrastructure. Network timeouts are enforced, while all
          signing-relevant responses still pass local validation.
        </p>
      </>
    ),
  },
];

function ArrowIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M5 12h13M13 6l6 6-6 6" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 3v12m0 0 5-5m-5 5-5-5M5 21h14" />
    </svg>
  );
}

export default function Home() {
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="site-header">
        <div className="shell header-inner">
          <a className="header-brand" href="#top" aria-label="Kaspire home">
            <img
              className="header-brand-symbol"
              src="/kaspire-logo.png"
              alt=""
            />
            <img
              className="header-brand-wordmark"
              src="/kaspire-wordmark.png"
              alt="Kaspire"
            />
          </a>
          <nav aria-label="Main navigation">
            <a href="#features">Features</a>
            <a href="#security">Security</a>
            <a href="#download">Download</a>
            <a href="/developers">For Developers</a>
            <a
              href="https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet"
              target="_blank"
              rel="noreferrer"
            >
              GitHub
            </a>
          </nav>
          <a className="header-download" href="#download">
            Download
          </a>
          <details className="mobile-menu">
            <summary aria-label="Open navigation menu">
              <span />
              <span />
              <span />
            </summary>
            <div>
              <a href="#features">Features</a>
              <a href="#security">Security</a>
              <a href="#download">Download</a>
              <a href="/developers">For Developers</a>
              <a
                href="https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet"
                target="_blank"
                rel="noreferrer"
              >
                GitHub
              </a>
            </div>
          </details>
        </div>
      </header>

      <main id="main">
        <section className="hero" id="top">
          <DagField />
          <div className="hero-orbit hero-orbit-one" />
          <div className="hero-orbit hero-orbit-two" />
          <div className="shell hero-layout">
            <div className="hero-copy">
              <div className="status-pill">
                <span />
                Android app + browser extension · L1 + L2
              </div>
              <div className="hero-brand" aria-label="Kaspire">
                <img
                  className="hero-brand-symbol"
                  src="/kaspire-logo.png"
                  alt=""
                />
                <img
                  className="hero-wordmark"
                  src="/kaspire-wordmark.png"
                  alt="Kaspire"
                />
              </div>
              <h1>Your Kaspa universe. One secure wallet.</h1>
              <p>
                The Kaspa wallet that makes no compromises. Designed from the
                ground up for security and usability, Kaspire gives you complete
                control over your assets while supporting everything the Kaspa
                ecosystem has to offer. Kaspire is the first covenant-ready
                Kaspa wallet to support all L1 assets, encrypted WalletConnect
                for mobile and desktop (for the app), BIP39 passphrases and
                Argon2id-encrypted backups for industry-leading protection of
                your wallet data. The entire project is open source because in
                crypto, trust should always be earned through verification, not
                promises.
              </p>
              <div className="hero-actions">
                <a className="button button-primary" href="#download">
                  <DownloadIcon />
                  Download
                </a>
                <a className="button button-ghost" href="#security">
                  Explore the security model
                  <ArrowIcon />
                </a>
              </div>
              <div className="hero-proof" aria-label="Release highlights">
                <span>App v{currentRelease.version}</span>
                <span>Extension v{extensionRelease.version}</span>
                <span>Kaspa Mainnet · Kasplex · Igra</span>
              </div>
            </div>

            <div
              className="phone-stage"
              aria-label="Real Kaspire watch-wallet screenshot"
            >
              <div className="phone-glow" />
              <div className="phone phone-screenshot">
                <img
                  src="/kaspire-watch-wallet.png"
                  alt="Kaspire watch wallet showing the real balance and assets of the public Kaspa address"
                />
              </div>
            </div>
          </div>
          <a className="scroll-cue" href="#features">
            <span>Explore Kaspire</span>
            <i />
          </a>
        </section>

        <section className="signal-strip" aria-label="Supported features">
          <div>
            <span>KAS</span><i />
            <span>KRC-20</span><i />
            <span>KRC-721</span><i />
            <span>KNS</span><i />
            <span>KCC20</span><i />
            <span>WALLETCONNECT</span>
          </div>
        </section>

        <section className="section shell" id="features">
          <div className="section-intro">
            <p className="kicker">The complete wallet</p>
            <h2>Everything you need to move through Kaspa.</h2>
            <p>
              A focused mobile and desktop experience for the network&apos;s native
              coin, emerging asset standards and the dApps connecting them.
            </p>
          </div>
          <div className="feature-grid">
            {highlights.map((feature) => (
              <article className="feature-card" key={feature.number}>
                <span className="feature-number">{feature.number}</span>
                <h3>{feature.title}</h3>
                <p>{feature.copy}</p>
                <div className="tag-row">
                  {feature.tags.map((tag) => (
                    <span key={tag}>{tag}</span>
                  ))}
                </div>
              </article>
            ))}
          </div>
        </section>

        <section className="flow-section">
          <div className="shell flow-layout">
            <div className="section-intro compact">
              <p className="kicker">One clear flow</p>
              <h2>Review first. Authorize second. Broadcast last.</h2>
              <p>
                Kaspire turns untrusted network data into a locally constructed,
                human-readable transaction before a key can sign.
              </p>
            </div>
            <div className="flow-steps">
              <div><span>1</span><b>Build</b><small>Rust reconstructs the transaction.</small></div>
              <i />
              <div><span>2</span><b>Review</b><small>You see the exact economic effect.</small></div>
              <i />
              <div><span>3</span><b>Authorize</b><small>Biometric or PIN approval is fresh.</small></div>
              <i />
              <div><span>4</span><b>Verify</b><small>The returned TX ID must match locally.</small></div>
            </div>
          </div>
        </section>

        <section className="section security-section" id="security">
          <div className="shell">
            <div className="security-heading">
              <div>
                <p className="kicker">Security architecture</p>
                <h2>Self-custody, enforced in layers.</h2>
              </div>
              <p>
                Security is a chain of controls across randomness, key storage,
                signing, authorization, network data, protocols and backups.
                Kaspire is built so no single service gets to decide what your
                wallet signs.
              </p>
            </div>
            <div className="security-grid">
              {securityChapters.map((chapter) => (
                <article className="security-card" key={chapter.eyebrow}>
                  <span>{chapter.eyebrow}</span>
                  <h3>{chapter.title}</h3>
                  <div>{chapter.body}</div>
                </article>
              ))}
            </div>
            <article className="security-deep-dive">
              <span>Security deep dive</span>
              <h3>
                Inside Kaspire: How the Wallet Protects Seeds, Transactions,
                Backups, and dApp Connections
              </h3>
              <a
                className="button button-primary"
                href="/security/inside-kaspire"
              >
                Explore how Kaspire secures your assets
                <ArrowIcon />
              </a>
            </article>
            <blockquote>
              <span>Core principle</span>
              “Network services may provide data, but they are never trusted to
              decide what the wallet signs.”
            </blockquote>
          </div>
        </section>

        <section className="download-section" id="download">
          <DagField />
          <div className="shell download-layout">
            <div className="download-intro">
              <p className="kicker">Kaspire downloads</p>
              <h2>Take control of your Kaspa wallet.</h2>
              <p>
                Choose the native Android app or the browser extension. Both use
                Kaspire&apos;s shared Rust security core across Kaspa Mainnet,
                TN10, Kasplex L2 and Igra L2.
              </p>
            </div>
            <div className="release-card">
              <div className="release-icon">
                <img
                  className="release-logo-symbol"
                  src="/kaspire-logo.png"
                  alt=""
                />
                <img
                  className="release-logo-wordmark"
                  src="/kaspire-wordmark.png"
                  alt="Kaspire"
                />
              </div>
              <div>
                <span>Current release</span>
                <strong>{currentRelease.version} <small>build {currentRelease.build}</small></strong>
              </div>
              <dl>
                <div><dt>Platform</dt><dd>Android 11–16</dd></div>
                <div><dt>Networks</dt><dd>Mainnet · TN10 · Kasplex · Igra</dd></div>
                <div><dt>Architectures</dt><dd>ARM64 · ARMv7</dd></div>
                <div><dt>Package</dt><dd>space.kaspire.wallet</dd></div>
              </dl>
              <a className="button button-primary" href={downloadUrl}>
                <DownloadIcon />
                Download Android APK
              </a>
              <div className="checksum">
                <span>SHA-256</span>
                <code>{currentRelease.sha256}</code>
              </div>
              <p>
                Android may ask you to allow installation from your browser or
                file manager. Verify the checksum before installation.
              </p>
            </div>
            <div className="release-card extension-release-card">
              <div className="release-icon">
                <img
                  className="release-logo-symbol"
                  src="/kaspire-logo.png"
                  alt=""
                />
                <img
                  className="release-logo-wordmark"
                  src="/kaspire-wordmark.png"
                  alt="Kaspire"
                />
              </div>
              <div>
                <span>Current browser extension</span>
                <strong>{extensionRelease.version} <small>build {extensionRelease.build}</small></strong>
              </div>
              <dl>
                <div><dt>Platform</dt><dd>Chrome · Chromium</dd></div>
                <div><dt>Networks</dt><dd>Mainnet · TN10 · Kasplex · Igra</dd></div>
                <div><dt>Manifest</dt><dd>Manifest V3</dd></div>
                <div><dt>Provider</dt><dd>window.kaspire</dd></div>
              </dl>
              <a
                className="button button-primary"
                href={extensionStoreUrl}
                target="_blank"
                rel="noreferrer"
              >
                <DownloadIcon />
                Add extension
              </a>
              <div className="checksum">
                <span>Chrome Web Store ID</span>
                <code>ldjonnkfjmcingabncepnibledcanmoe</code>
              </div>
              <p>
                Kaspire Wallet is live in the Chrome Web Store. Chrome installs
                verified updates automatically through the official listing.
              </p>
            </div>
          </div>
        </section>
      </main>

      <footer>
        <div className="shell footer-inner">
          <img src="/kaspire-wordmark.png" alt="Kaspire" />
          <p>Native self-custody for the Kaspa ecosystem.</p>
          <div>
            <a href="#features">Features</a>
            <a href="#security">Security</a>
            <a href="#download">Download</a>
            <a href="/developers">For Developers</a>
            <a
              href="https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet"
              target="_blank"
              rel="noreferrer"
            >
              GitHub
            </a>
            <a href="/privacy">Privacy</a>
            <a href="https://kaslab.space">HUB21</a>
          </div>
        </div>
      </footer>
    </>
  );
}
