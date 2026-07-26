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
        This Privacy Policy applies to the Kaspire Android application and the
        Kaspire website at <code>kaspire.kaslab.space</code>. Kaspire is a
        non-custodial wallet: the project does not hold users&apos; funds,
        recovery phrases, private keys, or wallet passwords.
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
          operations, and encrypted wallet material locally on the Android
          device. Private wallet material is encrypted using a key protected by
          Android Keystore. Portable wallet backups are encrypted before they
          leave the application.
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
            <p className="kicker">Effective July 26, 2026</p>
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
              This policy describes the current Kaspire application. It should
              be read together with the privacy terms of any dApp, relay,
              blockchain node, or indexer a user chooses to interact with.
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
