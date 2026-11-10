import 'dart:convert';
import 'dart:js_interop';
import 'driver.dart';
import 'generated/lib/compat.dart';

@JS('kaspireDexInvoke')
external set _invoke(JSFunction value);

Future<JSString> dispatch(JSString raw) async {
  try {
    final input=jsonDecode(raw.toDart) as Map;
    NetworkSettings.isTestnet=input['network']=='testnet-10';
    NetworkSettings.isKaspa=const ['mainnet','testnet-10'].contains(input['network']);
    if(!NetworkSettings.isKaspa)throw StateError('Switch to a Kaspa network.');
    final value=await execute(input);
    return jsonEncode({'ok':true,'value':value}).toJS;
  }catch(error){return jsonEncode({'ok':false,'error':'$error'}).toJS;}
}
void main(){_invoke=((JSString raw)=>dispatch(raw).toJS).toJS;}
