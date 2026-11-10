// Chrome-specific I/O only. Trading algorithms are copied from the released
// Android source at build time, not separately reimplemented here.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
export 'dart:typed_data';
import 'package:http/http.dart' as http;

// dart2js has no exact ByteData uint64 API. Covenant state uses BigInt.
BigInt webU64(List<int> bytes,int offset){
  if(offset<0||offset+8>bytes.length)throw const FormatException('Truncated uint64');
  var n=BigInt.zero;for(var i=0;i<8;i++)n|=BigInt.from(bytes[offset+i])<<(8*i);return n;
}
int webDataU64(ByteData data,int offset){
  final n=webU64(data.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes),offset);
  if(n>BigInt.from(9007199254740991))throw const FormatException('Integer exceeds exact browser range');return n.toInt();
}
Uint8List webU64Bytes(BigInt n){
  if(n<BigInt.zero||n>=BigInt.one<<64)throw const FormatException('Invalid uint64');
  return Uint8List.fromList(List.generate(8,(i)=>((n>>(8*i))&BigInt.from(255)).toInt()));
}

@JS('kaspireDexHost')
external JSPromise<JSString> _host(JSString request);

Future<dynamic> host(String operation, [Map body = const {}]) async {
  final result = jsonDecode((await _host(jsonEncode({'operation': operation,
    'body': body}).toJS).toDart).toDart) as Map;
  if(result['ok'] != true) throw PlatformException(code: 'DEX_HOST',message:'${result['error'] ?? 'Extension request failed'}');
  return result['value'];
}
class HostClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final result = await host('http', {'url': request.url.toString(),
      'method':request.method,'headers':request.headers,'body':base64Encode(body)}) as Map;
    return http.StreamedResponse(Stream.value(base64Decode('${result['body']}')),
      result['status'] as int,headers:Map<String,String>.from(result['headers'] as Map));
  }
}
class PlatformException implements Exception {
  PlatformException({required this.code,this.message});
  final String code; final String? message;
  @override String toString()=>message??code;
}
class _Testing {const _Testing();}
const visibleForTesting = _Testing();
class ValueNotifier<T> {
  ValueNotifier(this._value); T _value;
  T get value=>_value;
  set value(T value){_value=value;unawaited(host('progress',{'value':value}).catchError((_){return null;}));}
}
class _RootBundle {
  const _RootBundle();
  Future<String> loadString(String path) async => '${await host('asset',{'path':path})}';
}
const rootBundle = _RootBundle();
class NetworkSettings {
  static bool isTestnet = false;
  static bool isKaspa = true;
}
abstract interface class EncryptedStore {
  Future<String?> read(String key);
  Future<void> write(String key,String value);
  Future<void> delete(String key);
}
class KeystoreEncryptedStore implements EncryptedStore {
  const KeystoreEncryptedStore();
  @override Future<String?> read(String key) async=>await host('storeRead',{'key':key}) as String?;
  @override Future<void> write(String key,String value) async{await host('storeWrite',{'key':key,'value':value});}
  @override Future<void> delete(String key) async{await host('storeDelete',{'key':key});}
}
class NativeSecurity {
  Future<Map<String,Object?>> preparePskt(Map request) async => Map<String,Object?>.from(await host('prepare',{'request':request}) as Map);
  Future<Map<String,Object?>> signPskt(Map request,String hash) async => Map<String,Object?>.from(await host('sign',{'request':request,'hash':hash}) as Map);
}
class KaspaApi {
  KaspaApi({http.Client? client});
  Future<String> broadcastKcc20(String raw,{required String expectedTransactionId}) async => '${await host('broadcast',{'raw':raw,'id':expectedTransactionId})}';
}
// The common Borsh framing/response checks remain in Android's BraidClock.
// This single-frame browser socket replaces dart:io, which is unavailable here.
class WebSocket {
  WebSocket(this.url);
  final String url;
  final _messages=StreamController<dynamic>();
  static Future<WebSocket> connect(String url) async=>WebSocket(url);
  Future<dynamic> get first=>_messages.stream.first;
  Stream<dynamic> where(bool Function(dynamic) test)=>_messages.stream.where(test);
  void add(List<int> frame){unawaited(host('socketFrame',{'url':url,'frame':base64Encode(frame)}).then((r){if(!_messages.isClosed)_messages.add(base64Decode('$r'));}).catchError((Object e,StackTrace s){if(!_messages.isClosed)_messages.addError(e,s);}));}
  Future<void> close()=>_messages.close();
}
class WalletAsset {
  const WalletAsset({required this.symbol,required this.balance,required this.kind,
    this.rawBalance,this.covenantId,this.id,this.decimals=0,this.imageUrl,
    this.standard,this.discoveryComplete=false,this.validationStatus,this.priceKas});
  final String symbol,kind; final double balance; final int decimals;
  final String? rawBalance,covenantId,id,imageUrl,standard,validationStatus;
  final bool discoveryComplete; final double? priceKas;
  Map<String,Object?> toJson()=>{'symbol':symbol,'kind':kind,'rawBalance':rawBalance,
    'covenantId':covenantId,'tokenId':covenantId,'decimals':decimals,'image_url':imageUrl,
    'standard':standard,'discoveryComplete':discoveryComplete,
    'validationStatus':validationStatus,'priceKas':priceKas};
}
