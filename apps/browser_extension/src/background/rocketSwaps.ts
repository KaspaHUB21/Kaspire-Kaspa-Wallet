import { RocketConflict, RocketQuoteExpired, submitRocket, verifyRocketNetwork, type RocketNetwork } from './kasparocket';
import { verifyKronInputs } from './kronDex';
export {RocketConflict, RocketQuoteExpired};

const node = 'https://kaspire.kaslab.space/api/local-node';
export type RocketReceipt = {
  address: string; network: RocketNetwork; token: any; side: 'buy' | 'sell'; poolId: string;
  signed: any[]; transactionIds: string[]; next: number; receipts: any[];
  summary: any; reviews: any[]; plan: any; timestamp: number;
};
export type RocketRecoveryState = { pending?: RocketReceipt; obsolete?: RocketReceipt & {conflictingTransactionId: string; retiredAt: number} };
export type RocketContext = {
  address: string; network: RocketNetwork; binding: string; signal?: AbortSignal;
  guard(): Promise<void>; load(): RocketRecoveryState; save(value: RocketRecoveryState): Promise<void>;
  record(address: string, transaction: any): Promise<void>;
  accepted?(id: string): Promise<boolean>;
};
type NodeRead = (url: string, body?: any, signal?: AbortSignal) => Promise<any>;
export async function rocketNodeJson(url: string, body?: any, signal?: AbortSignal): Promise<any> {
  if (!url.startsWith(node + '/') || body !== undefined) throw Error('Invalid own-node read.');
  const response = await fetch(url, {redirect: 'error', headers: {accept: 'application/json'},
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000)});
  if (!response.ok) throw Object.assign(Error('Own-node swap status is temporarily unavailable. The saved swap is preserved.'), {httpStatus: response.status});
  return response.json();
}
export async function rocketAccepted(id: string, signal?: AbortSignal) {
  if (!/^[a-f0-9]{64}$/.test(id)) throw Error('Invalid saved swap transaction ID.');
  try { const tx = await rocketNodeJson(`${node}/transactions/${id}`, undefined, signal); return tx?.transaction_id === id && tx.is_accepted === true; }
  catch (error) { if ((error as any)?.httpStatus === 404) return false; throw error; }
}
function pending(context: RocketContext): RocketReceipt | undefined {
  const receipt = context.load().pending;
  if (receipt && (receipt.address !== context.address || receipt.network !== context.network ||
      !Array.isArray(receipt.signed) || !receipt.signed.length || receipt.signed.length > 8 ||
      receipt.signed.length !== receipt.transactionIds?.length || !Number.isInteger(receipt.next) ||
      receipt.next < 0 || receipt.next > receipt.signed.length ||
      receipt.transactionIds.some(id => !/^[0-9a-f]{64}$/.test(id)))) throw Error('Invalid saved swap for this wallet/network.');
  return receipt;
}
export function rocketPendingInfo(context: RocketContext) {
  const receipt = pending(context);
  return receipt ? {token: receipt.token, side: receipt.side, transactionIds: receipt.transactionIds, next: receipt.next} : null;
}
export async function confirmedRocketConflict(tx: any, savedIds: Set<string>, get: NodeRead = rocketNodeJson, signal?: AbortSignal) {
  if(!Array.isArray(tx?.inputs)||!tx.inputs.length)throw Error('Invalid saved swap input. The signed transaction remains saved.');
  const inputs = [...tx.inputs];
  if(inputs.length>64)throw new RocketConflictUnknown();
  const groups = new Map<string,Set<string>>(), points=new Set<string>(),origins=new Map<string,any>();
  let incomplete=false,totalPages=0;
  for (const input of inputs) {
    signal?.throwIfAborted();
    // Rocket RPC inputs nest their outpoint. Rust's SDK SafeJSON (Kasseal)
    // stores the exact same fields directly on the input. Read either shape,
    // but never rewrite the saved signed bytes or silently choose conflicting
    // nested/flat identities.
    const nested=input?.previousOutpoint;
    const pointData=nested===undefined?input:nested;
    const originId=pointData?.transactionId,index=pointData?.index;
    if(typeof originId!=='string'||!/^[a-f0-9]{64}$/.test(originId)||!Number.isInteger(index)||index<0||index>0xffffffff||
      nested!==undefined&&(Object.hasOwn(input,'transactionId')&&input.transactionId!==originId||Object.hasOwn(input,'index')&&input.index!==index)||
      points.has(`${originId}:${index}`))throw Error('Invalid saved swap input. The signed transaction remains saved.');
    const point=`${originId}:${index}`;points.add(point);
    let address=input.utxo?.address;
    if(typeof address!=='string'||!/^kaspa:[a-z0-9]+$/.test(address)){
      if(!origins.has(originId)) {
        try{origins.set(originId,await get(`${node}/transactions/${originId}`,undefined,signal));}
        catch(e){if((e as any)?.httpStatus!==404)throw e;origins.set(originId,null);}
      }
      const origin=origins.get(originId);
      if(origin?.transaction_id!==originId||origin.is_accepted!==true){incomplete=true;continue;}
      const outputs=(origin.outputs??[]).filter((o:any)=>o.index===index);
      address=outputs.length===1?outputs[0].script_public_key_address:null;
    }
    if(typeof address!=='string'||!/^kaspa:[a-z0-9]+$/.test(address)){incomplete=true;continue;}
    if(!groups.has(address))groups.set(address,new Set());groups.get(address)!.add(point);
  }
  const spends=(candidate:any)=>Array.isArray(candidate?.inputs)&&candidate.inputs.some((i:any)=>points.has(`${i.previous_outpoint_hash}:${i.previous_outpoint_index}`));
  const checked=new Set<string>();
  for(const address of groups.keys()){
    const pages=new Set<string>();let complete=false;
    for(let page=0;page<20;page++){
      signal?.throwIfAborted();
      if(++totalPages>100){incomplete=true;break;}
      const rows=await get(`${node}/addresses/${encodeURIComponent(address)}/full-transactions?limit=50&offset=${page*50}`,undefined,signal);
      if(!Array.isArray(rows)||rows.length>50)throw Error('Invalid own-node history. The saved swap is preserved.');
      const signature=rows.map(row=>row?.transaction_id).join(',');
      if(rows.length&&pages.has(signature)){incomplete=true;break;}pages.add(signature);
      for(const row of rows){
        const id=row?.transaction_id;
        if(typeof id!=='string'||!/^[a-f0-9]{64}$/.test(id)||savedIds.has(id)||!spends(row)||checked.has(id))continue;
        checked.add(id);
        const confirmed=await get(`${node}/transactions/${id}`,undefined,signal);
        if(confirmed?.transaction_id===id&&confirmed.is_accepted===true&&spends(confirmed))return id;
      }
      if(rows.length<50){complete=true;break;}
    }
    if(!complete)incomplete=true;
  }
  if(incomplete)throw new RocketConflictUnknown();
  return null;
}
export class RocketConflictUnknown extends Error {
  constructor(){super('Unable to determine whether the saved swap is obsolete within the history lookup limit. Its signed transaction remains saved; no replacement was created.');}
}
export async function retireRocketSwap(context: RocketContext,
    findConflict: typeof confirmedRocketConflict = confirmedRocketConflict) {
  await context.guard();
  const receipt = pending(context);
  if (!receipt || receipt.next !== 0) return false;
  const accepted = context.accepted ?? ((id: string) => rocketAccepted(id, context.signal));
  if (await accepted(receipt.transactionIds[0]!)) return false;
  const competing = await findConflict(receipt.signed[0], new Set(receipt.transactionIds), rocketNodeJson, context.signal);
  if (!competing || receipt.transactionIds.includes(competing) || await accepted(receipt.transactionIds[0]!)) return false;
  await context.guard();
  await context.save({obsolete: {...receipt, conflictingTransactionId: competing, retiredAt: Date.now()}});
  return true;
}
export async function requireFreshRocketSwap(context: RocketContext) {
  await context.guard();
  if (pending(context) && !await retireRocketSwap(context))
    throw Error('Check the saved swap before starting another trade. An uncertain broadcast cannot be replaced with a new purchase.');
}
const inFlight = new Set<string>();
export async function exclusiveRocket<T>(context: RocketContext, work: () => Promise<T>): Promise<T> {
  const key = `${context.network}:${context.address}`;
  if (inFlight.has(key)) throw Error('A swap operation is still in progress. Please wait.');
  inFlight.add(key);
  try { await context.guard(); return await work(); } finally { inFlight.delete(key); }
}
export async function verifyRocketInputs(requests: any[], reviews: any[], signal?: AbortSignal) {
  const parents = new Map<string, any>();
  for (let i = 0; i < requests.length; i++) {
    const tx = JSON.parse(requests[i].txJsonString), reviewed = reviews[i]?.inputs;
    if (!Array.isArray(reviewed) || reviewed.length !== tx.inputs?.length) throw Error('Incomplete local swap review.');
    const external: any[] = [], addresses: string[] = [];
    for (let j = 0; j < tx.inputs.length; j++) {
      const input = tx.inputs[j], parent = parents.get(`${input.transactionId}:${input.index}`);
      if (parent) {
        if (String(parent.amountSompi) !== String(input.utxo?.amount) || parent.scriptPublicKey !== input.utxo?.scriptPublicKey ||
            (parent.covenantId ?? null) !== (input.utxo?.covenantId ?? null)) throw Error('Child input differs from the locally reviewed parent.');
      } else { external.push(input); addresses.push(reviewed[j]?.address); }
    }
    if (external.length) await verifyKronInputs({txJsonString: JSON.stringify({...tx, inputs: external}),
      tradeSummary: {inputAddresses: addresses}}, rocketNodeJson, signal);
    for (const output of reviews[i].outputs) parents.set(`${reviews[i].transactionId}:${output.index}`, output);
  }
}
export async function resumeRocketSwap(context: RocketContext, checkConflict = true,
    dependencies: {submit?: typeof submitRocket; conflict?: typeof confirmedRocketConflict; sleep?: (ms: number) => Promise<void>} = {}) {
  await context.guard();
  const receipt = pending(context);
  if (!receipt) throw Error('No saved swap for this wallet and network.');
  const findConflict = dependencies.conflict ?? confirmedRocketConflict;
  const retireOrKeep=async()=>{try{return await retireRocketSwap(context,findConflict);}catch(e){if(e instanceof RocketConflictUnknown)return false;throw e;}};
  if (checkConflict && await retireOrKeep()) throw new RocketQuoteExpired();
  const accepted = context.accepted ?? ((id: string) => rocketAccepted(id, context.signal));
  const submit = dependencies.submit ?? submitRocket;
  const sleep = dependencies.sleep ?? ((ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)));
  for (let i = receipt.next; i < receipt.signed.length; i++) {
    await context.guard();
    if (!await accepted(receipt.transactionIds[i]!)) {
      await verifyRocketNetwork(context.network);
      let result: any;
      try { result = await submit(receipt.signed[i], i === receipt.signed.length - 1 ? receipt.plan?.order_row : undefined, context.signal); }
      catch (error) {
        if (error instanceof RocketConflict && await retireOrKeep()) throw new RocketQuoteExpired();
        throw error;
      }
      receipt.receipts.push(result);
      await context.save({...context.load(), pending: receipt});
      let confirmed = false;
      for (let attempt = 0; attempt < 12; attempt++) {
        await context.guard();
        if (await accepted(receipt.transactionIds[i]!)) { confirmed = true; break; }
        await sleep(1500);
      }
      if (!confirmed) throw Error('Swap submitted; confirmation is still pending. The signed swap is saved. Check its status; do not create a second purchase.');
    }
    receipt.next = i + 1;
    await context.save({...context.load(), pending: receipt});
  }
  await context.guard();
  await context.record(context.address, {transactionId: receipt.transactionIds.at(-1), blockTime: receipt.timestamp,
    incoming: receipt.side === 'buy', assetKind: 'KCC20', assetSymbol: receipt.token.ticker,
    displayAmount: receipt.summary.amountTokensDisplay, covenantId: receipt.token.tokenId,
    tokenId: receipt.token.tokenId, type: 'kasparocket-swap', standard: 'kasparocket-kcc20',
    operationLabel: receipt.side === 'buy' ? 'KaspaRocket Buy' : 'KaspaRocket Sell', rawJson: receipt});
  await context.save({obsolete: context.load().obsolete});
  return receipt;
}
