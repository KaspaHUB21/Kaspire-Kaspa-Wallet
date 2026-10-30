import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/kaspa_address.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'braid_mainnet_handoff_test.dart' show SnapshotClock;
import 'braid_service_test.dart' show Memory;

Map<String, dynamic> vector() => jsonDecode(File(
        '../../crates/kaspa_secure_core/src/fixtures/braid-mainnet-staged-deposit-change.json')
    .readAsStringSync()) as Map<String, dynamic>;

class FixtureBraid extends BraidService {
  FixtureBraid(this.nonce,
      {required super.client, required super.clock, required super.store});
  final String nonce;
  @override
  String createDepositNonce() => nonce;
}

// Synthetic, unsigned outpoints. The original vector is signed and executed
// by the native contract-engine test; this test never signs or broadcasts.
Future<Map<String, dynamic>> buildChange(Object? hint, {String? fault}) async {
  final r = vector(), s = r['tradeSummary'] as Map;
  final tx = jsonDecode(r['txJsonString'] as String) as Map;
  final originalInputs = jsonDecode(jsonEncode(tx['inputs'])) as List;
  tx.remove('storageMass');
  for (final input in tx['inputs'] as List) {
    (input as Map).remove('computeBudget');
    input['signatureScript'] = '';
    (input['utxo'] as Map).remove('covenantId');
  }
  final address = r['sender'] as String;
  final service = FixtureBraid(s['nonce'] as String,
      store: Memory(), clock: SnapshotClock(int.parse('${s['chainDaa']}')),
      client: MockClient((request) async {
    if (request.method == 'POST') {
      expect(request.url.path.endsWith('/deposit-build'), true);
      final body = jsonDecode(request.body) as Map;
      expect(body['nonce'], s['nonce']);
      return http.Response(
          jsonEncode({
            'net': 'mainnet',
            'ref': s['ref'],
            'pskt': tx,
            'terms': s['terms'],
            'router': s['router'],
            'userSignInputs': [0, 1],
            'coinIdx': 0,
            'noteIdx': 1,
            'tokRedeems': {
              'note': s['depositNoteRedeem'],
              'inputs': [
                {'idx': 0, 'redeem': s['inputRedeems']['0']}
              ],
              'change': hint,
            },
            'sighashes': {'0': r['scripts'][0]['expectedSighash']},
            'quote': quoteOf(s),
          }),
          200);
    }
    expect(request.method, 'GET');
    expect(request.url.path.endsWith('/utxos'), true);
    final entries = originalInputs.map((i) {
      final u = i['utxo'] as Map;
      return {
        'outpoint': {'transactionId': i['transactionId'], 'index': i['index']},
        'utxoEntry': {
          ...u,
          'scriptPublicKey': {
            'version': 0,
            'script': (u['scriptPublicKey'] as String).substring(4)
          }
        },
      };
    }).toList();
    return http.Response(
        jsonEncode({
          'network': 'mainnet',
          'covenantIdsIncluded': true,
          'entries': entries
        }),
        200);
  }));
  if (fault == 'redirect') {
    tx['outputs'][3]['scriptPublicKey'] = '000020${'11' * 32}ac';
  }
  if (fault == 'duplicate') (tx['outputs'] as List).add(tx['outputs'][3]);
  if (fault == 'missing') (tx['outputs'] as List).removeAt(3);
  if (fault == 'amount') {
    final redeem = s['inputRedeems']['0'] as String;
    // The declared input amount no longer agrees with the exact live script.
    s['inputRedeems']['0'] = redeem.replaceRange(70, 86, '01${'00' * 7}');
  }
  try {
    return await service.build(address, {
      ...quoteOf(s),
      'localAt': DateTime.now().millisecondsSinceEpoch,
      'localFromId': s['fromId'],
      'localToId': s['toId'],
      'localAmount': s['amountIn'],
      'localFloor': s['minimumOut'],
      'localMidMin': s['midMin'],
      'localSlippage': 100,
      'localValuation': s['valuation'],
    });
  } finally {
    service.client.close();
  }
}

Map<String, dynamic> quoteOf(Map s) => {
      'net': 'mainnet',
      'pin': BraidService.mainnetPin,
      'from': 'THEN',
      'to': 'GUZA',
      'amountIn': s['amountIn'],
      'amountOut': s['minimumOut'],
      'braidFee': s['feeCap'],
      'staged': true,
      'midMin': s['midMin'],
      'walletFee': {
        'mode': 'bps',
        'bps': 100,
        'unit': 'KAS',
        'amount': s['walletFee'],
        'basis': s['feeBasis'],
        'basisKind': 'tradeKas',
        'pk': BraidService.feeOwner,
        'address': kaspaAddressFromOwnerId(BraidService.feeOwner),
      }
    };

Future<ProcessResult> inspect(Map request) async {
  final p = await Process.start('../../target/debug/braid_inspect', []);
  p.stdin.write(jsonEncode(request));
  await p.stdin.close();
  final out = utf8.decoder.bind(p.stdout).join();
  final err = utf8.decoder.bind(p.stderr).join();
  return ProcessResult(p.pid, await p.exitCode, await out, await err);
}

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.mainnet);
  test('production deposit nonces remain fresh 32-byte secure-random values',
      () {
    final service = BraidService();
    final values = List.generate(100, (_) => service.createDepositNonce());
    expect(values.toSet().length, values.length);
    expect(values.every((v) => RegExp(r'^[a-f0-9]{64}$').hasMatch(v)), true);
    service.client.close();
  });
  for (final hint in <Object?>[
    [],
    [
      {'idx': 3, 'redeem': 'untrusted hint'}
    ],
    {'redeem': 'untrusted hint'},
    'untrusted hint',
    null
  ]) {
    test('token change is rebuilt independently for ${hint.runtimeType}',
        () async {
      final receipt = await buildChange(hint);
      final original = vector();
      final request = receipt['request'] as Map;
      final tx = jsonDecode(request['txJsonString'] as String) as Map;
      expect(tx['inputs'][0]['signatureScript'],
          original['scripts'][0]['prebuiltSignatureScript']);
      final review = await inspect(request);
      expect(review.exitCode, 0, reason: '${review.stderr}');
      final data = jsonDecode('${review.stdout}') as Map;
      expect(data['finalFeeKnown'], true);
      expect(data['outputCount'], 4);
      expect(data['feeSompi'], 1000000);
    });
  }
  for (final fault in ['redirect', 'duplicate', 'missing', 'amount']) {
    test('incorrect token change is rejected: $fault', () async {
      try {
        final receipt = await buildChange([], fault: fault);
        expect((await inspect(receipt['request'] as Map)).exitCode, isNot(0));
      } on StateError {/* rejected before native review */}
    });
  }
}
