import type { Metadata } from "next";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { currentRelease } from "../../release";

export const metadata: Metadata = {
  title: "Inside Kaspire | Wallet Security Architecture",
  description:
    "How Kaspire protects seeds, transactions, backups, token operations, and dApp connections.",
};

const sectionHeadings = new Set([
  "Secure seed generation",
  "BIP-39 passphrase support",
  "Modern and legacy HD derivation",
  "Multiple accounts under one seed",
  "Seed encryption at rest",
  "Native security boundary",
  "Biometric and PIN authorization",
  "Transaction reconstruction in Rust",
  "Review-hash binding",
  "Local transaction-ID verification",
  "Watch-only isolation",
  "UTXO compounding safety",
  "KRC-20, KRC-721, and KNS commit/reveal protection",
  "Typed KCC20 covenant signing",
  "WalletConnect isolation",
  "Secure personal-message signing",
  "Encrypted portable backups",
  "Screen and clipboard protections",
  "Network security and local infrastructure",
  "Pinned native signing code",
  "Security as a system",
]);

type ArticleSection = {
  heading: string | null;
  lines: string[];
};

function loadArticle() {
  const source = readFileSync(
    join(process.cwd(), "content", "inside-kaspire.txt"),
    "utf8",
  );
  const lines = source
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const title = lines.shift() ?? "Inside Kaspire";
  const sections: ArticleSection[] = [{ heading: null, lines: [] }];

  for (const line of lines) {
    if (sectionHeadings.has(line)) {
      sections.push({ heading: line, lines: [] });
    } else {
      sections.at(-1)!.lines.push(line);
    }
  }

  return { title, sections };
}

function ArticleBlocks({ lines }: { lines: string[] }) {
  const blocks: React.ReactNode[] = [];

  for (let index = 0; index < lines.length; ) {
    const line = lines[index];

    if (line.startsWith("•")) {
      const items: string[] = [];
      while (index < lines.length && lines[index].startsWith("•")) {
        items.push(lines[index].replace(/^•\s*/, ""));
        index += 1;
      }
      blocks.push(
        <ul key={`list-${index}`}>
          {items.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>,
      );
      continue;
    }

    if (/^\d+\.\s/.test(line)) {
      const items: string[] = [];
      while (index < lines.length && /^\d+\.\s/.test(lines[index])) {
        items.push(lines[index].replace(/^\d+\.\s*/, ""));
        index += 1;
      }
      blocks.push(
        <ol key={`steps-${index}`}>
          {items.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ol>,
      );
      continue;
    }

    if (line.startsWith("m/44")) {
      blocks.push(<code key={`code-${index}`}>{line}</code>);
      index += 1;
      continue;
    }

    if (
      line ===
      "Network services may provide data, but they are never trusted to decide what the wallet signs."
    ) {
      blocks.push(
        <blockquote key={`quote-${index}`}>
          <span>Core principle</span>
          “{line}”
        </blockquote>,
      );
      index += 1;
      continue;
    }

    blocks.push(<p key={`paragraph-${index}`}>{line}</p>);
    index += 1;
  }

  return blocks;
}

export default function InsideKaspirePage() {
  const { title, sections } = loadArticle();

  return (
    <>
      <a className="skip-link" href="#article">
        Skip to article
      </a>
      <header className="site-header article-header">
        <div className="shell header-inner">
          <a
            className="header-brand"
            href="/"
            aria-label="Back to Kaspire home"
          >
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
          <nav aria-label="Article navigation">
            <a href="/#features">Features</a>
            <a href="/#security">Security</a>
            <a href="/#download">Download</a>
          </nav>
          <a className="header-download" href="/">
            Back home
          </a>
        </div>
      </header>

      <main id="article" className="article-page">
        <section className="article-hero">
          <div className="shell article-hero-inner">
            <p className="kicker">
              Security deep dive · Kaspire {currentRelease.version}
            </p>
            <h1>{title}</h1>
            <p>
              A technical walkthrough of the controls protecting wallet
              creation, storage, authorization, signing, protocols, backups,
              and external connections.
            </p>
            <div className="article-meta">
              <span>21 security areas</span>
              <span>Native Android + Rust</span>
              <span>Kaspa Mainnet</span>
            </div>
          </div>
        </section>

        <article className="shell article-body">
          {sections.map((section, index) =>
            section.heading === null ? (
              <div className="article-lead" key="introduction">
                <ArticleBlocks lines={section.lines} />
              </div>
            ) : (
              <section
                className="article-section"
                id={`section-${index}`}
                key={section.heading}
              >
                <span className="article-number">
                  {String(index).padStart(2, "0")}
                </span>
                <div>
                  <h2>{section.heading}</h2>
                  <ArticleBlocks lines={section.lines} />
                </div>
              </section>
            ),
          )}
        </article>

        <section className="article-cta">
          <div className="shell">
            <p className="kicker">Read the architecture. Verify the wallet.</p>
            <h2>Security should be inspectable—not promised.</h2>
            <div>
              <a className="button button-primary large" href="/#download">
                Download Kaspire
              </a>
              <a className="button button-ghost large" href="/#security">
                Return to security overview
              </a>
            </div>
          </div>
        </section>
      </main>

      <footer>
        <div className="shell footer-inner">
          <img src="/kaspire-wordmark.png" alt="Kaspire" />
          <p>Native self-custody for the Kaspa ecosystem.</p>
          <div>
            <a href="/">Home</a>
            <a href="/#security">Security</a>
            <a href="/#download">Download</a>
            <a href="/developers">For Developers</a>
            <a href="/privacy">Privacy</a>
            <a href="https://kaslab.space">HUB21</a>
          </div>
        </div>
      </footer>
    </>
  );
}
