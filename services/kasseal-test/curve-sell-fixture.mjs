// Public key 1, synthetic owner coin. NEVER broadcast.
import * as sdk from '@kassealhq/sdk/node';
import {calculate,signingRequest,NETWORK} from './planner.mjs';
const k=sdk.sdk(),address=new k.PrivateKey('1'.padStart(64,'0')).toAddress(NETWORK).toString();
const body={network:NETWORK,address,tokenId:'3c0719016639f58f7090b2d652eafcc8cc29364cb04fb585097ee2da59385c9e',side:'sell',rawAmount:'10000'};
const ctx=await calculate(body),base=sdk.curveBasesOf(NETWORK)[0];
body.minimumReceive=String(BigInt(ctx.quote.kasSompi)*99n/100n);body.maxSpendSompi=ctx.quote.maxSpendSompi;
const own=Buffer.from(ctx.ownKey).toString('hex');
const sources={...ctx.sources,tokenCells:async(id,key)=>{
  if(key!==own)return ctx.sources.tokenCells(id,key);
  const state=sdk.userToken(10000n,ctx.ownKey);
  return [{outpoint:{txid:'ff'.repeat(32),index:0},covenantId:body.tokenId,state,
    redeemScript:sdk.tokenProgram(base.token,state),amount:250_000_000n,templateHash:base.token.templateHash,confirmed:true}];
},funding:async()=>[{outpoint:{txid:'aa'.repeat(32),index:0},amount:100_000_000_000n,
  spk:Buffer.from(k.payToAddressScript(new k.Address(address)).script,'hex'),daaScore:123n,address}]};
const built=await sdk.createTxBuilder({sources,networkId:NETWORK}).buildSell({covenantId:ctx.proof.C,expectedCurveId:ctx.proof.C,
  tokenId:body.tokenId,seller:address,sellerXOnlyPubkey:ctx.ownKey,lots:ctx.lots,expectedTokens:10000n,proofVerdict:'bound',minNetOut:BigInt(body.minimumReceive)});
console.log(JSON.stringify(signingRequest(body,ctx,built).request,null,2));
