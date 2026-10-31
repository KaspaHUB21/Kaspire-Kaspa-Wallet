import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kasvault_wallet/src/services/activity_store.dart';
import 'package:kasvault_wallet/src/services/encrypted_store.dart';
import 'package:kasvault_wallet/src/services/kaspa_api.dart';
import 'package:kasvault_wallet/src/services/kron_dex_service.dart';

class Memory implements EncryptedStore {
  final values = <String, String>{};
  bool archiveFails = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (archiveFails && key.endsWith('_last_obsolete')) {
      throw StateError('Storage unavailable');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class Node extends KaspaApi {
  bool accepted = false, failStatus = false, reject = false, late = false;
  int sends = 0;
  String? sent;
  Completer<void>? paused;
  @override
  Future<bool> kcc20PlanTransactionAccepted(String transactionId) async {
    if (paused != null) await paused!.future;
    if (failStatus) throw StateError('Own node unavailable');
    return accepted;
  }

  @override
  Future<String> broadcastKcc20(String json,
      {required String expectedTransactionId}) async {
    sends++;
    sent = json;
    if (late) {
      accepted = true;
      throw TimeoutException('Response lost');
    }
    if (reject) throw StateError('orphan where orphan is disallowed');
    return expectedTransactionId;
  }
}

final own = 'a' * 64, origin = 'b' * 64, competing = 'c' * 64;
const address = 'kaspa:fixture';
Map<String, dynamic> receipt() => {
      'transactionId': own,
      'signedTxJson': jsonEncode({
        'id': own,
        'inputs': [
          {
            'transactionId': origin,
            'index': 1,
            'signatureScript': 'signed-unchanged',
            'utxo': {'address': null}
          }
        ]
      }),
      'ticker': 'KRON',
      'decimals': 8,
      'tokenId': 'd' * 64,
      'timestamp': '2026-10-31T00:00:00Z',
      'summary': {'side': 'buy', 'tokenAmount': '123000000', 'ticker': 'KRON'}
    };
Map rival({bool accepted = true, int index = 1, String? id}) => {
      'transaction_id': id ?? competing,
      'is_accepted': accepted,
      'inputs': [
        {'previous_outpoint_hash': origin, 'previous_outpoint_index': index}
      ]
    };
http.Client history(
        {bool conflict = false,
        bool accepted = true,
        int index = 1,
        bool missing = false,
        bool unavailable = false,
        VoidCallback? onProof}) =>
    MockClient((r) async {
      if (unavailable) return http.Response('{}', 429);
      if (missing) return http.Response('{}', 404);
      Object data;
      if (r.url.path.contains('/full-transactions')) {
        data = conflict ? [rival(index: index)] : [];
      } else if (r.url.path.endsWith(competing)) {
        onProof?.call();
        data = rival(accepted: accepted, index: index);
      } else {
        data = {
          'transaction_id': origin,
          'is_accepted': true,
          'outputs': [
            {'index': 1, 'script_public_key_address': 'kaspa:pool'}
          ]
        };
      }
      return http.Response(jsonEncode(data), 200);
    });
typedef VoidCallback = void Function();
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<KronDexService> setup(Memory store, Node node,
      {http.Client? client}) async {
    final s = KronDexService(
        store: store,
        api: node,
        activity: ActivityStore(encryptedStore: store),
        client: client ?? history());
    await s.retain(address, receipt());
    return s;
  }

  test('already accepted saved swap completes without rebroadcast', () async {
    final m = Memory(), n = Node()..accepted = true, s = await setup(m, n);
    expect(await s.submit(address, receipt()), own);
    expect(n.sends, 0);
    expect(await s.pending(address), isNull);
  });
  test('read-only accepted check completes and records one asset entry',
      () async {
    final m = Memory(), n = Node()..accepted = true, s = await setup(m, n);
    expect(await s.checkSaved(address, receipt()), KronRecoveryState.confirmed);
    final rows = await ActivityStore(encryptedStore: m).load(address);
    expect(rows.length, 1);
    expect(rows.single.id, own);
    expect(n.sends, 0);
  });
  test('resubmit uses byte-identical saved transaction', () async {
    final m = Memory(), n = Node(), s = await setup(m, n);
    expect(await s.submit(address, receipt()), own);
    expect(n.sent, receipt()['signedTxJson']);
    expect(n.sends, 1);
  });
  test('lost broadcast response resolves accepted swap without duplicate',
      () async {
    final m = Memory(), n = Node()..late = true, s = await setup(m, n);
    expect(await s.submit(address, receipt()), own);
    expect(n.sends, 1);
    expect(await s.pending(address), isNull);
  });
  test(
      'exact accepted conflict archives original signed bytes, frees active slot',
      () async {
    final m = Memory(),
        n = Node(),
        s = await setup(m, n, client: history(conflict: true));
    expect(await s.checkSaved(address, receipt()), KronRecoveryState.obsolete);
    expect(await s.pending(address), isNull);
    expect(n.sends, 0);
    final archive =
        jsonDecode(m.values['${KronDexService.key(address)}_last_obsolete']!);
    expect(archive['signedTxJson'], receipt()['signedTxJson']);
    expect(archive['conflictingTransactionId'], competing);
  });
  test('orphan rejection with exact conflict releases UI via typed result',
      () async {
    final m = Memory(),
        n = Node()..reject = true,
        s = await setup(m, n, client: history(conflict: true));
    await expectLater(
        s.submit(address, receipt()), throwsA(isA<KronSwapObsolete>()));
    expect(await s.pending(address), isNull);
  });
  for (final mode in [
    'empty',
    'unaccepted',
    'wrong-index',
    'missing',
    'rate-limit'
  ]) {
    test('$mode never discards a saved signed swap', () async {
      final m = Memory(),
          n = Node(),
          s = await setup(m, n,
              client: history(
                  conflict: mode != 'empty',
                  accepted: mode != 'unaccepted',
                  index: mode == 'wrong-index' ? 2 : 1,
                  missing: mode == 'missing',
                  unavailable: mode == 'rate-limit'));
      try {
        expect(
            await s.checkSaved(address, receipt()), KronRecoveryState.pending);
      } catch (e) {
        expect(e, isA<StateError>());
      }
      expect((await s.pending(address))!['signedTxJson'],
          receipt()['signedTxJson']);
      expect(n.sends, 0);
    });
  }
  test('temporary parent absence and rejected broadcast preserve retry bytes',
      () async {
    final m = Memory(), n = Node()..reject = true, s = await setup(m, n);
    await expectLater(s.submit(address, receipt()), throwsStateError);
    expect((await s.pending(address))!['signedTxJson'], n.sent);
    n.reject = false;
    await s.submit(address, receipt());
    expect(n.sends, 2);
    expect(await s.pending(address), isNull);
  });
  test('completion discovered during conflict lookup wins over retirement',
      () async {
    final m = Memory(),
        n = Node(),
        s = await setup(m, n,
            client: history(conflict: true, onProof: () => n.accepted = true));
    expect(await s.checkSaved(address, receipt()), KronRecoveryState.confirmed);
    expect(m.values.keys.any((k) => k.endsWith('_last_obsolete')), false);
  });
  test('archive write failure preserves active receipt', () async {
    final m = Memory(),
        n = Node(),
        s = await setup(m, n, client: history(conflict: true));
    m.archiveFails = true;
    await expectLater(s.checkSaved(address, receipt()), throwsStateError);
    expect(await s.pending(address), isNotNull);
  });
  test('own-node status outage prevents rebroadcast and preserves receipt',
      () async {
    final m = Memory(), n = Node()..failStatus = true, s = await setup(m, n);
    await expectLater(s.submit(address, receipt()), throwsStateError);
    expect(n.sends, 0);
    expect(await s.pending(address), isNotNull);
  });
  test('second receipt cannot overwrite pending swap or operate on it',
      () async {
    final m = Memory(),
        n = Node(),
        s = await setup(m, n),
        other = {...receipt(), 'transactionId': 'e' * 64};
    await expectLater(s.retain(address, other), throwsStateError);
    await expectLater(s.submit(address, other), throwsStateError);
    expect((await s.pending(address))!['transactionId'], own);
    expect(n.sends, 0);
  });
  test('parallel recovery is rejected while original check remains active',
      () async {
    final m = Memory(), n = Node(), s = await setup(m, n);
    n.paused = Completer<void>();
    final first = s.checkSaved(address, receipt());
    await expectLater(s.submit(address, receipt()), throwsStateError);
    n.paused!.complete();
    await first;
    expect(n.sends, 0);
  });
}
