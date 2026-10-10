class BrowserDapp {
  const BrowserDapp(this.name, this.url, this.logo);
  final String name;
  final String url;
  final String logo;
  Uri get home => Uri.parse(url);
}

const browserDapps = [
  BrowserDapp('Kasvio', 'https://kasvio.network/', 'assets/browser/kasvio.svg'),
  BrowserDapp(
      'GothDAG', 'https://gothdag.kaslab.space/', 'assets/browser/gothdag.png'),
  BrowserDapp('Kaspa Dev Tools', 'https://devtools.kaslab.space/',
      'assets/browser/devtools.png'),
  BrowserDapp('dot.k', 'https://dotk.name/', 'assets/browser/dotk.png'),
  BrowserDapp('KasCoven Vaults', 'https://vaults.kaslab.space/',
      'assets/browser/vaults.png'),
];
