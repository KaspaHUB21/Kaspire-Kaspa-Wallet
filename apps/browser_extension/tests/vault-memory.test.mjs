import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createVault, decryptVault, createPortableBackup, decryptPortableBackup } from './generated/vault.mjs';

const wasm=await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url));
const password='Synthetic backup password 🔑 2026!',sentinel='NON-WALLET-SECRET-SENTINEL-891d',payload={address:'synthetic-public-address',wallets:[{secret:sentinel}],hiddenKas:{descriptor:'kip22-p2sh-v1',receiveCount:3,changeCount:1,exposed:['0:0','1:0']}};

function observe(t) {
  const originalChrome=globalThis.chrome, stored={},inputs=[],outputs=[];
  const originals={};let rejectEncryption=false;
  globalThis.chrome={runtime:{getURL:()=>wasm},storage:{local:{set:async data=>Object.assign(stored,structuredClone(data))},session:{set:async()=>assert.fail('No plaintext session storage allowed')}}};
  for(const name of ['encrypt','decrypt','importKey']){
    originals[name]=crypto.subtle[name];
    crypto.subtle[name]=async function(...args){
      const value=args[name==='importKey'?1:2];
      if(value instanceof Uint8Array)inputs.push({name,value});
      if(name==='encrypt'&&rejectEncryption)throw Error('synthetic crypto failure');
      const result=await Reflect.apply(originals[name],this,args);
      if(name==='decrypt')outputs.push(new Uint8Array(result));
      return result;
    };
  }
  t.after(()=>{for(const [name,fn]of Object.entries(originals))crypto.subtle[name]=fn;globalThis.chrome=originalChrome;});
  return{stored,inputs,outputs,rejectEncryption:()=>{rejectEncryption=true;}};
}

test('real vault/backup encryption wipes transient keys and plaintext, while persistent storage contains ciphertext only',async t=>{
  const e=observe(t);
  await createVault(password,payload);
  assert.equal(e.stored.encryptedVault.version,2);
  assert(!JSON.stringify(e.stored).includes(sentinel));assert(!JSON.stringify(e.stored).includes(password));
  assert.deepEqual(await decryptVault(e.stored.encryptedVault,password),payload);
  const backup=await createPortableBackup(password,payload);
  assert.equal(backup.format,'kaspire-backup-v3');assert.equal(backup.memoryKiB,65536);assert.equal(backup.iterations,4);
  assert(!JSON.stringify(backup).includes(sentinel));
  assert.deepEqual(await decryptPortableBackup(backup,password),payload);
  await assert.rejects(decryptPortableBackup(backup,'Wrong synthetic password 2026'),/Incorrect password/);
  for(const {name,value}of e.inputs)if(name==='encrypt'||name==='importKey')assert(value.every(b=>b===0),name+' buffer must be wiped');
  assert.equal(e.outputs.length,2);for(const bytes of e.outputs)assert(bytes.every(b=>b===0));
});

test('encryption failure clears its plaintext and publishes no vault',async t=>{
  const e=observe(t);e.rejectEncryption();
  await assert.rejects(createVault(password,payload),/synthetic crypto failure/);
  assert.deepEqual(e.stored,{});
  assert(e.inputs.some(i=>i.name==='encrypt'));
  for(const {value}of e.inputs)assert(value.every(b=>b===0));
});

test('invalid decrypted JSON is wiped and reported without exposing its contents',async t=>{
  const e=observe(t);
  await createVault(password,payload);
  const decrypt=crypto.subtle.decrypt;
  let invalid;
  crypto.subtle.decrypt=async function(...args){const authentic=await Reflect.apply(decrypt,this,args);new Uint8Array(authentic).fill(0);invalid=new TextEncoder().encode('{'+sentinel);return invalid.buffer;};
  await assert.rejects(decryptVault(e.stored.encryptedVault,password),error=>/Incorrect password or damaged vault/.test(error.message)&&!error.message.includes(sentinel));
  assert(invalid.every(b=>b===0));for(const value of e.outputs)assert(value.every(b=>b===0));
});

test('legacy v1 PBKDF2 and v2 Argon2id portable backups still decrypt and wipe plaintext',async t=>{
  const e=observe(t),pwd='correct horse battery staple',salt=new Uint8Array(32).fill(7),iv=new Uint8Array(12).fill(34);
  const base64=bytes=>Buffer.from(bytes).toString('base64');
  for(const version of [1,2]){
    let key;
    if(version===1){
      const encoded=new TextEncoder().encode(pwd);let material;
      try{material=await crypto.subtle.importKey('raw',encoded,'PBKDF2',false,['deriveKey']);}finally{encoded.fill(0);}
      key=await crypto.subtle.deriveKey({name:'PBKDF2',hash:'SHA-256',salt,iterations:600000},material,{name:'AES-GCM',length:256},false,['encrypt']);
    }else{
      // Exact v2 key from the published 0.5.11 binary, not the new adapter.
      const bytes=Uint8Array.from(Buffer.from('b5af6a4b543949d5eef52b724c0d80448d1a29b83e5e3de3059296a0d8322f80','hex'));
      try{key=await crypto.subtle.importKey('raw',bytes,'AES-GCM',false,['encrypt']);}finally{bytes.fill(0);}
    }
    const plaintext=new TextEncoder().encode(JSON.stringify(payload));let encrypted;
    try{encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv},key,plaintext);}finally{plaintext.fill(0);}
    const fixture={format:'kaspire-backup-v'+version,kdf:version===1?'pbkdf2-sha256':'argon2id-v19',iterations:version===1?600000:3,salt:base64(salt),iv:base64(iv),ciphertext:base64(new Uint8Array(encrypted)),...(version===2?{memoryKiB:32768,parallelism:1}:{})};
    assert.deepEqual(await decryptPortableBackup(fixture,pwd),payload);
  }
  assert.equal(e.outputs.length,2);for(const bytes of e.outputs)assert(bytes.every(b=>b===0));
});
