// Synthetic public key 1 and fake owner outpoints. NEVER broadcast.
import * as sdk from '@kassealhq/sdk/node';
import {preparationRequest,NETWORK} from './planner.mjs';
const k=sdk.sdk(),address=new k.PrivateKey('1'.padStart(64,'0')).toAddress(NETWORK).toString();
const own=sdk.xOnlyKeyOfAddress(address),ctx=sdk.curveBasesOf(NETWORK)[0],T='cc'.repeat(32);
const operation=process.argv[2];if(!['split','merge'].includes(operation))throw Error('split or merge required');
const sources={funding:async()=>[{outpoint:{txid:'aa'.repeat(32),index:0},amount:100_000_000_000n,
  spk:Buffer.from(k.payToAddressScript(new k.Address(address)).script,'hex'),daaScore:123n,address}],
  tokenCells:async()=>Array.from({length:operation==='split'?1:2},(_,i)=>{
    const state=sdk.userToken(operation==='split'?1_000_000n:600_000n,own);
    return {outpoint:{txid:(i?'ee':'ff').repeat(32),index:0},covenantId:T,state,
      redeemScript:sdk.tokenProgram(ctx.token,state),amount:500_000_000n,templateHash:ctx.token.templateHash,confirmed:true};
  }),feerate:async()=>100n};
const builder=sdk.createTxBuilder({sources,networkId:NETWORK});
const amount=operation==='split'?10_000n:1_000_000n;
const common={covenantId:T,owner:address,ownerXOnlyPubkey:own};
const built=operation==='split'?await builder.buildSplit({...common,cell:{txid:'ff'.repeat(32),index:0},carve:amount}):
  (await builder.buildConsolidate({...common,target:amount}))[0];
const body={network:NETWORK,address,tokenId:T,side:'sell',rawAmount:String(amount),minimumReceive:'1',maxSpendSompi:'700000000'};
const context={quote:{network:NETWORK,tokenId:T,marketId:'bb'.repeat(32),side:'sell',rawAmount:String(amount),tokenAmount:String(amount)},token:{meta:{ticker:'FIXTURE'}}};
console.log(JSON.stringify(preparationRequest(body,context,built,operation).request,null,2));
