import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
// Copy only public, released application algorithms. No partner kits, private
// artifacts, mobile wallet storage or Flutter runtime is bundled.
const root=resolve('dex_engine'),source=resolve('../mobile_flutter/lib/src');
const names=['braid_service','braid_clock','braid_pool_reader','braid_pool_pins','kforge_service','kforge_trading','kasforge_service','kasforge_trading','swap_conflict_lookup'];
await fs.mkdir(root+'/generated/lib/services',{recursive:true});
const provenance={};
for(const name of names){
  const original=await fs.readFile(`${source}/services/${name}.dart`,'utf8');
  provenance[name]=createHash('sha256').update(original).digest('hex');
  let text=original.replace(/^import '(?:package:flutter\/(?:foundation|services)\.dart|dart:io|native_security\.dart|encrypted_store\.dart|network_settings\.dart|kaspa_api\.dart|\.\.\/models\/wallet_snapshot\.dart)';\n/gm,'');
  text="import '../compat.dart';\n"+text;
  // dart2js bitwise int operations are 32-bit; Android's are 64-bit. Keep
  // these public arithmetic bounds/decoders exact rather than truncating them.
  text=text.replace('BigInt.from(1 << 52)','(BigInt.one << 52)');
  text=text.replace('.fold<int>(0, (sum, e) => sum + (e.value << (8 * e.key))))',
    '.fold<BigInt>(BigInt.zero, (sum, e) => sum + (BigInt.from(e.value) << (8 * e.key))).toInt())');
  text=text.replace(/BigInt\.from\(\s*ByteData\.sublistView\(state\)\.getUint64\(at, Endian\.little\)\)/g,'webU64(state,at)');
  text=text.replace(/final b = ByteData\(8\)\.\.setUint64\(0, (integer\(t\[k\]\)|amount)\.toInt\(\), Endian\.little\);/g,'final b = webU64Bytes($1);');
  if(name==='braid_service')text=text.replaceAll('b.buffer.asUint8List()','b');
  text=text.replace(/(data|p|b)\.getUint64\(([^,]+), Endian\.little\)/g,'webDataU64($1,$2)');
  if(/getUint64|setUint64/.test(text))throw Error(`Review new browser uint64 use in ${name}`);
  await fs.writeFile(`${root}/generated/lib/services/${name}.dart`,text);
}
await fs.copyFile(`${source}/number_format.dart`,`${root}/generated/lib/number_format.dart`);
let address=await fs.readFile(`${source}/kaspa_address.dart`,'utf8');
const polymod=address.indexOf('int _polymod(Iterable<int> values) {');
if(polymod<0)throw Error('Public address checksum source changed; review web port.');
address=address.slice(0,polymod)+`int _polymod(Iterable<int> values) {
  var checksum = BigInt.one;
  final generators = [0x98f2bc8e61,0x79b76d99e2,0xf33e5fb3c4,0xae2eabe2a8,0x1e4f43e470].map(BigInt.from).toList();
  for(final value in values){
    final high=checksum >> 35;
    checksum=((checksum & BigInt.parse('07ffffffff',radix:16)) << 5) ^ BigInt.from(value);
    for(var bit=0;bit<5;bit++)if((high & (BigInt.one << bit))!=BigInt.zero)checksum ^= generators[bit];
  }
  return (checksum ^ BigInt.one).toInt();
}\n`;
address=address.replace('(checksum >> shift) & 0xff','((BigInt.from(checksum) >> shift) & BigInt.from(255)).toInt()');
await fs.writeFile(`${root}/generated/lib/kaspa_address.dart`,address);
await fs.copyFile(root+'/compat.dart',root+'/generated/lib/compat.dart');
const dart=process.env.KASPIRE_DART??'/srv/kaspire/toolchains/flutter/bin/cache/dart-sdk/bin/dart';
execFileSync(dart,['pub','get','--offline'],{cwd:root,stdio:'inherit'});
await fs.mkdir('generated/dex',{recursive:true});
execFileSync(dart,['compile','js','-O2','--csp','main.dart','-o',resolve('generated/dex/engine.js')],{cwd:root,stdio:'inherit'});
await fs.writeFile('generated/dex/provenance.json',JSON.stringify({source:'Android shared trading logic',platformAdaptations:['Chrome host I/O instead of Flutter/Android channels','BigInt for the same 40-bit address checksum and wide public integer shifts/bounds'],files:provenance},null,2)+'\n');
