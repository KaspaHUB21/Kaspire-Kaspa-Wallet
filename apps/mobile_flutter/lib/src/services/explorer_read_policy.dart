/// Read-only public explorer transport. Never attach wallet sessions or keys.
bool explorerReadAllowed(String method, Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443)) return false;
  final path = uri.path;
  if (uri.host == 'kaspatoken.kaslab.space') {
    if (method == 'GET')
      return RegExp(
                  r'^/api/(tokens$|token/|kcc20/|wallet/|home/|kaspa/|kns/|dotk/|market/|sources$)')
              .hasMatch(path) &&
          !RegExp(r'/(auth|admin|submit|sign|send|create|trade)(/|$)')
              .hasMatch(path);
    return method == 'POST' &&
        (RegExp(r'^/api/token/[^/]+/holder-activity$').hasMatch(path) ||
            RegExp(r'^/api/kcc20/token/[a-f0-9]{64}/transaction-owners$')
                .hasMatch(path));
  }
  if (uri.host == 'kaspanftnexus.com') {
    if (method == 'POST') return path == '/api/collections/resolve';
    return method == 'GET' &&
        (path == '/api/collections' ||
            RegExp(r'^/api/collections/[^/]+/(tokens|traits)$')
                .hasMatch(path) ||
            RegExp(r'^/api/nfts/[^/]+/[^/]+$').hasMatch(path));
  }
  if (uri.host == 'kaspire.kaslab.space') {
    if (method != 'GET') return false;
    if (path == '/api/explorer/blockdag') return !uri.hasQuery;
    return RegExp(
            r'^/api/local-node/(addresses/kaspa:[a-z0-9]+/(balance|full-transactions)|transactions/[a-f0-9]{64}|blocks/[a-f0-9]{64}|info/(blockdag|hashrate|coinsupply|health))$')
        .hasMatch(Uri.decodeComponent(path));
  }
  return method == 'GET' &&
      uri.host == 'insdomains.org' &&
      path == '/api/reverse';
}
