import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import * as sdk from '@kassealhq/sdk/node';
import {checkOrder,NETWORK,economics} from './planner.mjs';
import {checkAddress,normalizeEntry} from './node.mjs';
const fixture=JSON.parse(readFileSync('../../crates/kaspa_secure_core/src/fixtures/kasseal-tn10-buy.json','utf8'));
test('Explicit TN10 gate rejects Mainnet and unknown fields at the HTTP boundary',()=>{
 const body={network:NETWORK,address:fixture.sender,tokenId:fixture.tokenId,side:'buy',rawAmount:'100000000'};
 assert.doesNotThrow(()=>checkOrder(body));
 for(const changed of [{network:'mainnet'},{rawAmount:'1.5'},{side:'withdraw'},{address:'kaspa:wrong'}])assert.throws(()=>checkOrder({...body,...changed}));
});
test('SDK integrity pins both contract artifacts and its Rusty-Kaspa binary',()=>{
 assert(sdk.verifyArtifacts().length>0);assert(sdk.verifyKaspaSdk().length>0);assert.equal(sdk.sdk().version(),'2.1.0');
});
test('Whole-token amounts and exact scaled pool math are not mixed with KaspaRocket units',()=>{
 const q=sdk.swapKasForTokens({kasScaled:100000n,tokenReserve:400000000n,feeAccruedScaled:0n,dust:0n},sdk.poolLegForKas(100000000n));
 assert(q.tokenOut>0n);assert.equal(typeof q.tokenOut,'bigint');
 assert.equal(sdk.tokenStateToJson(sdk.userToken(6000n,new Uint8Array(32))).amount,'6000');
});
test('Independent live UTXO serialization includes explicit null or exact covenant ID',()=>{
 const base={outpoint:{transactionId:'a'.repeat(64),index:2},amount:123n,blockDaaScore:456n,isCoinbase:false,
   scriptPublicKey:{version:0,script:'20'+'b'.repeat(64)+'ac'},entry:{}};
 assert.equal(normalizeEntry(base).utxoEntry.covenantId,null);
 assert.equal(normalizeEntry({...base,entry:{covenantId:{toString:()=> 'c'.repeat(64)}}}).utxoEntry.covenantId,'c'.repeat(64));
 assert.equal(normalizeEntry(base).utxoEntry.blockDaaScore,'456');
 assert.doesNotThrow(()=>checkAddress(fixture.sender));
 for(const address of ['kaspa:invalid','https://evil.invalid',null])assert.throws(()=>checkAddress(address));
});
test('Large wallet funding change is never counted as sale proceeds',()=>{
 const base=100000000000000n,net=23085304605n;
 const built={feeSompi:123n,txJson:JSON.stringify({inputs:[{utxo:{amount:String(base),covenantId:null}},{utxo:{amount:'500000000',covenantId:'a'.repeat(64)}}],
   outputs:[{value:String(base+net),covenant:null}]})};
 const result=economics(built);
 assert.equal(result.walletNetSompi,String(net));assert.equal(result.walletChangeSompi,String(base+net));
});
