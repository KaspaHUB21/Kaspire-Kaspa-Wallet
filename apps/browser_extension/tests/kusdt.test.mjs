import {test} from 'node:test';
import assert from 'node:assert/strict';
import {pinKusdtToken,KUSDT_COVENANT_ID,KUSDT_TEMPLATE,standardKcc20Token,standardKcc20BorrowedReceive} from './generated/standardKcc20.mjs';
import {psktTokenDetails} from './generated/psktTokenReview.mjs';
const token={covenant_id:KUSDT_COVENANT_ID,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:null,token_units:null};
test('kUSDT missing metadata is pinned to exact mainnet identity and six decimals',async()=>{
 const pinned=pinKusdtToken(token);assert.equal(pinned.metadata.decimals,6);assert.equal(pinned.metadata.symbol,'kUSDT');
 const t=await standardKcc20Token(async()=>({data:token,meta:{network:'mainnet',reference_commit:'c8a087117735a1f87c5c6d115fcddeaf2562c784'}}),KUSDT_COVENANT_ID);
 assert.equal(t.templateHash,KUSDT_TEMPLATE);assert.equal(t.decimals,6);assert.equal(t.standard,'kcc20');
});
test('kUSDT rejects conflicting units and does not promote another covenant or program',()=>{
 assert.throws(()=>pinKusdtToken({...token,token_units:{status:'verified',decimals:8}}),/units differ/);
 assert.throws(()=>pinKusdtToken({...token,metadata:{binding_verified:true,covenant_id:'e'.repeat(64)}}),/covenant differs/);
 const other={...token,covenant_id:'e'.repeat(64)};assert.equal(pinKusdtToken(other),other);
 const altered={...token,template_hash:'e'.repeat(64)};assert.equal(pinKusdtToken(altered),altered);
});
test('kUSDT never borrows recipient states or queries them for borrowing',async()=>{
 assert.equal(await standardKcc20BorrowedReceive(async()=>{throw Error('Must not query');},KUSDT_COVENANT_ID,'e'.repeat(64),1,{},KUSDT_TEMPLATE),undefined);
});
test('web signing surfaces render exact amounts, reserves and incomplete states',()=>{
 const t={ticker:'kUSDT',covenantId:KUSDT_COVENANT_ID,decimals:6,complete:true,outputsBound:true,walletNetRaw:'-1',inputs:[{index:0,amountRaw:'9007199254740991',walletOwned:true,reserveSompi:'150000000'}],outputs:[{index:0,amountRaw:'1',walletOwned:false,reserveSompi:'150000000',signatureBound:true}]};
 const lines=psktTokenDetails({tokenReviews:[t]}).join('\n');
 assert.match(lines,/-0\.000001 kUSDT/);assert.match(lines,/9,007,199,254\.740991 kUSDT/);assert.match(lines,/1\.5 KAS \(not token amount\)/);
 const partial=psktTokenDetails({tokenReviews:[{...t,walletNetRaw:null,complete:false,outputsBound:false}]}).join('\n');
 assert.match(partial,/Unknown does not mean zero/);assert.doesNotMatch(partial,/Draft token balance change: 0/);
 assert.match(psktTokenDetails({tokenReviews:[{...t,outputsBound:false}]}).join('\n'),/NOT FIXED BY THIS SIGNATURE/);
 assert.deepEqual(psktTokenDetails({}),[]);
});
