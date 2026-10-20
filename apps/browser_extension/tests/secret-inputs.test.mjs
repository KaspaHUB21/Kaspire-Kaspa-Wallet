import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import init, * as rawCore from './generated/wasm/kaspa_secure_core.mjs';
import { secureCore, secretArguments } from './generated/secretInputs.mjs';

const exports = await init({ module_or_path: await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm', import.meta.url)) });
const core = secureCore(rawCore, exports.memory);

test('every registered secret entry is exported by the actual WASM artifact',()=>{
  assert.equal(rawCore.secretBoundaryVersion(),1);
  for(const name of Object.keys(secretArguments))assert.equal(typeof rawCore[name],'function',name);
});

test('native derived keys are wiped and freed even when copying to JS fails',()=>{
  let wiped=false,freed=false;
  const wrapped=secureCore({deriveBackupKey(){return{pointer:()=>exports.memory.buffer.byteLength+1,wipe:()=>{wiped=true;},free:()=>{freed=true;}};}},exports.memory);
  assert.throws(()=>wrapped.deriveBackupKey('Synthetic password','07'.repeat(32)),RangeError);
  assert(wiped);assert(freed);
});

test('every secret-bearing adapter clears its JS byte buffers on success and exceptions', () => {
  for (const [name, positions] of Object.entries(secretArguments)) {
    for (const fail of [false, true]) {
      let seen;
      const raw = { [name](...args) {
        seen = positions.map(position => args[position]);
        for (const bytes of seen) { assert(bytes instanceof Uint8Array); assert(bytes.some(b=>b!==0)); }
        if (fail) throw Error('synthetic native failure');
        if (name.startsWith('deriveBackupKey')) return { pointer:()=>0, wipe(){}, free(){} };
        return 'public result';
      }};
      const fn = secureCore(raw, new WebAssembly.Memory({initial:1}))[name];
      const args = ['private UTF-8 🔑', 'second secret', 'public hash'];
      if (fail) assert.throws(()=>fn(...args),/synthetic native failure/); else fn(...args);
      for (const bytes of seen) assert(bytes.every(b=>b===0),name);
    }
  }
});

test('failure while validating a later argument still clears earlier secret buffers', () => {
  const original = TextEncoder.prototype.encode, captured=[];
  TextEncoder.prototype.encode=function(value){const b=original.call(this,value);captured.push(b);return b;};
  try {
    const core = secureCore({importWallet(){assert.fail('must not call WASM');}},exports.memory);
    assert.throws(()=>core.importWallet('sensitive phrase',null),/Invalid secret input/);
    assert.equal(captured.length,1); assert(captured[0].every(b=>b===0));
  } finally { TextEncoder.prototype.encode=original; }
});

test('actual WASM wipes owned buffers on invalid UTF-8 and malformed requests, including long inputs', () => {
  // Deliberately non-wallet sentinels: never use actual wallet data in tests.
  for (const kind of ['encoding','request','oversize']) {
    const marker = new TextEncoder().encode('MEMORY-ERASURE-CHECK-4a7b9c2d-'.repeat(10));
    const bytes = new Uint8Array(kind==='oversize'?65537:marker.length+1);bytes.fill(0x61);bytes.set(marker);
    if(kind==='encoding')bytes[bytes.length-1]=0xff;
    try { assert.throws(()=>rawCore.signHiddenKas(bytes,'{','invalid hash')); }
    finally { bytes.fill(0); }
    assert.equal(Buffer.from(exports.memory.buffer).indexOf(marker),-1,kind+' must not leave the input allocation readable');
  }
});

test('derived backup keys are native zeroizing owners, not hex strings', () => {
  const password = new TextEncoder().encode('Kaspire backup UTF-8 🔑 2026');
  const native = rawCore.deriveBackupKeyV3(password,'07'.repeat(32)); password.fill(0);
  const pointer = native.pointer(), copy = new Uint8Array(exports.memory.buffer,pointer,32).slice();
  assert(copy.some(b=>b!==0)); native.wipe();
  assert(new Uint8Array(exports.memory.buffer,pointer,32).every(b=>b===0));
  native.free(); // The allocator may now reuse bytes for free-list metadata.
  const adapted = core.deriveBackupKeyV3('Kaspire backup UTF-8 🔑 2026','07'.repeat(32));
  try { assert(adapted instanceof Uint8Array);assert.deepEqual(adapted,copy); }
  finally { copy.fill(0);adapted.fill(0); }
});

test('WASM error messages do not echo a malformed secret or password', () => {
  const sentinel='NON-WALLET-SENTINEL-SECRET-7c492';
  for(const action of [()=>core.importPrivateKey(sentinel),()=>core.deriveHiddenKas(sentinel,0,0,1),()=>core.deriveBackupKeyV3(sentinel,'bad salt')]){
    assert.throws(action,error=>!String(error).includes(sentinel));
  }
});

test('v2/v3 KDF bytes exactly match the published 0.5.11 artifact, including Unicode and long passwords',()=>{
  // Generated read-only from the released 0.5.11 ZIP, not the new implementation.
  const vectors=[
    ['correct horse battery staple','b5af6a4b543949d5eef52b724c0d80448d1a29b83e5e3de3059296a0d8322f80','0678d548f1a7c3c0d88652f20dcb8ad6fe179a597c0d8480a9a0e78c8d56c15f'],
    ['Unicode pásswörd 🔑 2026','3f93400e6ee805385941762163a4802dff00069d4ff4656fba176f2fc20584ec','7c146629fb8ac8c92246729dbbc038a493799c2e0d26c4066ead9f7ccb4d140f'],
    ['x'.repeat(65537),'9aeb4862eaa46e668906857a909222bd3ba884824ea87e4f6d71153041a16e9a','8f2b238a26941e319cc8cc88100046df71fab4072e221a340ab9039988e672e5'],
  ];
  for(const [password,v2,v3]of vectors)for(const [fn,expected]of [[core.deriveBackupKey,v2],[core.deriveBackupKeyV3,v3]]){
    const bytes=fn(password,'07'.repeat(32));try{assert.equal(Buffer.from(bytes).toString('hex'),expected);}finally{bytes.fill(0);}
  }
});
