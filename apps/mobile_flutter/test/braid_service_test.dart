import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/braid_clock.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';

class Memory implements EncryptedStore {
  final data = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String k) async => data[k];
  @override
  Future<void> write(String k, String v) async {
    if (!fail) data[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    data.remove(k);
  }
}

Map<String, dynamic> fixture() => Map<String, dynamic>.from(jsonDecode(
    File('../../crates/kaspa_secure_core/src/fixtures/braid-tn10-kas-buy.json')
        .readAsStringSync()) as Map);
Map<String, dynamic> info() => {
      'net': 'tn10',
      'enabled': true,
      'pin': BraidService.pin,
      'expectedPin': BraidService.pin,
      'pinOk': true,
      'executorStatus': {'healthy': true}
    };
Map<String, dynamic> quote() => {
      'net': 'tn10',
      'from': 'KAS',
      'to': 'ICE',
      'pin': BraidService.pin,
      'staged': false,
      'amountIn': '2937000000',
      'payTotal': '3000000000',
      'amountOut': '884487',
      'minOut': '875642',
      'braidFee': '0',
      'walletFee': {'amount': '0'}
    };
http.Response reply(Object d, [int status = 200]) =>
    http.Response(jsonEncode(d), status);

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  test('Blake2b-256 uses the protocol output length, not truncated Blake2b-512',
      () {
    expect(BraidService.digest([]),
        '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8');
  });
  test('network changes fail before any Braid HTTP write', () async {
    var calls = 0;
    final svc = BraidService(client: MockClient((_) async {
      calls++;
      return reply({});
    }));
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    await expectLater(svc.info(), throwsStateError);
    expect(calls, 0);
  });
  test(
      'quote binds network, pair, pinned program, exact debit and locally computed floor',
      () async {
    final address = '${fixture()['sender']}';
    final svc = BraidService(client: MockClient((r) async {
      if (r.url.path.endsWith('/info')) return reply(info());
      expect(r.url.queryParameters['payTotal'], '3000000000');
      expect(r.url.queryParameters.containsKey('walletFeeBps'), false);
      return reply(quote());
    }));
    final q = await svc.quote(address, BraidService.tokens[0],
        BraidService.tokens[1], '3000000000', 100);
    expect(q['localFloor'], '875642');
    expect(q['localFromId'], BraidService.zero);
    expect(q['localToId'], BraidService.tokens[1].id);
  });
  test('unapproved fees and router/pair substitutions are rejected', () async {
    for (final q in [
      {...quote(), 'pin': '0' * 64},
      {...quote(), 'to': 'FIRE'},
      {
        ...quote(),
        'walletFee': {'amount': '1'}
      },
      {...quote(), 'staged': true}
    ]) {
      final svc = BraidService(
          client: MockClient(
              (r) async => reply(r.url.path.endsWith('/info') ? info() : q)));
      await expectLater(
          svc.quote('${fixture()['sender']}', BraidService.tokens[0],
              BraidService.tokens[1], '3000000000', 100),
          throwsStateError);
    }
  });
  test(
      'signed journals survive failed submit, expiry claims and service reopening',
      () async {
    final memory = Memory(), address = '${fixture()['sender']}';
    final rec = <String, dynamic>{
      'ref': 'br-test',
      'signed': {'0': 'ab' * 65},
      'transactionId': '11' * 32,
      'state': 'signed'
    };
    final svc = BraidService(
        store: memory,
        client: MockClient((_) async =>
            reply({'error': 'expired', 'code': 'DEADLINE_TOO_CLOSE'}, 409)));
    await svc.retain(address, rec);
    await expectLater(svc.submit(address, rec), throwsStateError);
    final reopened = BraidService(store: memory);
    expect((await reopened.pending(address))!['signed'], rec['signed']);
  });
  test('receipt persistence is verified before any submission', () async {
    final memory = Memory()..fail = true;
    var posts = 0;
    final svc = BraidService(
        store: memory,
        client: MockClient((_) async {
          posts++;
          return reply({});
        }));
    await expectLater(
        svc.submit('${fixture()['sender']}', {
          'ref': 'br-abc',
          'signed': {'0': '00' * 65}
        }),
        throwsStateError);
    expect(posts, 0);
  });
  test('operation guard always releases after failure', () async {
    final svc = BraidService();
    await expectLater(
        svc.exclusive('test', () async => throw StateError('cancelled')),
        throwsStateError);
    expect(await svc.exclusive('test', () async => 42), 42);
  });
  test(
      'node verification rejects mismatching amount, script and missing exact outpoint',
      () async {
    final tx =
        jsonDecode('${fixture()['txJsonString']}') as Map<String, dynamic>;
    tx.remove('storageMass');
    for (final i in tx['inputs'] as List) {
      i.remove('computeBudget');
      (i['utxo'] as Map).remove('covenantId');
    }
    for (final mode in ['amount', 'script', 'missing']) {
      final row = (tx['inputs'] as List).first as Map, u = row['utxo'] as Map;
      final svc = BraidService(
          client: MockClient((_) async => reply({
                'network': 'testnet-10',
                'covenantIdsIncluded': true,
                'entries': mode == 'missing'
                    ? []
                    : [
                        {
                          'outpoint': {
                            'transactionId': row['transactionId'],
                            'index': row['index']
                          },
                          'utxoEntry': {
                            'amount': mode == 'amount' ? '1' : u['amount'],
                            'scriptPublicKey': {
                              'version': 0,
                              'script': mode == 'script'
                                  ? '20${'11' * 32}ac'
                                  : '${u['scriptPublicKey']}'.substring(4)
                            },
                            'isCoinbase': false,
                            'blockDaaScore': '123',
                            'covenantId': null
                          }
                        }
                      ]
              })));
      await expectLater(svc.verifyInputs(tx), throwsStateError);
    }
  });
  test(
      'finality cannot be forged using a different accepted payment to the same wallet',
      () async {
    final svc = BraidService(
        client: MockClient((_) async => reply({
              'transaction_id': '22' * 32,
              'is_accepted': true,
              'inputs': [
                {
                  'previous_outpoint_hash': '33' * 32,
                  'previous_outpoint_index': 0
                }
              ],
              'outputs': []
            })));
    await expectLater(
        svc.verifyFinal('${fixture()['sender']}', {
          'transactionId': '11' * 32,
          'depositCoinIndex': 0,
          'context': {'toId': BraidService.zero}
        }, {
          'state': 'done',
          'exec': {'txid': '22' * 32},
          'received': {'amount': '100000000'}
        }),
        throwsStateError);
  });
  test('independent clocks disagreeing by more than a minute prevent signing',
      () async {
    final c = MockClient((_) async => reply(
        {'networkName': 'kaspa-testnet-10', 'virtualDaaScore': '606000000'}));
    await expectLater(BraidClock(c, socketRead: () async => 606000601).read(),
        throwsStateError);
  });
  test(
      'wRPC clock decoder rejects wrong network, unsynced data and response ID',
      () {
    final payload = Uint8List(26);
    final p = ByteData.sublistView(payload);
    p.setUint32(6, 0, Endian.little);
    payload[10] = 1;
    payload[11] = 1;
    p.setUint32(12, 10, Endian.little);
    payload[16] = 1;
    payload[17] = 1;
    p.setUint64(18, 606000000, Endian.little);
    final frame = Uint8List(17 + payload.length);
    final f = ByteData.sublistView(frame);
    frame[0] = 1;
    f.setUint64(1, 1, Endian.little);
    frame[11] = 114;
    frame[12] = 1;
    f.setUint32(13, payload.length, Endian.little);
    frame.setRange(17, frame.length, payload);
    expect(decodeBraidServerInfo(frame), 606000000);
    final bad = Uint8List.fromList(frame)..[33] = 0;
    expect(() => decodeBraidServerInfo(bad), throwsFormatException);
    final wrong = Uint8List.fromList(frame)..[27] = 0;
    expect(() => decodeBraidServerInfo(wrong), throwsFormatException);
  });
}
