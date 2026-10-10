/// Top-level navigation policy. Subresources do not receive wallet capabilities.
class DappBrowserPolicy {
  static final home = Uri.parse('https://gothdag.kaslab.space/');
  static const approvedHosts = {
    'gothdag.kaslab.space',
    'kasvio.network',
    'devtools.kaslab.space',
    'dotk.name',
    'vaults.kaslab.space',
  };

  static bool approvedPage(Uri uri) =>
      uri.scheme == 'https' &&
      approvedHosts.contains(uri.host) &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  static bool sameDapp(Uri uri, Uri home) =>
      approvedPage(uri) && uri.host == home.host;

  // GothDAG renders its banner twice in these skins: an <img> plus a
  // background on the containing topbar. Remove only the mobile duplicate.
  // Selectors remain valid when GothDAG changes its theme without a reload.
  static const gothdagMobileStyle = '''
    @media (max-width: 900px) {
      .gothicPreview.hub21Theme .topbar {
        background-image: var(--hub-metal) !important;
      }
      .gothicPreview.neptuneTheme .topbar {
        background-image: var(--neptune-water) !important;
      }
    }
  ''';

  /// Converts only Kaspire's two supported Android intents to internal links.
  /// Never dispatch these intents to Android or follow their fallback URL.
  static Uri? walletLink(String value) {
    try {
      return _walletLink(value);
    } on FormatException {
      return null;
    }
  }

  static Uri? _walletLink(String value) {
    if (value.length > 8192) return null;
    if (value.startsWith('intent://')) {
      final parts = value.split('#Intent;');
      if (parts.length != 2 || !parts[1].endsWith(';end')) return null;
      final fields = parts[1].substring(0, parts[1].length - 4).split(';');
      final seen = <String>{};
      for (final field in fields) {
        final separator = field.indexOf('=');
        if (separator < 1) return null;
        final key = field.substring(0, separator);
        final data = field.substring(separator + 1);
        if (!seen.add(key)) return null;
        if (key == 'scheme' && data == 'kaspire') continue;
        if (key == 'package' && data == 'space.kaspire.wallet') continue;
        if (key == 'S.browser_fallback_url') continue;
        return null;
      }
      if (!seen.containsAll({'scheme', 'package'})) return null;
      value = parts[0].replaceFirst('intent:', 'kaspire:');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    if (uri.scheme == 'kaspire' &&
        uri.host == 'dapp' &&
        (uri.path.isEmpty || uri.path == '/') &&
        uri.query.isEmpty) {
      return uri;
    }
    final pairing = (uri.scheme == 'kaspire' &&
            uri.host == 'wc' &&
            (uri.path.isEmpty || uri.path == '/')) ||
        (uri.scheme == 'https' &&
            uri.host == 'kaspire.kaslab.space' &&
            uri.path == '/kaspire/wc');
    if (!pairing ||
        uri.queryParametersAll.length != 1 ||
        uri.queryParametersAll['uri']?.length != 1) {
      return null;
    }
    return uri;
  }
}
