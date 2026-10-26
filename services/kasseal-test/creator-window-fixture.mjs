// Public deterministic key 1 and synthetic outpoints only. Never broadcast.
import * as sdk from '@kassealhq/sdk/node';
import {signingRequest,NETWORK} from './planner.mjs';
const k=sdk.sdk(),address=new k.PrivateKey('1'.padStart(64,'0')).toAddress(NETWORK).toString();
const owner=sdk.xOnlyKeyOfAddress(address),T='cc'.repeat(32),C='bb'.repeat(32);
const ctx=sdk.curveBasesOf(NETWORK).find(c=>sdk.hasCreatorWindow(c.curve));
const spk=Buffer.from(k.payToAddressScript(new k.Address(address)).script,'hex');
const state={tokenCovId:Buffer.from(T,'hex'),lotsSold:0n,feeAccrued:0n,phase:1};
const supply=sdk.covenantOwnedToken(ctx.curve.params.curveLots*ctx.curve.params.lot,C);
const cell=(id,covenantId,redeemScript,state,amount,templateHash)=>({outpoint:{txid:id.repeat(32),index:0},covenantId,redeemScript,state,amount,templateHash,confirmed:true});
const source={
  funding:async()=>[{outpoint:{txid:'aa'.repeat(32),index:0},amount:100_000_000_000n,spk,daaScore:123n,address}],
  curveHead:async()=>cell('ee',C,sdk.curveProgram(ctx.curve,state),state,100_000_000n,ctx.curve.templateHash),
  covenantCells:async()=>({supply:cell('dd',T,sdk.tokenProgram(ctx.token,supply),supply,ctx.curve.params.tokenCellKas,ctx.token.templateHash)}),
  tokenCells:async()=>[cell('dd',T,sdk.tokenProgram(ctx.token,supply),supply,ctx.curve.params.tokenCellKas,ctx.token.templateHash)],
  feerate:async()=>100n,
};
const lots=10n,q=sdk.buyQuote(ctx.curve.params,0n,lots);
const body={network:NETWORK,address,tokenId:T,side:'buy',rawAmount:String(q.total),minimumReceive:String(lots*ctx.curve.params.lot),maxSpendSompi:String(q.total+700_000_000n)};
const built=await sdk.createTxBuilder({sources:source,networkId:NETWORK}).buildBuy({covenantId:C,expectedCurveId:C,tokenId:T,buyer:address,buyerXOnlyPubkey:owner,lots,proofVerdict:'bound',maxAllIn:BigInt(body.maxSpendSompi),maxKasIn:q.total});
const context={proof:{T,C},token:{meta:{ticker:'CREATOR_WINDOW_FIXTURE'}},quote:{network:NETWORK,tokenId:T,marketId:C,venue:'curve',side:'buy',rawAmount:body.rawAmount,tokenAmount:String(lots*ctx.curve.params.lot),kasSompi:String(q.total),protocolFeeSompi:String(q.fee)}};
console.log(JSON.stringify(signingRequest(body,context,built).request,null,2));
