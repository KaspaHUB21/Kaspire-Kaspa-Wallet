// Read-only Kasvio discovery. Programs come exclusively from the pinned local
// template; indexer state is cross-checked against accepted, live own-node UTXOs.
import template from '../../../../crates/kaspa_secure_core/src/kcc20_standard_template.json';
import {kcc20TransactionCount} from '../shared/kcc20Compound';
import {kcc20Program,kcc20TokenProgram} from '../shared/kcc20Programs';
const BASE = 'https://kasvio.network/api/kcc20/v1';
const NODE = 'https://kaspire.kaslab.space/api/local-node';
export const STANDARD_TEMPLATE = 'argent-kcc20-c8a0871';
type ReadOptions = {signal?:AbortSignal;progress?:(stage:string)=>void;fullPlan?:boolean};
const HASH = '9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7';
const hex64 = /^[0-9a-f]{64}$/;
type Get = (url: string) => Promise<any>;
// Share pacing between holdings and signing reads. Snapshot caching is only
// used for display: signing still fetches current balance and own-node proofs.
const queues = new WeakMap<Get, {tail: Promise<void>; next: number}>();
const holdings = new WeakMap<Get, Map<string, {at:number; assets:any[]; warning:string}>>();
const pending = new WeakMap<Get, Map<string, Promise<any[]>>>();
const delay = (ms:number) => new Promise<void>(resolve=>setTimeout(resolve,ms));
async function paced(get:Get, url:string) {
  let q=queues.get(get);
  if(!q) {q={tail:Promise.resolve(),next:0};queues.set(get,q);}
  const queue=q;
  const task=queue.tail.then(async()=>{
    for(let attempt=0;attempt<3;attempt++) {
      await delay(Math.max(0,queue.next-Date.now()));
      queue.next=Date.now()+300;
      try{return await get(url);} catch(error) {
        const e=error as {httpStatus?:number;retryAfterMs?:number;message?:string};
        if((e.httpStatus!==429 && !/\b429\b/.test(e.message??'')) || attempt===2) throw error;
        queue.next=Date.now()+Math.min(30_000,Math.max(1_500*2**attempt,e.retryAfterMs??0));
      }
    }
  });
  queue.tail=task.then(()=>{},()=>{});
  return task;
}
async function read(get: Get, path: string) {
  const v = await paced(get, BASE + path);
  if(v?.meta?.network !== 'mainnet' || v?.meta?.reference_commit !== template.referenceCommit)
    throw Error('KCC20 network or reference revision differs.');
  return v;
}
async function balance(get: Get, cid: string, owner: string) {
  const {data} = await read(get, `/tokens/${cid}/balance?owner=${owner}&scheme=00`);
  if(data?.covenant_id !== cid || data?.owner_value !== owner || data?.owner_scheme !== 0 || data?.available !== true)
    throw Error('KCC20 owner balance unavailable or mismatched.');
  return data;
}
export async function standardKcc20Assets(get: Get, owner: string, onWarning:(warning:string)=>void = ()=>{}) {
  let cache=holdings.get(get);if(!cache){cache=new Map();holdings.set(get,cache);}
  const saved=cache.get(owner);
  if(saved && Date.now()-saved.at<15_000){onWarning(saved.warning);return saved.assets;}
  let jobs=pending.get(get);if(!jobs){jobs=new Map();pending.set(get,jobs);}
  const existing=jobs.get(owner);
  if(existing){const rows=await existing;onWarning(cache.get(owner)?.warning??'');return rows;}
  const task=discover(get,owner).then(result=>{
    cache.set(owner,{at:Date.now(),...result});onWarning(result.warning);return result.assets;
  });
  jobs.set(owner,task);
  try{return await task;}finally{jobs.delete(owner);}
}
async function discover(get: Get, owner: string):Promise<{assets:any[];warning:string}> {
  if(!hex64.test(owner)) return {assets:[],warning:''};
  if((await read(get, '/status'))?.data?.status !== 'ready') throw Error('KCC20 indexer is not ready.');
  const tokens = new Map<string, any>(); let cursor = '';
  for(let page=0;page<20;page++) {
    const v = await read(get, `/tokens?limit=50${cursor ? '&cursor='+encodeURIComponent(cursor):''}`);
    for(const t of Array.isArray(v.data)?v.data:[]) if(hex64.test(t.covenant_id)) tokens.set(t.covenant_id,t);
    if(v.pagination?.has_more !== true) break;
    const next = v.pagination?.next_cursor;
    if(typeof next !== 'string' || !next || next === cursor || page === 19) throw Error('KCC20 catalogue incomplete.');
    cursor = next;
  }
  const assets: any[] = [], rows = [...tokens.values()];let failures=0;
  for(let start=0; start<rows.length; start+=6) {
    await Promise.all(rows.slice(start,start+6).map(async t=>{
      const program=kcc20TokenProgram(t);
      if(!program || !['hash_proven_reference_actor_family','hash_proven_program_artifact'].includes(t.recognition)) return;
      const m=t.metadata??{}, verified=m.binding_verified===true;
      const symbol=String(verified?(m.ticker??m.symbol??'KCC20_RAW'):'KCC20_RAW').toUpperCase();
      const decimals=verified?Number(m.decimals):0;
      if(!/^[A-Z0-9_.-]{1,32}$/.test(symbol)||!Number.isInteger(decimals)||decimals<0||decimals>18)return;
      try {
      const b=await balance(get,t.covenant_id,owner), raw=String(b.balance_raw);
      if(!/^\d+$/.test(raw))throw Error('Invalid KCC20 balance.');
      if(BigInt(raw)<=0n)return;
      assets.push({covenantId:t.covenant_id,symbol,name:verified?String(m.name??symbol):symbol,
        rawBalance:raw,decimals,standard:'kcc20',templateHash:program.id,
        validationStatus:'observed',directTransfer:true,
        image_url:m.image_bytes_verified===true&&hex64.test(m.image_hash)?`${BASE}/images/${m.image_hash}`:'',
        explorerUrl:`https://kasvio.network/`});
      } catch {failures++;}
    }));
  }
  return {assets,warning:failures ? `Some standard KCC20 balances could not be loaded (${failures}). Other tokens remain visible. Please retry.` : ''};
}
export function cachedStandardKcc20Asset(get:Get,owner:string,cid:string) {
  const value=holdings.get(get)?.get(owner);
  return value && Date.now()-value.at<300_000 ? value.assets.find(a=>a.covenantId===cid) : undefined;
}
export async function standardKcc20Token(get:Get,cid:string) {
  if(!hex64.test(cid))throw Error('Invalid KCC20 covenant ID.');
  const {data:t}=await read(get,`/tokens/${cid}`),m=t?.metadata??{};
  const program=kcc20TokenProgram(t);
  if(t?.covenant_id!==cid||!program||!['hash_proven_reference_actor_family','hash_proven_program_artifact'].includes(t?.recognition))
    throw Error('Token is not the pinned standard KCC20 actor.');
  const symbol=String(m.binding_verified===true?(m.ticker??m.symbol??'KCC20_RAW'):'KCC20_RAW').toUpperCase();
  const decimals=m.binding_verified===true?Number(m.decimals):0;
  if(!/^[A-Z0-9_.-]{1,32}$/.test(symbol)||!Number.isInteger(decimals)||decimals<0||decimals>18)throw Error('Invalid KCC20 metadata.');
  return {covenantId:cid,symbol,decimals,standard:'kcc20',templateHash:program.id};
}
export async function waitForStandardKcc20Cell(get:Get,cid:string,owner:string,txid:string,options:ReadOptions={}) {
  const deadline=Date.now()+90_000;
  while(Date.now()<deadline) {
    options.signal?.throwIfAborted();
    options.progress?.('Consolidation submitted. Waiting for indexed output; recipient not paid…');
    const b=await balance(get,cid,owner);
    if(Array.isArray(b.outputs)&&b.outputs.some((r:any)=>r.txid===txid))return;
    await delay(3000);
  }
  throw Error(`Consolidation ${txid} is saved but not indexed yet. Recipient not paid. Resume later; do not approve another consolidation for this step.`);
}
export async function standardKcc20TransferData(get: Get, cid: string, owner: string, amount: number, options:ReadOptions={}) {
  options.signal?.throwIfAborted();
  if(!hex64.test(cid)||!hex64.test(owner)||!Number.isSafeInteger(amount)||amount<=0)throw Error('Invalid KCC20 request.');
  const b=await balance(get,cid,owner), available=BigInt(String(b.balance_raw));
  if(available<BigInt(amount))throw Error('Insufficient KCC20 balance.');
  const outputs=Array.isArray(b.outputs)?[...b.outputs]:[];
  const seen=new Set<string>();
  for(const r of outputs) {
    if(!hex64.test(r.txid)||!Number.isSafeInteger(r.output_index)||r.output_index<0||
      !/^\d+$/.test(String(r.balance_raw))||BigInt(r.balance_raw)<=0n||seen.has(`${r.txid}:${r.output_index}`))throw Error('Invalid or duplicate KCC20 output.');
    seen.add(`${r.txid}:${r.output_index}`);
  }
  outputs.sort((a,b)=>BigInt(a.balance_raw)>BigInt(b.balance_raw)?-1:BigInt(a.balance_raw)<BigInt(b.balance_raw)?1:a.txid.localeCompare(b.txid)||a.output_index-b.output_index);
  let covered=0n,requiredCells=0;
  for(const raw of outputs){covered+=BigInt(raw.balance_raw);requiredCells++;if(covered>=BigInt(amount))break;}
  if(covered<BigInt(amount))throw Error('KCC20 cell discovery is incomplete.');
  const memo=new Map<string,Promise<any>>();
  const once=(url:string,load:()=>Promise<any>)=>{
    options.signal?.throwIfAborted();
    let p=memo.get(url);if(!p){p=load();memo.set(url,p);}return p;
  };
  if(!outputs.length)throw Error('No standard KCC20 token outputs.');
  const first=outputs[0],firstPath=`/tokens/${cid}/transactions/${first.txid}`;
  const firstDetail=(await once(BASE+firstPath,()=>read(get,firstPath))).data;
  const firstStates=(firstDetail?.outputs??[]).filter((r:any)=>r.io_index===first.output_index&&r.covenant_id===cid&&r.actor==='KCC20');
  if(firstDetail?.txid!==first.txid||firstStates.length!==1||firstStates[0].state_hash_verified!==true)throw Error('Missing KCC20 program proof.');
  const program=kcc20Program(firstStates[0].template_hash),limit=program.maxInputs;
  const transactionCount=kcc20TransactionCount(requiredCells,limit);
  if(options.fullPlan && requiredCells>65)throw Error('This payment needs more than 65 token cells. Split the amount into smaller payments.');
  const mandatory=options.fullPlan?requiredCells:Math.min(limit,requiredCells);
  const candidates=outputs.slice(0,mandatory);
  // Use spare slots of an ordinary payment to consume the smallest leftover
  // cells. This cleans up fragmentation without a separate consolidation TX.
  for(const raw of [...outputs].reverse()) {
    if(candidates.length>=limit)break;
    if(!candidates.includes(raw))candidates.push(raw);
  }
  const verify=async (raw:any,position:number)=>{
    try {
    options.signal?.throwIfAborted();
    options.progress?.(`Verifying KCC20 cell ${position+1} of ${candidates.length} with the local node…`);
    const id=raw.txid,index=raw.output_index;
    const path=`/tokens/${cid}/transactions/${id}`;
    const {data:detail}=await once(BASE+path,()=>read(get,path));
    const rows=(detail?.outputs??[]).filter((r:any)=>r.io_index===index&&r.covenant_id===cid&&r.actor==='KCC20');
    if(detail?.txid!==id||rows.length!==1)throw Error('Missing KCC20 state reconstruction.');
    const s=rows[0], units=Number(s.token_amount);
    if(s.state_hash_verified!==true||s.template_hash!==program.hash||s.owner_value!==owner||s.owner_scheme!==0||
      !Number.isSafeInteger(units)||units<=0||String(s.token_amount)!==String(raw.balance_raw)||!hex64.test(s.extension_commitment))
      throw Error('KCC20 reconstructed state differs.');
    if(s.borrow_scheme!==0||s.borrow_guard!=='0'.repeat(64))throw Error('KCC20 borrowing policies are not supported by direct transfers.');
    const little=Array.from({length:8},(_,i)=>Number((BigInt(units)>>BigInt(8*i))&255n).toString(16).padStart(2,'0')).join('');
    const redeemScript=`${program.template.prefix}08${little}20${owner}0100010020${'0'.repeat(64)}20${s.extension_commitment}${program.template.suffix}`;
    const origin=await once(`${NODE}/transactions/${id}`,()=>get(`${NODE}/transactions/${id}`)), os=(origin?.outputs??[]).filter((r:any)=>r.index===index);
    if(origin.transaction_id!==id||origin.is_accepted!==true||os.length!==1||os[0].covenant_id!==cid||String(os[0].amount)!==String(raw.amount_sompi))
      throw Error('The own node does not confirm this KCC20 output.');
    const o=os[0];if(!/^kaspa:[a-z0-9]{61,63}$/.test(o.script_public_key_address))throw Error('Invalid KCC20 output address.');
    const liveUrl=`${NODE}/addresses/${o.script_public_key_address}/utxos`;
    const live=await once(liveUrl,()=>get(liveUrl));
    const matches=(Array.isArray(live)?live:[]).filter((r:any)=>r.outpoint?.transactionId===id&&r.outpoint?.index===index);
    const e=matches[0]?.utxoEntry;
    if(matches.length!==1||e?.isCoinbase!==false||e?.scriptPublicKey?.scriptPublicKey!==o.script_public_key||String(e?.amount)!==String(o.amount)||
      !Number.isSafeInteger(Number(e?.amount))||!Number.isSafeInteger(Number(e?.blockDaaScore)))throw Error('KCC20 output is spent or its live state differs.');
    return {transactionId:id,index,valueSompi:Number(e.amount),blockDaaScore:Number(e.blockDaaScore),scriptPublicKey:o.script_public_key,tokenAmount:units,redeemScript,extension:s.extension_commitment};
    } catch(error) {
      // Optional dust must never break an otherwise valid payment. Required
      // cells still fail closed, as do cancellation and all native VM checks.
      if(position>=mandatory && !options.signal?.aborted)return null;
      throw error;
    }
  };
  // Bound own-node proof concurrency even for a complete multi-TX plan.
  const verified:Awaited<ReturnType<typeof verify>>[]=[];
  for(let offset=0;offset<candidates.length;offset+=3)
    verified.push(...await Promise.all(candidates.slice(offset,offset+3).map((raw,i)=>verify(raw,offset+i))));
  options.signal?.throwIfAborted();
  const cells=[];
  for(let i=0;i<verified.length;i++) {
    const row=verified[i];if(!row)continue;
    if(row.extension!==verified[0]?.extension) {
      if(i<mandatory)throw Error('Different extended token identities cannot be combined.');
      continue;
    }
    const {extension,...cell}=row;cells.push(cell);
  }
  const total=cells.reduce((sum,c)=>sum+c.tokenAmount,0);
  if(!Number.isSafeInteger(total))throw Error('KCC20 amount exceeds safe range.');
  if(!cells.length)throw Error('No verified KCC20 cells.');
  return {cells,templateHash:program.id,inputLimit:limit,compound:total<amount,stepAmount:Math.min(total,amount),requiredCells,transactionCount};
}
