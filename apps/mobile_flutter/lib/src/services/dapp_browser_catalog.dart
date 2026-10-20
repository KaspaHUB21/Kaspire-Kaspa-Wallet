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
  BrowserDapp(
      'GothDAG', 'https://gothdag.kaslab.space/', 'assets/browser/gothdag.png'),
  BrowserDapp('Kaspa Dev Tools', 'https://devtools.kaslab.space/',
      'assets/browser/devtools.png'),
  BrowserDapp('dot.k', 'https://dotk.name/', 'assets/browser/dotk.png'),
  BrowserDapp(
      'Kaspa News', 'https://kaspa.news/', 'assets/browser/kaspa-news.png',
      walletConnectEnabled: false),
  BrowserDapp('KasCoven Vaults', 'https://vaults.kaslab.space/',
      'assets/browser/vaults.png'),
];
