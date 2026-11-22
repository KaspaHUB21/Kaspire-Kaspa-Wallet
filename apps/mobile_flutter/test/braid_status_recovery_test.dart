import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kasvault_wallet/src/services/braid_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'braid_service_test.dart' show Memory, fixture;

void main() {
  setUp(() => NetworkSettings.network.value = KaspaNetwork.tn10);
  for (final offline in [false,true]) {
    test('independent refund closes stale/failed router status (offline=$offline)', () async {
      final f=fixture(),ctx=Map<String,dynamic>.from(f['tradeSummary'] as Map);
      final owner=ctx['terms']['recipient'];
      ctx.addAll({'fromId':BraidService.zero,'toId':BraidService.tokens[1].id,'minimumOut':'100','amountIn':'1000000000'});
      final dep='11'*32, refund='22'*32;
      final receipt=<String,dynamic>{'ref':'status-test','transactionId':dep,'depositCoinIndex':0,'depositCoinValue':'1000000000','context':ctx,'state':'deposited','signed':{'0':'signature-preserved'}};
      final tx={'transaction_id':refund,'is_accepted':true,'inputs':[{'previous_outpoint_hash':dep,'previous_outpoint_index':0}],
        'outputs':[{'script_public_key':'20${owner}ac','amount':'999000000'}]};
      var posts=0;
      final memory=Memory(),svc=BraidService(store:memory,client:MockClient((r)async{
        if(r.method!='GET')posts++;
        if(r.url.path.endsWith('/status'))return http.Response(jsonEncode(offline?{'error':'offline'}:{'ref':'status-test','state':'deposited'}),offline?503:200);
        if(r.url.path.endsWith('/full-transactions'))return http.Response(jsonEncode([tx]),200);
        if(r.url.path.endsWith('/transactions/$refund'))return http.Response(jsonEncode(tx),200);
        return http.Response('{}',404);
      }));
      final status=await svc.status('${f['sender']}',receipt);
      expect(status['state'],'refunded');expect(receipt['verifiedFinal'],true);
      expect(posts,0);expect(receipt['signed'],{'0':'signature-preserved'});
      final reopened=BraidService(store:memory);
      expect(await reopened.pending('${f['sender']}'),isNull);
      expect((await reopened.saved('${f['sender']}')).single['verifiedFinal'],true);
    });
  }
  test('wrong accepted spender cannot close a receipt; expiry is not completion',()async{
    final f=fixture(),ctx=Map<String,dynamic>.from(f['tradeSummary'] as Map);
    ctx.addAll({'fromId':BraidService.zero,'toId':BraidService.tokens[1].id,'minimumOut':'100','amountIn':'1000000000'});
    final receipt=<String,dynamic>{'ref':'status-test','transactionId':'11'*32,'depositCoinIndex':0,'depositCoinValue':'1000000000','context':ctx,'state':'deposited','signed':{'0':'kept'}};
    final svc=BraidService(store:Memory(),client:MockClient((r)async{
      if(r.url.path.endsWith('/status'))return http.Response(jsonEncode({'ref':'status-test','state':'deposited'}),200);
      if(r.url.path.endsWith('/full-transactions'))return http.Response(jsonEncode([{'transaction_id':'22'*32,'is_accepted':true,'inputs':[{'previous_outpoint_hash':'33'*32,'previous_outpoint_index':0}]}]),200);
      if(r.url.path.endsWith('/info/blockdag'))return http.Response(jsonEncode({'virtualDaaScore':'700000000'}),200);
      return http.Response('{}',404);
    }));
    await svc.status('${f['sender']}',receipt);
    expect(receipt['verifiedFinal'],isNot(true));expect(receipt['recoveryAvailable'],true);
    expect((await svc.pending('${f['sender']}'))?['signed'],{'0':'kept'});
  });
}
