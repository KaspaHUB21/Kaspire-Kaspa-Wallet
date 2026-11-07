class BrowserDapp {
  const BrowserDapp(this.name, this.url, this.logo,
      {this.walletConnectEnabled = true});
  final String name;
  final String url;
  final String logo;
  final bool walletConnectEnabled;
  Uri get home => Uri.parse(url);
}

const browserDapps = [
  BrowserDapp('Kasvio', 'https://kasvio.network/', 'assets/browser/kasvio.svg'),
  BrowserDapp('Kasseal', 'https://app.kasseal.com/',
      'assets/browser/kasseal-browser.png'),
  BrowserDapp(
      'GothDAG', 'https://gothdag.kaslab.space/', 'assets/browser/gothdag.png'),
  BrowserDapp('Braid', 'https://app.braidswap.com/', 'assets/browser/braid.svg'),
  BrowserDapp('dot.k', 'https://dotk.name/', 'assets/browser/dotk.png'),
  BrowserDapp(
      'Kaspa News', 'https://kaspa.news/', 'assets/browser/kaspa-news.png',
      walletConnectEnabled: false),
  BrowserDapp('Kaspa Dev Tools', 'https://devtools.kaslab.space/',
      'assets/browser/devtools.png'),
  BrowserDapp('KasForge', 'https://kaspa.pumpforge.tech/',
      'assets/browser/kasforge.png'),
  BrowserDapp('KasForge Vaults', 'https://vault.pumpforge.tech/',
      'assets/browser/kasforge-vaults.svg'),
  BrowserDapp('Jeetslab',
      'https://jeetslab-staging.kaspajeets.workers.dev/wallet',
      'assets/browser/jeetslab.jpg'),
  BrowserDapp('ANTX Universe', 'https://universe.antx.world/',
      'assets/browser/antx-universe.svg'),
  BrowserDapp('KasCoven Vaults', 'https://vaults.kaslab.space/',
      'assets/browser/vaults.png'),
];
