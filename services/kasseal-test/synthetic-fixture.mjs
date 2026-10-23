// Public deterministic test key 1, fake outpoints, NEVER broadcast these transactions.
import * as s from '@kassealhq/sdk/node';
import {signingRequest,NETWORK} from './planner.mjs';
const k=s.sdk(),address=new k.PrivateKey('1'.padStart(64,'0')).toAddress(NETWORK).toString();
const owner=s.xOnlyKeyOfAddress(address),T='cc'.repeat(32),P='bb'.repeat(32),ctx=s.curveBasesOf(NETWORK)[0];
const spk=Buffer.from(k.payToAddressScript(new k.Address(address)).script,'hex');
const state={tokenCovId:Buffer.from(T,'hex'),kasScaled:100000n,tokenReserve:400000000n,lpShares:1000000n,
  lpCovId:Buffer.from('dd'.repeat(32),'hex'),feeAccruedScaled:0n,creatorSpk:Buffer.concat([Buffer.alloc(2),spk])};
const cell=(outpoint,covenantId,program,state,amount,templateHash)=>({outpoint,covenantId,redeemScript:program,state,amount,templateHash,confirmed:true});
const sources={
  funding:async()=>[{outpoint:{txid:'aa'.repeat(32),index:0},amount:100_000_000_000n,spk,daaScore:123n,address}],
  poolCell:async()=>cell({txid:'ee'.repeat(32),index:0},P,s.poolProgram(ctx.pool,state),state,100_000_000_000n,ctx.pool.templateHash),
  tokenCells:async(cid,key)=>{const user=key===Buffer.from(owner).toString('hex');const st=user?s.userToken(1_000_000n,owner):s.covenantOwnedToken(state.tokenReserve,P);
    return[cell({txid:(user?'ff':'dd').repeat(32),index:0},T,s.tokenProgram(ctx.token,st),st,500_000_000n,ctx.token.templateHash)];},
  feerate:async()=>100n,
};
const side=process.argv[2];if(!['buy','sell'].includes(side))throw Error('buy or sell required');
const raw=side==='buy'?100_000_000n:1_000_000n;
const p={kasScaled:state.kasScaled,tokenReserve:state.tokenReserve,feeAccruedScaled:0n,dust:0n};
const q=side==='buy'?s.swapKasForTokens(p,s.poolLegForKas(raw)):s.swapTokensForKas(p,raw);
const amount=side==='buy'?q.tokenOut:raw,kas=side==='buy'?raw:q.kasOutScaled*1_000_000n;
const body={network:NETWORK,address,tokenId:T,side,rawAmount:String(raw),minimumReceive:String((side==='buy'?amount:kas)*99n/100n),maxSpendSompi:String(kas+700_000_000n)};
const built=await s.createTxBuilder({sources,networkId:NETWORK}).buildSwap({poolId:P,expectedPoolId:P,tokenId:T,
  trader:address,traderXOnlyPubkey:owner,side:side==='buy'?'kas->tok':'tok->kas',amountIn:side==='buy'?s.poolLegForKas(raw):raw,
  proofVerdict:'bound',...(side==='buy'?{maxAllIn:BigInt(body.maxSpendSompi),minOut:BigInt(body.minimumReceive)}:{minNetOut:BigInt(body.minimumReceive)})});
const context={proof:{T,C:'11'.repeat(32),graduation:{P}},token:{meta:{ticker:'FIXTURE'}},quote:{network:NETWORK,tokenId:T,marketId:P,venue:'pool',side,
  rawAmount:body.rawAmount,tokenAmount:String(amount),kasSompi:String(kas),protocolFeeSompi:String(q.fee.total*1_000_000n),depositSompi:side==='buy'?'500000000':'0'}};
console.log(JSON.stringify(signingRequest(body,context,built).request,null,2));
