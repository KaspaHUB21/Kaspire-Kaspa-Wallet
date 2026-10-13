import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';

const wallet =
    'kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
void main() {
  test(
      'KRC20 holdings query only Kasplex token lists, not history or other protocols',
      () async {
    final urls = <Uri>[];
    final api = KaspaApi(client: MockClient((r) async {
      urls.add(r.url);
      expect(r.url.host, 'api.kasplex.org');
      expect(r.url.path, contains('/tokenlist'));
      return http.Response(
          jsonEncode({
            'result': [
              {'tick': 'wallet', 'balance': '42029000000', 'dec': 8},
              {'tick': 'abc', 'balance': '100', 'dec': 2},
            ]
          }),
          200);
    }));
    final assets = await api.loadKrc20Holdings(wallet);
    expect(assets.map((a) => a.symbol), ['ABC', 'WALLET']);
    expect(assets.last.balance, 420.29);
    expect(assets.last.rawBalance, '42029000000');
    expect(urls, hasLength(1));
  });
  for (final healthy in [true, false]) {
    test('cold KRC20 fallback, primary healthy=$healthy', () async {
      final hosts = <String>[];
      final api = KaspaApi(client: MockClient((r) async {
        hosts.add(r.url.host);
        if (r.url.host == 'api.kasplex.org' && !healthy) {
          return http.Response('offline', 503);
        }
        return http.Response('{"result":[]}', 200);
      }));
      expect(await api.loadKrc20Holdings(wallet), isEmpty);
      expect(
          hosts,
          healthy
              ? ['api.kasplex.org']
              : ['api.kasplex.org', 'kaspire.kaslab.space']);
    });
  }
  test(
      'KNS queries its own paginated holdings only and publishes the first page early',
      () async {
    final next = Completer<http.Response>(), first = Completer<void>();
    final urls = <Uri>[];
    final api = KaspaApi(client: MockClient((r) async {
      urls.add(r.url);
      expect(r.url.host, 'api.knsdomains.org');
      expect(r.url.path, '/mainnet/api/v1/assets');
      expect(r.url.queryParameters['owner'], wallet);
      if (r.url.queryParameters['page'] == '2') return next.future;
      return http.Response(
          jsonEncode({
            'data': {
              'assets': [
                {
                  'asset': 'zebra.kas',
                  'assetId': '${'a' * 64}i0',
                  'status': 'listed'
                }
              ],
              'pagination': {'totalPages': 2}
            }
          }),
          200);
    }));
    final result = api.loadKnsHoldings(wallet, onProgress: (rows) {
      if (!first.isCompleted) {
        expect(rows.single.name, 'zebra.kas');
        first.complete();
      }
    });
    await first.future;
    expect(next.isCompleted, isFalse);
    next.complete(http.Response(
        jsonEncode({
          'data': {
            'assets': [
              {
                'asset': 'apple.kas',
                'assetId': '${'b' * 64}i0',
                'status': 'unlisted'
              }
            ],
            'pagination': {'totalPages': 2}
          }
        }),
        200));
    expect((await result).map((d) => d.name), ['apple.kas', 'zebra.kas']);
    expect(urls, hasLength(2));
  });
  test('an unavailable KNS first page is an error, not an empty wallet',
      () async {
    final api =
        KaspaApi(client: MockClient((_) async => http.Response('down', 503)));
    await expectLater(
        api.loadKnsHoldings(wallet), throwsA(isA<KaspaApiException>()));
  });
}
