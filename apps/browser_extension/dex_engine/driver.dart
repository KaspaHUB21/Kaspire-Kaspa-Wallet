import 'dart:convert';
import 'dart:math';
import 'generated/lib/compat.dart';
import 'generated/lib/services/kforge_service.dart';
import 'generated/lib/services/kforge_trading.dart';
import 'generated/lib/services/kasforge_service.dart';
import 'generated/lib/services/kasforge_trading.dart';
import 'generated/lib/services/braid_service.dart';
import 'generated/lib/kaspa_address.dart';

final _plans=<String,Map<String,dynamic>>{};
final _quotes=<String,Map<String,dynamic>>{};
String keep(Map<String,Map<String,dynamic>> cache,Map value,Map input){
  if(cache.length>100)cache.remove(cache.keys.first);
  final id=List.generate(24,(_)=>Random.secure().nextInt(256).toRadixString(16).padLeft(2,'0')).join();
  cache[id]={'address':input['address'],'network':input['network'],'venue':input['venue'],
    'at':DateTime.now().millisecondsSinceEpoch,'value':Map<String,dynamic>.from(value)};return id;
}
Map<String,dynamic> take(Map<String,Map<String,dynamic>> cache,Object? id,Map input,{bool remove=false}){
  final saved=remove?cache.remove(id):cache[id];
  if(saved==null||saved['address']!=input['address']||saved['network']!=input['network']||saved['venue']!=input['venue']||
    DateTime.now().millisecondsSinceEpoch-(saved['at'] as int)>60000)throw StateError('Quote/review expired. Refresh quote; no new payment was signed.');
  return Map<String,dynamic>.from(saved['value'] as Map);
}
BigInt amount(String text,int decimals){
  if(!RegExp(r'^(0|[1-9][0-9]*)(\.[0-9]+)?$').hasMatch(text)||text.length>80)throw StateError('Enter a positive amount using a decimal point.');
  final parts=text.split('.'),fraction=parts.length==2?parts[1]:'';
  if(fraction.length>decimals)throw StateError('Too many decimal places.');
  final raw=BigInt.parse(parts[0]+fraction.padRight(decimals,'0'));
  if(raw<=BigInt.zero)throw StateError('Enter a positive amount.');return raw;
}
Map tokenK(KForgeToken t)=>{'id':t.id,'symbol':t.symbol,'name':t.name,'logo':t.logo,'curve':t.curve,'pool':t.pool,'graduated':t.graduated,'priceKas':t.priceKas,'marketCapKas':t.marketCapKas,'volume24hKas':t.volume24hKas,'market':t.market,'decimals':0};
Map tokenF(KasForgeToken t)=>{'id':t.id,'symbol':t.symbol,'name':t.name,'logo':t.logo,'decimals':t.decimals,'priceKas':t.priceKas,'graduated':t.graduated,'marketCapKas':t.marketCapKas,'volume24hKas':t.volume24hKas,'network':t.network,'activeMarket':t.activeMarket};
Map tokenB(BraidToken t)=>{'id':t.id,'symbol':t.symbol,'kind':t.kind,'template':t.template,'prefix':t.prefix,'suffixLength':t.suffixLength,'codeHash':t.codeHash,'decimals':t.isKas?8:t.decimals};
Future<Map<String,Object?>> publicBalance(HostClient client,String address)async{
  try{final base=NetworkSettings.isTestnet?'https://api-tn10.kaspa.org':'https://kaspire.kaslab.space/api/local-node';
    final r=await client.get(Uri.parse('$base/addresses/${Uri.encodeComponent(address)}/balance'));final body=jsonDecode(r.body);
    if(r.statusCode!=200||body is! Map||!RegExp(r'^\d+$').hasMatch('${body['balance']}'))throw StateError('Unavailable balance');
    return {'balanceSompi':'${body['balance']}'};
  }catch(_){return {'balanceSompi':null};}
}
Future<Map<String,dynamic>> findSaved(Future<List<Map<String,dynamic>>> task,Object? id,String key)async{
  final rows=await task;return rows.singleWhere((r)=>r[key]==id,orElse:()=>throw StateError('Saved receipt was not found. Reopen activity.'));
}
Future<Object?> execute(Map input)async{
  NetworkSettings.isTestnet=input['network']=='testnet-10';NetworkSettings.isKaspa=const ['mainnet','testnet-10'].contains(input['network']);
  if(!NetworkSettings.isKaspa)throw StateError('Select a Kaspa network.');
  final client=HostClient(),address='${input['address']}',venue=input['venue'],action=input['action'],a=Map<String,dynamic>.from(input['args'] as Map? ?? {});
  // Build/package regressions compare this public vector with the Kaspa SDK.
  if(action=='selfTest')return {'owner':kaspaOwnerIdFromAddress(address),
    'address':kaspaAddressFromOwnerId(kaspaOwnerIdFromAddress(address)),
    'feeOwner':BraidService.feeOwner,'feeAddress':BraidService(client:client).feeAddress,
    'wideIntegerLimit':'${BigInt.one << 52}',
    'wideState':'${webU64(webU64Bytes(BigInt.parse('9223372036854775807')),0)}',
    'publicDigest':BraidService.digest([1,2,3,255])};
  if(venue=='kforge'){
    final service=KForgeService(client:client),trading=KForgeTrading(client:client);
    if(action=='tokens')return (await service.catalogue()).map(tokenK).toList();
    if(action=='assets')return (await service.walletAssets(address,onProgress:(rows){host('assets',{'items':rows.map((a)=>a.toJson()).toList()});})).map((a)=>a.toJson()).toList();
    if(action=='saved')return trading.saved(address);
    if(action=='context'){
      final saved=await trading.saved(address);List? assets;String? warning;
      try{assets=(await service.walletAssets(address)).map((a)=>a.toJson()).toList();}catch(e){warning='$e';}
      return {...await publicBalance(client,address),'assets':assets,'saved':saved,'warning':warning};
    }
    if(action=='quote'){
      final token=(await service.catalogue()).singleWhere((t)=>t.id==a['tokenId']);
      final side='${a['side']}',plan=await trading.quote(address,token,side,amount('${a['amount']}',side=='buy'?8:0));
      final id=keep(_plans,plan,input);return {'id':id,'review':plan['review'],'token':tokenK(token),'side':side,'summary':(plan['review'] as Map)['tradeSummary'],'rawPlan':plan['request']};
    }
    if(action=='prepare'){final p=take(_plans,a['id'],input);return {'id':a['id'],'review':p['review'],'rawPlan':p['request']};}
    if(action=='submit')return trading.exclusive(address,()async{final p=take(_plans,a['id'],input,remove:true);final r=await trading.sign(address,p);return trading.resume(address,r);});
    if(action=='status'||action=='resume'){final r=await findSaved(trading.saved(address),a['id'],'id');return trading.exclusive(address,()=>trading.resume(address,r,submit:action=='resume'));}
  }else if(venue=='kasforge'){
    final service=KasForgeService(client:client),trading=KasForgeTrading(client:client);
    if(action=='tokens')return (await service.catalogue()).map(tokenF).toList();
    if(action=='assets')return (await service.walletAssets(address)).map((a)=>a.toJson()).toList();
    if(action=='portfolio')return service.portfolio(address);
    if(action=='saved')return trading.saved(address);
    if(action=='context'){
      final saved=await trading.saved(address);Map? portfolio;String? warning;
      try{portfolio=await service.portfolio(address);}catch(e){warning='$e';}
      return {...await publicBalance(client,address),'saved':saved,'portfolio':portfolio,'warning':warning,
        'activity':KasForgeService.activityRows((portfolio?['activity'] as List? ?? []).whereType<Map>().toList(),saved)};
    }
    if(action=='quote'){
      final token=(await service.catalogue()).singleWhere((t)=>t.id==a['tokenId']),q=await service.quote(token,'${a['side']}','${a['amount']}');
      final id=keep(_quotes,q,input);return {...q,'id':id,'token':tokenF(token)};
    }
    if(action=='prepare'){
      final q=take(_quotes,a['id'],input),token=(await service.catalogue()).singleWhere((t)=>t.id==q['tokenId']);
      final r=await trading.build(address,token,'${q['side']}','${q['localAmount']}',q),id=keep(_plans,r,input);
      return {'id':id,'token':tokenF(token),'summary':r['summary'],'reviews':r['reviews'],'rawPlan':r['requests']};
    }
    if(action=='submit')return trading.exclusive(address,()async{
      final r=take(_plans,a['id'],input,remove:true);await trading.sign(address,r);await trading.submit(address,r);
      try{await trading.status(address,r);}catch(e){r['statusWarning']='$e';}return r;
    });
    if(action=='status'||action=='resume'||action=='recover')return trading.exclusive(address,()async{
      final r=await findSaved(trading.saved(address),a['id'],'buildId');
      if(action=='recover')await trading.cancelAndSubmit(address,r);
      if(action=='resume'&&r['finalVerified']!=true){
        if(r['cancelSigned']!=null||r['recoveryPreparationId']!=null)await trading.cancelAndSubmit(address,r);
        else{await trading.sign(address,r);await trading.submit(address,r);}
      }
      await trading.status(address,r);return r;
    });
  }else if(venue=='braid'){
    final service=BraidService(client:client),native=NativeSecurity();
    BraidToken token(Object? id)=>BraidService.tokens.singleWhere((t)=>t.id==id);
    if(action=='tokens')return BraidService.tokens.map(tokenB).toList();
    if(action=='info')return service.info();
    if(action=='saved')return service.saved(address);
    if(action=='context')return {...await publicBalance(client,address),'saved':await service.saved(address)};
    if(action=='notes')return service.notes(address,token(a['tokenId']));
    if(action=='quote'){
      final from=token(a['from']),to=token(a['to']),raw=amount('${a['amount']}',from.isKas?8:from.decimals??0).toString();
      final q=await service.quote(address,from,to,raw,100),id=keep(_quotes,q,input);
      return {...q,'id':id,'fromToken':tokenB(from),'toToken':tokenB(to)};
    }
    if(action=='prepare'){
      final q=take(_quotes,a['id'],input),r=await service.build(address,q),review=await native.preparePskt(Map<String,Object?>.from(r['request'] as Map));
      if(r['build']['depositTxid']!=null&&r['build']['depositTxid']!=review['transactionId'])throw StateError('Deposit ID differs from the native transaction. Nothing was signed.');
      r['review']=review;final id=keep(_plans,r,input);return {'id':id,'quote':q,'review':review,'rawPlan':r['request']};
    }
    if(action=='submit')return service.exclusive(address,()async{
      final r=take(_plans,a['id'],input,remove:true),request=Map<String,Object?>.from(r['request'] as Map),review=r['review'] as Map,b=r['build'] as Map;
      await service.beforeSigning(address,r);await service.retain(address,r);
      final signed=await native.signPskt(request,'${review['reviewHash']}'),tx=jsonDecode('${signed['signedTxJson']}') as Map;
      final signatures=<String,String>{};
      for(final selector in request['signInputs'] as List){final i=(selector as Map)['index'] as int,script='${tx['inputs'][i]['signatureScript']}';
        final templates=(request['scripts'] as List).whereType<Map>().where((t)=>t['inputIndex']==i).toList(),bytes=BraidService.bytes(script);
        final List<int> sig;
        if(templates.isNotEmpty&&templates.single['signatureOffsets'] is List){final at=(templates.single['signatureOffsets'] as List).single as int;sig=bytes.sublist(at,at+65);}else{final pushes=BraidService.pushes(script);if(pushes.isEmpty)throw StateError('Native signature missing.');sig=pushes.first.data;}
        if(sig.length!=65||sig.last!=1)throw StateError('Native signer did not return SIGHASH_ALL.');signatures['$i']=BraidService.hex(sig);
      }
      final raw=jsonDecode('${request['txJsonString']}') as Map;
      r.addAll({'signed':signatures,'signedTransaction':signed['wrpcJson'],'transactionId':signed['transactionId'],
        'depositCoinIndex':b['coinIdx'],'depositCoinValue':'${raw['outputs'][b['coinIdx']]['value']}',
        'depositNoteIndex':b['noteIdx'],'depositNoteValue':b['noteValue'],'depositNoteRedeem':(b['tokRedeems'] as Map?)?['note'],'state':'signed'});
      await service.retain(address,r);await service.submit(address,r);try{await checkBraid(service,address,r);}catch(e){r['statusWarning']='$e';}return r;
    });
    if(action=='status'||action=='resume'||action=='recover')return service.exclusive(address,()async{
      final r=await findSaved(service.saved(address),a['id'],'ref');
      if(action=='resume')await service.submit(address,r);
      if(action=='recover'){
        if(r['recoverySigned']==null){final request=await service.reclaim(address,r),review=await native.preparePskt(request);
          r['recoverySigned']=await native.signPskt(request,'${review['reviewHash']}');await service.retain(address,r);}
        await service.submitRecovery(address,r);
      }
      await checkBraid(service,address,r);return r;
    });
  }
  throw StateError('Unsupported DEX command.');
}
Future<void> checkBraid(BraidService service,String address,Map<String,dynamic> r)async{
  if(r['recoverySigned'] is Map){try{await service.verifyFinal(address,r,{'state':'reclaimed','reclaim':{'txid':r['recoverySigned']['transactionId']}});r['verifiedFinal']=true;r['state']='reclaimed';await service.retain(address,r);return;}catch(_){/* Preserve exact pending recovery. */}}
  await service.status(address,r);
}
