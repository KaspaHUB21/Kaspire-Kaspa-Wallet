import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy Policy | Kaspire",
  description:
    "How the Kaspire self-custody wallet processes local wallet data, blockchain requests, dApp connections, and device permissions.",
};

const sections = [
  {
    title: "Who this policy applies to",
    content: (
      <p>
        This Privacy Policy applies to the Kaspire Android application, the
        Kaspire browser extension, and the Kaspire website at{" "}
        <code>kaspire.kaslab.space</code>. Kaspire is a non-custodial wallet:
        the project does not hold users&apos; funds, recovery phrases, private
        keys, or wallet passwords.
      </p>
    ),
  },
  {
    title: "Data stored on your device",
    content: (
      <>
        <p>
          Kaspire stores wallet configuration, public addresses, preferences,
          address-book entries, transaction activity, pending protocol
          operations, and encrypted wallet material locally on the user&apos;s
          device. The Android app protects private wallet material using
          Android Keystore. The browser extension encrypts its local vault with
          Argon2id-derived key material and AES-256-GCM. While the extension is
          unlocked, decrypted wallet material is held only in the extension&apos;s
          local session context so that user-approved operations can be signed.
          Portable wallet backups are encrypted before export.
        </p>
        <p>
          Recovery phrases, BIP39 passphrases, imported private keys, wallet
          passwords, application PINs, and backup passwords are not sent to
          Kaspire servers.
        </p>
      </>
    ),
  },
  {
    title: "Blockchain and indexer requests",
    content: (
      <>
        <p>
          To display balances, UTXOs, assets, names, fees, and transaction
          history—and to broadcast user-approved transactions—Kaspire sends
          public blockchain identifiers and request data to Kaspa network
          services. Depending on the requested feature and service
          availability, these may include the Kaspire-operated Kaspa
          infrastructure, public Kaspa API fallbacks, Kaspa token and NFT
          indexers, KNS services, the kcc20.info indexer, and Kascov fallback
          services.
        </p>
        <p>
          Requests can contain public wallet addresses, transaction IDs, token
          or covenant identifiers, domain names, and signed transactions
          selected for broadcast. These services necessarily receive network
          metadata such as an IP address. Public blockchain transactions are
          permanently visible on the Kaspa network and cannot be deleted by
          Kaspire.
        </p>
      </>
    ),
  },
  {
    title: "Browser extension and connected websites",
    content: (
      <>
        <p>
          The browser extension makes the Kaspire provider available to web
          applications on HTTP and HTTPS pages. It does not read page text,
          images, unrelated form fields, cookies, or compile general browsing
          history. When a website deliberately calls the provider, Kaspire
          processes that site&apos;s origin and its wallet request. A connected
          dApp origin is stored locally until the user disconnects it.
        </p>
        <p>
          A dApp receives a public wallet address or signature only after the
          applicable connection or approval flow. Transaction, PSKT, asset
          transfer, and personal-signature request payloads are processed only
          to display a review and perform the operation the user approves.
          Private keys, recovery phrases, vault passwords, and decrypted vault
          contents are never exposed to websites.
        </p>
      </>
    ),
  },
  {
    title: "Data categories and recipients",
    content: (
      <>
        <p>
          For Chrome Web Store disclosure purposes, Kaspire handles financial
          information (public wallet addresses, balances, assets, transaction
          history, and signed transactions), authentication information
          (vault and backup passwords, recovery phrases, BIP39 passphrases, and
          private keys), and website information limited to connected dApp
          origins and wallet request payloads. Authentication information is
          processed locally and is not sent to Kaspire or third-party servers.
        </p>
        <p>
          Public identifiers and approved transaction data may be transmitted
          to <code>kaspire.kaslab.space</code>, <code>api.kaspa.org</code>,
          <code>kaspatoken.kaslab.space</code>, <code>api.kasplex.org</code>,
          <code>kcc20.info</code>, <code>kascov.io</code>,
          <code>krc721-indexer.kaspa.com</code>,
          <code>api.knsdomains.org</code>, <code>api.kaspa.com</code>,
          <code>gothdag.kaslab.space</code>, and
          <code>open.er-api.com</code>, depending on the feature used. These
          services also receive ordinary connection metadata such as the
          user&apos;s IP address. No data is transferred for advertising or
          resale.
        </p>
      </>
    ),
  },
  {
    title: "Browser extension permissions",
    content: (
      <>
        <p>
          <code>storage</code> keeps the encrypted vault, public wallet state,
          settings, contacts, connected dApp origins, and activity data on the
          device. <code>alarms</code> performs the configured inactivity lock
          even when the extension popup is closed. Access on HTTP and HTTPS
          pages is used only to inject the Kaspire provider and relay explicit
          wallet API requests from a website to the extension.
        </p>
        <p>
          Host access is limited to the Kaspa node, indexer, exchange-rate,
          metadata, and transaction-broadcast services needed to display wallet
          state and complete user-approved operations. The extension does not
          request the Chrome <code>idle</code> permission.
        </p>
      </>
    ),
  },
  {
    title: "WalletConnect and dApp connections",
    content: (
      <>
        <p>
          When a user deliberately connects Kaspire to a dApp, WalletConnect
          and Reown relay infrastructure transports encrypted pairing and
          session messages. The dApp receives the public account selected by
          the user and the result of requests the user approves. Kaspire does
          not expose private keys or recovery phrases to dApps or relay
          services.
        </p>
        <p>
          The connected dApp and relay provider process data under their own
          privacy terms. Users should connect only to dApps they recognize and
          disconnect sessions they no longer use.
        </p>
      </>
    ),
  },
  {
    title: "Remote code",
    content: (
      <p>
        The Kaspire browser extension does not use remote code. Its JavaScript,
        WebAssembly security core, and executable logic are included in the
        extension package reviewed by the Chrome Web Store. Remote services
        return blockchain data, token metadata, exchange rates, and broadcast
        results; those responses are treated as data and are not executed as
        code.
      </p>
    ),
  },
  {
    title: "Camera and biometric access",
    content: (
      <>
        <p>
          Camera permission is used only when the user opens QR scanning.
          Camera frames are processed on the device for barcode recognition and
          are not intentionally uploaded or retained by Kaspire.
        </p>
        <p>
          Biometric checks are performed by Android system services. Kaspire
          receives only the authorization result and does not receive or store
          fingerprint, face, or other biometric templates.
        </p>
      </>
    ),
  },
  {
    title: "Chrome Web Store Limited Use",
    content: (
      <p>
        Kaspire&apos;s use of information received from Chrome APIs complies
        with the Chrome Web Store User Data Policy, including the Limited Use
        requirements. User data is used only to provide and secure the
        self-custody wallet functions described here. Kaspire does not sell
        user data, use it for advertising or credit decisions, or permit humans
        to read private wallet data.
      </p>
    ),
  },
  {
    title: "Analytics, advertising, and tracking",
    content: (
      <p>
        Kaspire does not include advertising SDKs, cross-app tracking, or
        behavioral analytics. The project does not sell personal data.
        Infrastructure providers may maintain operational security logs
        according to their own retention and legal obligations.
      </p>
    ),
  },
  {
    title: "Data retention and deletion",
    content: (
      <>
        <p>
          Local application data remains on the device until the user removes
          wallets, clears application storage, or uninstalls Kaspire. Before
          deleting application data, users must independently secure their
          recovery phrase, any BIP39 passphrase, and any required encrypted
          backup.
        </p>
        <p>
          Clearing local data cannot remove information already published to a
          public blockchain or data independently retained by a connected dApp,
          relay, node, indexer, or other third-party service.
        </p>
      </>
    ),
  },
  {
    title: "Security",
    content: (
      <p>
        Kaspire uses local encryption, Android Keystore, authenticated backups,
        explicit transaction review, and local signing controls to protect
        wallet data. No software or transmission method can guarantee absolute
        security. Users remain responsible for protecting recovery material and
        verifying recipients and transaction details before approval.
      </p>
    ),
  },
  {
    title: "Children",
    content: (
      <p>
        Kaspire is not directed to children. The application is intended for
        people who are legally permitted to use cryptocurrency wallet software
        in their jurisdiction.
      </p>
    ),
  },
  {
    title: "Changes and contact",
    content: (
      <>
        <p>
          This policy may be updated when Kaspire&apos;s functionality,
          infrastructure, or legal obligations change. Material updates will be
          published at this same URL with a revised effective date.
        </p>
        <p>
          Privacy questions can be directed to the Kaspire project through{" "}
          <a href="https://kaslab.space">HUB21 / Kaslab</a>. The public support
          contact listed on Kaspire&apos;s Google Play store listing may also be
          used once the listing is available.
        </p>
      </>
    ),
  },
];

export default function PrivacyPage() {
  return (
    <>
      <a className="skip-link" href="#privacy-policy">
        Skip to privacy policy
      </a>
      <header className="site-header article-header">
        <div className="shell header-inner">
          <a className="header-brand" href="/" aria-label="Kaspire home">
            <img className="header-brand-symbol" src="/kaspire-logo.png" alt="" />
            <img
              className="header-brand-wordmark"
              src="/kaspire-wordmark.png"
              alt="Kaspire"
            />
          </a>
          <nav aria-label="Privacy navigation">
            <a href="/#features">Features</a>
            <a href="/#security">Security</a>
            <a href="/developers">Developers</a>
          </nav>
          <a className="header-download" href="/">
            Back home
          </a>
        </div>
      </header>

      <main id="privacy-policy" className="article-page">
        <section className="article-hero">
          <div className="shell article-hero-inner">
            <p className="kicker">Effective August 4, 2026</p>
            <h1>Kaspire Privacy Policy</h1>
            <p>
              How Kaspire processes wallet data, network requests, device
              permissions, and dApp connections while keeping signing keys
              under the user&apos;s control.
            </p>
            <div className="article-meta">
              <span>Non-custodial</span>
              <span>No advertising</span>
              <span>No behavioral analytics</span>
            </div>
          </div>
        </section>

        <article className="shell article-body">
          <div className="article-lead">
            <p>
              This policy describes the current Kaspire Android app, browser
              extension, and website. It should be read together with the
              privacy terms of any dApp, relay, blockchain node, or indexer a
              user chooses to interact with.
            </p>
          </div>
          {sections.map((section, index) => (
            <section className="article-section" key={section.title}>
              <span className="article-number">
                {String(index + 1).padStart(2, "0")}
              </span>
              <div>
                <h2>{section.title}</h2>
                {section.content}
              </div>
            </section>
          ))}
        </article>
      </main>

      <footer>
        <div className="shell footer-inner">
          <img src="/kaspire-wordmark.png" alt="Kaspire" />
          <p>Native self-custody for the Kaspa ecosystem.</p>
          <div>
            <a href="/">Home</a>
            <a href="/#security">Security</a>
            <a href="/developers">For Developers</a>
            <a href="/privacy">Privacy</a>
            <a href="https://kaslab.space">HUB21</a>
          </div>
        </div>
      </footer>
    </>
  );
}
