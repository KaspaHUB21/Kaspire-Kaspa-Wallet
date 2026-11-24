export function PrivacyPage() {
  return (
    <section className="mx-auto max-w-3xl space-y-6">
      <div className="kaspa-panel rounded-md p-6 sm:p-8">
        <p className="text-sm font-semibold text-kaspa-primary">Privacy Policy</p>
        <h1 className="mt-2 text-3xl font-bold text-kaspa-text">KasHub Privacy Policy</h1>
        <p className="mt-3 text-sm text-kaspa-muted">Last updated: July 16, 2026</p>
      </div>

      <div className="kaspa-panel space-y-6 rounded-md p-6 text-sm leading-6 text-kaspa-muted sm:p-8">
        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Overview</h2>
          <p className="mt-2">
            KasHub is a read-only Kaspa token explorer and portfolio tracking interface. We do not require accounts, do not
            collect personal information, and do not sell or share user data.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Data We Do Not Collect</h2>
          <p className="mt-2">
            KasHub does not collect names, email addresses, phone numbers, payment information, device contacts, precise
            location, advertising identifiers, or private keys. KasHub does not use advertising trackers or third-party
            analytics services.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Local Storage</h2>
          <p className="mt-2">
            Features such as portfolio entries, favorites, wallet labels, imported labels, and display preferences are stored
            locally on your device or in your browser. This data is not uploaded to a KasHub account or central user database.
            If you clear your browser or app data, this locally stored information may be deleted.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Public Blockchain and Market Data</h2>
          <p className="mt-2">
            KasHub loads public token, NFT, wallet, transaction, domain, price, chart, and market information from public APIs
            and blockchain indexers. When you search for a wallet, token, or domain, the requested public identifier may be
            sent to the relevant API endpoint so the app can display the result.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Server Logs</h2>
          <p className="mt-2">
            Like most web services, our hosting infrastructure may process basic technical request information such as IP
            address, requested URL, user agent, and timestamp for security, debugging, uptime monitoring, and abuse prevention.
            We do not use this information to create personal advertising profiles.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Exports and Imports</h2>
          <p className="mt-2">
            Portfolio and label import/export files are handled locally by your browser or Android device. Exported files are
            created only when you request them. Imported files are read by the app to restore your local data.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Children's Privacy</h2>
          <p className="mt-2">
            KasHub is not directed at children and does not knowingly collect personal information from children.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Changes</h2>
          <p className="mt-2">
            We may update this policy when the app changes. The updated version will be published on this page with a revised
            date.
          </p>
        </section>

        <section>
          <h2 className="text-lg font-semibold text-kaspa-text">Contact</h2>
          <p className="mt-2">
            For privacy questions about KasHub, contact the project operator through the official KasHub or HUB21 community
            channels.
          </p>
        </section>
      </div>
    </section>
  );
}

