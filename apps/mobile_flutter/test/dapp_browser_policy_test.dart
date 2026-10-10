import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/dapp_browser_policy.dart';
import 'package:kasvault_wallet/src/services/dapp_session_service.dart';
import 'package:kasvault_wallet/src/services/dapp_browser_catalog.dart';

void main() {
  final pairing = 'wc:${'a' * 64}@2?relay-protocol=irn&symKey=${'b' * 64}';
  final query = Uri.encodeQueryComponent(pairing);
  final app = 'kaspire://wc?uri=$query';
  final fallback = 'https://kaspire.kaslab.space/kaspire/wc?uri=$query';
  final intent = 'intent://wc?uri=$query#Intent;scheme=kaspire;'
      'package=space.kaspire.wallet;S.browser_fallback_url='
      '${Uri.encodeComponent(fallback)};end';

  test('only exact approved HTTPS origins are navigable', () {
    for (final value in [
      'https://gothdag.kaslab.space/',
      'https://gothdag.kaslab.space/game?view=nft#dragons'
    ]) {
      expect(DappBrowserPolicy.approvedPage(Uri.parse(value)), isTrue);
    }
    for (final value in [
      'http://gothdag.kaslab.space/',
      'https://kasperopay.com/',
      'https://gothdag.kaslab.space.evil.example/',
      'https://evil.example/gothdag.kaslab.space',
      'https://user@gothdag.kaslab.space/',
      'https://gothdag.kaslab.space:444/',
      'file:///data/local',
      'content://wallet',
      'javascript:alert(1)'
    ]) {
      expect(DappBrowserPolicy.approvedPage(Uri.parse(value)), isFalse,
          reason: value);
    }
  });

  test('catalog is limited to the five approved dApps', () {
    expect(browserDapps, hasLength(5));
    expect(browserDapps.map((d) => d.home.host).toSet(),
        DappBrowserPolicy.approvedHosts);
    for (final dapp in browserDapps) {
      expect(DappBrowserPolicy.approvedPage(dapp.home), isTrue);
      expect(
          DappBrowserPolicy.sameDapp(
              dapp.home.resolve('/account?tab=nfts'), dapp.home),
          isTrue);
      for (final other in browserDapps.where((d) => d != dapp)) {
        expect(DappBrowserPolicy.sameDapp(other.home, dapp.home), isFalse);
      }
    }
    for (final value in [
      'https://kasvio.network.evil.example/',
      'http://kasvio.network/',
      'https://www.kasvio.network/',
      'https://devtools.kaslab.space:444/',
      'https://user@kasvio.network/'
    ]) {
      expect(DappBrowserPolicy.approvedPage(Uri.parse(value)), isFalse);
    }
  });

  test('GothDAG intent and fallback yield the same validated pairing', () {
    for (final value in [intent, app, fallback]) {
      final link = DappBrowserPolicy.walletLink(value);
      expect(link, isNotNull);
      expect(
          DappSessionService.pairingUriFromQrPayload(link.toString()), pairing);
    }
  });

  test('GothDAG wake remains inside the wallet', () {
    expect(
        DappBrowserPolicy.walletLink('intent://dapp#Intent;scheme=kaspire;'
            'package=space.kaspire.wallet;S.browser_fallback_url='
            'https%3A%2F%2Fkaspire.kaslab.space%2Fkaspire%2Fwc;end'),
        Uri.parse('kaspire://dapp'));
  });

  test('unknown destinations and ambiguous Android intents are blocked', () {
    for (final value in [
      intent.replaceFirst('space.kaspire.wallet', 'com.other.wallet'),
      intent.replaceFirst('scheme=kaspire', 'scheme=https'),
      intent.replaceFirst(';end', ';scheme=kaspire;end'),
      intent.replaceFirst(';end', ';component=evil;end'),
      '$app&uri=$query',
      '$app&extra=1',
      '$app#fragment',
      app.replaceFirst('://wc', '://wc:123'),
      app.replaceFirst('://wc', '://user@wc'),
      fallback.replaceFirst('kaspire.kaslab.space', 'evil.example'),
      'kaspire://export',
      'kaspire://dapp?extra=1',
      'intent://dapp#Intent;scheme=kaspire;end',
      'kaspire://wc?uri=%FF',
    ]) {
      expect(DappBrowserPolicy.walletLink(value), isNull, reason: value);
    }
  });
}
