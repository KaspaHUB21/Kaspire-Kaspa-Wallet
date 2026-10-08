import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {nexusConnected,nexusDisconnect,nexusRequest,nexusSetSession,nexusRestoreSession,validateNexusChallenge} from './generated/nexus.mjs';
const context={address:'kaspa:test',generation:1,revision:1};
test('Nexus login only accepts the known domain and wallet',()=>{
  const nonce='a'.repeat(43),expiresAt=new Date(Date.now()+300000).toISOString(),message=`Kaspire Internal NFT Offers\n\nDomain: kaspire.kaslab.space\nPurpose: internal-private-offers-v1\nWallet: ${context.address}\nNonce: ${nonce}\nIssued at: ${new Date().toISOString()}\nExpires at: ${expiresAt}\n\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\nThis signature does not create a transaction or spend funds.`;
  assert.equal(validateNexusChallenge(context.address,{nonce,expiresAt,message}),message);
  assert.throws(()=>validateNexusChallenge('kaspa:other',{nonce,expiresAt,message}));
  assert.throws(()=>validateNexusChallenge(context.address,{nonce,expiresAt,message:message.replace('kaspire.kaslab.space','evil.example')}));
  assert.throws(()=>validateNexusChallenge(context.address,{nonce,expiresAt,message:message.replace('internal-private-offers-v1','website-login')}));
  assert.throws(()=>validateNexusChallenge(context.address,{nonce,expiresAt,message:message.replace('Authenticate this wallet','Send all funds and authenticate this wallet')}));
  assert.throws(()=>validateNexusChallenge(context.address,{nonce,expiresAt,message:`NFT Offer Relay Login\n\nDomain: kaspanftnexus.com\nWallet: ${context.address}\nNonce: ${nonce}\nIssued at: ${new Date().toISOString()}\nExpires at: ${expiresAt}\n\nSign this message to access your private offer dashboard.\nThis signature does not create a transaction or spend funds.`}));
  assert.throws(()=>validateNexusChallenge(context.address,{nonce,expiresAt:'2000-01-01',message}));
  const futureIssued=new Date(Date.now()+60000).toISOString(),futureExpires=new Date(Date.now()+360000).toISOString();
  const future=message.replace(/Issued at: [^\n]+/,`Issued at: ${futureIssued}`).replace(/Expires at: [^\n]+/,`Expires at: ${futureExpires}`);
  assert.equal(validateNexusChallenge(context.address,{nonce,expiresAt:futureExpires,message:future}),future);
});
test('notification session survives worker suspension only in trusted session RAM, bound to unlocked wallet',async()=>{
 const previous=globalThis.chrome;let saved={},access='';
 globalThis.chrome={storage:{session:{setAccessLevel:async({accessLevel})=>{access=accessLevel;},set:async(value)=>{saved=value;},get:async()=>saved,remove:async()=>{saved={};}}}};
 try {
  nexusSetSession(context,{walletAddress:context.address,token:'test.bearer'});
  await new Promise(resolve=>setTimeout(resolve,0));nexusDisconnect();
  assert.equal(await nexusRestoreSession({...context,address:'kaspa:other'}),false);
  assert.equal(await nexusRestoreSession({...context,generation:2}),true);
  assert.equal(access,'TRUSTED_CONTEXTS');assert.equal(nexusConnected({...context,generation:2}),true);
 }finally{globalThis.chrome=previous;nexusDisconnect();}
});
test('native Nexus authentication does not create an external dApp approval',()=>{
  const background=readFileSync(new URL('../src/background/index.ts',import.meta.url),'utf8');
  const start=background.indexOf("if(message.command==='nexusConnect'||message.command==='nexusPoll')");
  const internal=background.slice(start,background.indexOf("if(message.command==='nexusPoll')",start));
  assert.ok(internal.includes('validateNexusChallenge'));
  assert.ok(internal.includes('await guard()'));
  assert.ok(!internal.includes('approve('));
  assert.ok(!internal.includes('kaspanftnexus.com'));
});
test('automatic private-offer authentication stays limited to the unlocked internal feature',()=>{
  const background=readFileSync(new URL('../src/background/index.ts',import.meta.url),'utf8');
  const start=background.indexOf("if(message.command==='nexusConnect'||message.command==='nexusPoll')");
  assert(start>=0);
  const internal=background.slice(start,background.indexOf("if(message.command==='nexusStatus')",start));
  assert(internal.includes('validateNexusChallenge(address,challenge)'));
  assert(internal.includes('entry.watchOnly'));
  assert(internal.includes('await guard();nexusSetSession(context,result)'));
  const native=readFileSync(new URL('../../mobile_flutter/android/app/src/main/kotlin/space/kasvault/wallet/MainActivity.kt',import.meta.url),'utf8');
  assert(native.includes('internalNexusUnlocked && lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)'));
  assert(native.includes('check(validInternalNexusBinding('));
  assert(native.includes('requireAuthorization(call, call.method, "$address\\u0000$message")'));
  assert(native.includes('Purpose: internal-private-offers-v1'));
});
test('private Nexus token is memory-only and bound to lock, account and network generations',()=>{
  for(const mutation of [{address:'kaspa:other'},{generation:2},{revision:2}]){
    nexusSetSession(context,{walletAddress:context.address,token:'test.bearer'});
    assert.equal(nexusConnected(context),true);
    assert.equal(nexusConnected({...context,...mutation}),false);
  }
  nexusSetSession(context,{walletAddress:context.address,token:'test.bearer'});nexusDisconnect();assert.equal(nexusConnected(context),false);
});
test('private requests require login, use pinned origin and never forward arbitrary paths',async()=>{
  nexusDisconnect();await assert.rejects(nexusRequest(context,'offers',{},{}),/Unlock your wallet/);
  await assert.rejects(nexusRequest(context,'../../secret'),/Invalid Nexus request/);
  const original=globalThis.fetch;let seen;
  try{globalThis.fetch=async(url,init)=>{seen={url:String(url),init};return new Response(JSON.stringify([]),{status:200});};
    nexusSetSession(context,{walletAddress:context.address,token:'test.bearer'});await nexusRequest(context,'dashboard/notifications');
    assert.equal(seen.url,'https://kaspire.kaslab.space/nexus-test-v1/dashboard/notifications');assert.equal(seen.init.headers.authorization,'Bearer test.bearer');assert.equal(seen.init.redirect,'error');
    globalThis.fetch=async()=>new Response(JSON.stringify({error:'expired'}),{status:401});await assert.rejects(nexusRequest(context,'dashboard/notifications'),/expired/);assert.equal(nexusConnected(context),false);
  }finally{globalThis.fetch=original;nexusDisconnect();}
});
