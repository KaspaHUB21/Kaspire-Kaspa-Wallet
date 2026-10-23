// Public, unsigned TN10 plans only. Never accept a private key, seed or signed transaction.
import * as sdk from '@kassealhq/sdk/node';
import {NETWORK, API, PREFIX, profile} from './network.mjs';
export {NETWORK, API};
const encode = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v));
export async function get(path) {
  const response = await fetch(API + path, {redirect:'error', signal:AbortSignal.timeout(15000)});
  const body = await response.json();
  if (!response.ok) throw Error(body.detail ?? `Kasseal data unavailable (${response.status})`);
  return body;
}
export function checkOrder(body) {
  if (body.network !== NETWORK || !new RegExp('^'+PREFIX+'[a-z0-9]{61,120}$').test(body.address ?? '') ||
      !/^[a-f0-9]{64}$/.test(body.tokenId ?? '') || !['buy','sell'].includes(body.side) ||
      !/^[1-9][0-9]{0,17}$/.test(body.rawAmount ?? '')) throw Error(`Select ${NETWORK} and enter a valid wallet, token and positive amount.`);
  sdk.xOnlyKeyOfAddress(body.address);
}
export async function proofFor(id) {
  const json = await get(`/tokens/${id}/launch-proof`);
  const verdict = sdk.verifyLaunchProofJson(json, NETWORK);
  if (verdict.status !== 'bound') throw Error(`Kasseal launch proof is ${verdict.status}. Nothing was signed.`);
  const proof = sdk.launchProofFromJson(json);
  if (proof.T !== id) throw Error('Kasseal proof names another token.');
  if (proof.graduation && await sdk.graduationOnChain(json, NETWORK) !== 'confirmed')
    throw Error('Pool graduation could not be independently confirmed on TN10. Retry later.');
  return {json,proof};
}
export async function catalogue(cursor = '') {
  if (cursor.length > 1024) throw Error('Invalid page cursor.');
  return get(`/tokens?sort=active&limit=20${cursor ? '&cursor='+encodeURIComponent(cursor) : ''}`);
}
async function context(body) {
  checkOrder(body);
  const {proof} = await proofFor(body.tokenId);
  const token = await get(`/tokens/${body.tokenId}`);
  const ownKey = sdk.xOnlyKeyOfAddress(body.address);
  const sources = sdk.createApiSources({baseUrl:API, network:NETWORK, tokenId:body.tokenId, ownKey:Buffer.from(ownKey).toString('hex'),
    useTip:false, attempts:2, fetch:(url,init)=>fetch(url,{...init,redirect:'error',signal:AbortSignal.timeout(15000)})});
  return {proof,token,ownKey,sources};
}
export async function calculate(body) {
  const ctx = await context(body), {proof,sources} = ctx, raw = BigInt(body.rawAmount);
  let amountIn, lots, tokens, kas, protocolFee;
  if (proof.graduation) {
    const cell = await sources.poolCell(proof.graduation.P), state = cell.state;
    const p = {kasScaled:state.kasScaled,tokenReserve:state.tokenReserve,feeAccruedScaled:state.feeAccruedScaled,dust:cell.amount%1_000_000n};
    // Pure SDK arithmetic uses the pool's exact live state.
    if (body.side === 'buy') {
      amountIn = sdk.poolLegForKas(raw);
      const q = sdk.swapKasForTokens(p, amountIn);
      tokens = q.tokenOut; kas = amountIn * 1_000_000n; protocolFee = q.fee.total * 1_000_000n;
    } else {
      amountIn = raw;
      const q = sdk.swapTokensForKas(p, raw);
      tokens = raw; kas = q.kasOutScaled * 1_000_000n; protocolFee = q.fee.total * 1_000_000n;
    }
  } else {
    const head = await sources.curveHead(proof.C), params = proof.params;
    const p = {p0:BigInt(params.p0),k:BigInt(params.k),feeBps:BigInt(params.feeBps),curveLots:BigInt(params.curveLots)};
    const lot = BigInt(params.lot);
    if (body.side === 'buy') {
      let low=0n,high=p.curveLots-head.state.lotsSold;
      if (head.state.lotsSold < BigInt(params.openWindowLots)) high = high < BigInt(params.openWindowMaxLots) ? high : BigInt(params.openWindowMaxLots);
      while(low<high){const mid=(low+high+1n)/2n;if(sdk.buyQuote(p,head.state.lotsSold,mid).total<=raw)low=mid;else high=mid-1n;}
      lots=low;if(!lots)throw Error(`Increase the KAS amount: this curve trades in lots of ${lot} tokens.`);
      const q=sdk.buyQuote(p,head.state.lotsSold,lots);tokens=lots*lot;kas=q.total;protocolFee=q.fee;
    } else {
      if(raw%lot!==0n)throw Error(`This curve sells whole lots of ${lot} tokens. Enter a multiple of ${lot}.`);
      lots=raw/lot;const q=sdk.sellQuote(p,head.state.lotsSold,lots);tokens=raw;kas=q.total;protocolFee=q.fee;
    }
  }
  if (typeof tokens!=='bigint' || typeof kas!=='bigint' || tokens<=0n || kas<=0n) throw Error('This amount cannot be traded economically.');
  return {...ctx,lots,amountIn,quote:{network:NETWORK,tokenId:body.tokenId,marketId:proof.graduation?.P ?? proof.C,
    venue:proof.graduation?'pool':'curve',side:body.side,rawAmount:body.rawAmount,tokenAmount:String(tokens),
    kasSompi:String(kas),protocolFeeSompi:String(protocolFee),lotSize:proof.graduation?'1':String(proof.params.lot),depositSompi:body.side==='buy'?'500000000':'0',
    maxSpendSompi:String(kas+500_000_000n+200_000_000n),quoteExpiresAt:Date.now()+120000}};
}
export async function quote(body) { return (await calculate(body)).quote; }
export async function plan(body, sourceOverride) {
  const ctx = await calculate(body), {proof,ownKey,quote:q} = ctx;
  if (!/^[0-9]{1,19}$/.test(body.minimumReceive ?? '') || !/^[1-9][0-9]{0,18}$/.test(body.maxSpendSompi ?? '')) throw Error('Missing reviewed trade limits.');
  const min=BigInt(body.minimumReceive), max=BigInt(body.maxSpendSompi);
  if (BigInt(body.side==='buy'?q.tokenAmount:q.kasSompi)<min) throw Error('Price changed beyond your limit. Refresh the quote.');
  const builder=sdk.createTxBuilder({sources:sourceOverride ?? ctx.sources,networkId:NETWORK});
  let built;
  try {
  if (proof.graduation) {
    built=await builder.buildSwap({poolId:proof.graduation.P,expectedPoolId:proof.graduation.P,tokenId:body.tokenId,
      trader:body.address,traderXOnlyPubkey:ownKey,side:body.side==='buy'?'kas->tok':'tok->kas',amountIn:ctx.amountIn,
      proofVerdict:'bound',...(body.side==='buy'?{maxAllIn:max,minOut:min}:{minNetOut:min})});
  } else if (body.side==='buy') {
    built=await builder.buildBuy({covenantId:proof.C,expectedCurveId:proof.C,tokenId:body.tokenId,buyer:body.address,
      buyerXOnlyPubkey:ownKey,lots:ctx.lots,proofVerdict:'bound',maxAllIn:max,maxKasIn:BigInt(body.rawAmount)});
  } else {
    built=await builder.buildSell({covenantId:proof.C,expectedCurveId:proof.C,tokenId:body.tokenId,seller:body.address,
      sellerXOnlyPubkey:ownKey,lots:ctx.lots,expectedTokens:BigInt(body.rawAmount),proofVerdict:'bound',minNetOut:min});
  }
  } catch(error) {
    if(body.side!=='sell'||body.allowPreparation!==true)throw error;
    if(error.name==='NeedsSplit'||error.errorCode==='NEEDS_SPLIT') {
      built=await builder.buildSplit({covenantId:body.tokenId,owner:body.address,ownerXOnlyPubkey:ownKey,cell:error.cell,carve:BigInt(body.rawAmount)});
      return preparationRequest(body,ctx,built,'split');
    }
    if(error.name==='NeedsConsolidation'||error.errorCode==='NEEDS_CONSOLIDATION') {
      const steps=await builder.buildConsolidate({covenantId:body.tokenId,owner:body.address,ownerXOnlyPubkey:ownKey,target:BigInt(body.rawAmount)});
      if(!steps.length)throw Error('No token preparation step could be built. Refresh the wallet.');
      // Only the first live step is authorized. Later steps are rebuilt after confirmation.
      return preparationRequest(body,ctx,steps[0],'merge');
    }
    throw error;
  }
  return signingRequest(body,ctx,built);
}
export function economics(built) {
  const tx=JSON.parse(built.txJson);
  const plainIn=tx.inputs.filter(i=>!i.utxo?.covenantId).reduce((n,i)=>n+BigInt(i.utxo.amount),0n);
  const plainOut=tx.outputs.filter(o=>!o.covenant).reduce((n,o)=>n+BigInt(o.value),0n);
  return {walletNetSompi:String(plainOut-plainIn),walletChangeSompi:String(plainOut),networkFeeSompi:String(built.feeSompi)};
}
export function preparationRequest(body,ctx,built,operation) {
  const prepared=sdk.prepareSignRequest(built.txJson,built.inputsToSign,{networkId:NETWORK}),outputPrograms={};
  for(const cell of built.optimistic.cells.produced)outputPrograms[cell.outpoint.index]=Buffer.from(sdk.tokenProgram(sdk.loadTokenTemplate(),cell.state)).toString('hex');
  const summary={...ctx.quote,stage:'preparation',operation,minimumReceive:body.minimumReceive,maxSpendSompi:body.maxSpendSompi,
    ...economics(built),maxPreparationDebitSompi:'700000000',outputPrograms};
  return encode({request:{sender:body.address,profile:profile('prepare'),tokenId:body.tokenId,lpCovenantId:ctx.quote.marketId,
    ticker:ctx.token.meta?.ticker||ctx.token.meta?.name||body.tokenId.slice(0,8),side:'sell',txJsonString:prepared.txJson,
    signInputs:prepared.signInputs.map(i=>({...i,expectedSighash:sdk.sighashOfTxJson(prepared.txJson,i.index,1)})),scripts:prepared.prebuilt,tradeSummary:summary},
    proofStatus:'bound',sdkVersion:'0.1.1'});
}
export async function preparationReady(address,tokenId,transactionId) {
  checkOrder({network:NETWORK,address,tokenId,side:'sell',rawAmount:'1'});
  if(!/^[a-f0-9]{64}$/.test(transactionId??''))throw Error('Invalid preparation transaction ID.');
  const key=Buffer.from(sdk.xOnlyKeyOfAddress(address)).toString('hex');
  const data=await get(`/tokens/${tokenId}/cells?owner=${encodeURIComponent('pk:'+key)}`);
  return {ready:data.cells?.some(c=>c.outpoint?.txid===transactionId)===true,network:NETWORK,tokenId,transactionId};
}
export function signingRequest(body,ctx,built) {
  const {proof,quote:q}=ctx;
  const prepared=sdk.prepareSignRequest(built.txJson,built.inputsToSign,{networkId:NETWORK});
  const tx=JSON.parse(prepared.txJson), outputPrograms={};
  for(const cell of built.optimistic.cells.produced) outputPrograms[cell.outpoint.index]=Buffer.from(sdk.tokenProgram(sdk.loadTokenTemplate(),cell.state)).toString('hex');
  if(built.optimistic.curve){
    const i=built.optimistic.curve.toOutpoint.index;
    const input=JSON.parse(built.txJson).inputs.find(i=>i.utxo?.covenantId===proof.C);
    const old=sdk.programFromSigScript(Buffer.from(input.signatureScript,'hex'));
    const next=Buffer.from(old);const state=sdk.encodeCurveState(built.optimistic.curve.state);next.set(state,1);outputPrograms[i]=next.toString('hex');
  }
  if(built.optimistic.pool){
    const i=built.optimistic.pool.toOutpoint.index,input=JSON.parse(built.txJson).inputs.find(i=>i.utxo?.covenantId===proof.graduation.P);
    const next=Buffer.from(sdk.programFromSigScript(Buffer.from(input.signatureScript,'hex')));next.set(sdk.encodePoolState(built.optimistic.pool.state,'v3'),1);outputPrograms[i]=next.toString('hex');
  }
  const summary={...q,stage:'swap',minimumReceive:body.minimumReceive,maxSpendSompi:body.maxSpendSompi,...economics(built),outputPrograms};
  if(body.side==='sell') {
    // Exact native net delta is authoritative; trade income + deposit release - network fee.
    summary.depositRefundSompi=String(BigInt(summary.walletNetSompi)-BigInt(q.kasSompi)+built.feeSompi);
  }
  return encode({request:{sender:body.address,profile:profile('swap'),tokenId:body.tokenId,lpCovenantId:q.marketId,
    ticker:ctx.token.meta?.ticker || ctx.token.meta?.name || body.tokenId.slice(0,8),side:body.side,
    txJsonString:prepared.txJson,signInputs:prepared.signInputs.map(i=>({...i,expectedSighash:sdk.sighashOfTxJson(prepared.txJson,i.index,1)})),
    scripts:prepared.prebuilt,tradeSummary:summary},proofStatus:'bound',sdkVersion:'0.1.1'});
}
