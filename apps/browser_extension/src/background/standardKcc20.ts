// Read-only Kasvio discovery. Programs come exclusively from the pinned local
// template; indexer state is cross-checked against accepted, live own-node UTXOs.
import template from '../../../../crates/kaspa_secure_core/src/kcc20_standard_template.json';
import {kcc20TransactionCount} from '../shared/kcc20Compound';
import {kcc20Program,kcc20TokenProgram} from '../shared/kcc20Programs';
import {formatRawTokenAmount} from '../shared/tokenAmount';
const BASE = 'https://kasvio.network/api/kcc20/v1';
const NODE = 'https://kaspire.kaslab.space/api/local-node';
export const STANDARD_TEMPLATE = 'argent-kcc20-c8a0871';
type ReadOptions = {signal?:AbortSignal;progress?:(stage:string)=>void;fullPlan?:boolean};
const HASH = '9703112ee6e3555107cd168858992b77d3b74f655205b2b463b1f9ec2ec73cf7';
const hex64 = /^[0-9a-f]{64}$/;
const recognized = ['hash_proven_reference_actor_family','hash_proven_program_artifact','hash_proven_parameterized_actor_family'];
export function standardKcc20Decimals(token:any) {
  const units=token?.token_units,metadata=token?.metadata;
  const value=units?.status==='verified'?units.decimals:metadata?.binding_verified===true?metadata.decimals:null;
  if(value===null||value===undefined)return undefined;
  const decimals=Number(value);
  return Number.isInteger(decimals)&&decimals>=0&&decimals<=18?decimals:undefined;
}
type Get = (url: string) => Promise<any>;
// Share pacing between holdings and signing reads. Snapshot caching is only
// used for display: signing still fetches current balance and own-node proofs.
type Queue = {urgent:Array<()=>Promise<void>>; ordinary:Array<()=>Promise<void>>; running:boolean; next:number};
const queues = new WeakMap<Get, Queue>();
const holdings = new WeakMap<Get, Map<string, {at:number; assets:any[]; warning:string}>>();
type HoldingsProgress = (assets:any[])=>void;
type HoldingsJob = {task:Promise<any[]>;assets:any[];observers:Set<HoldingsProgress>};
const pending = new WeakMap<Get, Map<string, HoldingsJob>>();
const delay = (ms:number) => new Promise<void>(resolve=>setTimeout(resolve,ms));
async function paced(get:Get, url:string, priority=false) {
  let q=queues.get(get);
  if(!q) {q={urgent:[],ordinary:[],running:false,next:0};queues.set(get,q);}
  const queue=q;
  const execute=async()=>{
    for(let attempt=0;attempt<3;attempt++) {
      await delay(Math.max(0,queue.next-Date.now()));
      queue.next=Date.now()+300;
      try{return await get(url);} catch(error) {
        const e=error as {httpStatus?:number;retryAfterMs?:number;message?:string};
        if((e.httpStatus!==429 && !/\b429\b/.test(e.message??'')) || attempt===2) throw error;
        queue.next=Date.now()+Math.min(30_000,Math.max(1_500*2**attempt,e.retryAfterMs??0));
      }
    }
  };
  const task=new Promise<any>((resolve,reject)=>{
    (priority?queue.urgent:queue.ordinary).push(async()=>{try{resolve(await execute());}catch(error){reject(error);}});
  });
  if(!queue.running) {
    queue.running=true;
    void (async()=>{while(queue.urgent.length||queue.ordinary.length)await(queue.urgent.length?queue.urgent:queue.ordinary).shift()!();queue.running=false;})();
  }
  return task;
}
async function read(get: Get, path: string, priority=false) {
  const v = await paced(get, BASE + path, priority);
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
export async function standardKcc20Assets(get: Get, owner: string, onWarning:(warning:string)=>void = ()=>{}, onProgress:HoldingsProgress = ()=>{}) {
  let cache=holdings.get(get);if(!cache){cache=new Map();holdings.set(get,cache);}
  const saved=cache.get(owner);
  if(saved && Date.now()-saved.at<15_000){onWarning(saved.warning);return saved.assets;}
  let jobs=pending.get(get);if(!jobs){jobs=new Map();pending.set(get,jobs);}
  let job=jobs.get(owner);
  if(!job) {
    const current:HoldingsJob={task:Promise.resolve([]),assets:[],observers:new Set()};
    current.task=discover(get,owner,assets=>{
      current.assets=assets;
      for(const observer of current.observers)try{observer([...assets]);}catch{/* A display subscriber cannot interrupt discovery. */}
    }).then(result=>{
      cache.set(owner,{at:Date.now(),...result});return result.assets;
    }).finally(()=>jobs!.delete(owner));
    jobs.set(owner,current);job=current;
  }
  job.observers.add(onProgress);
  // A reopened popup joins the existing scan, including its already found
  // positives. Partial discovery is never cached as a complete/zero balance.
  if(job.assets.length)try{onProgress([...job.assets]);}catch{/* Display only. */}
  try {const rows=await job.task;onWarning(cache.get(owner)?.warning??'');return rows;}
  finally {job.observers.delete(onProgress);}
}
async function discover(get: Get, owner: string, publish:HoldingsProgress):Promise<{assets:any[];warning:string}> {
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
        activityOrigins:(Array.isArray(b.outputs)?[...b.outputs]:[])
          .sort((a,b)=>Number(b.acceptance_id??0)-Number(a.acceptance_id??0))
          .map(r=>String(r.txid??'')).filter(id=>hex64.test(id)).slice(0,512),
        image_url:m.image_bytes_verified===true&&hex64.test(m.image_hash)?`${BASE}/images/${m.image_hash}`:'',
        explorerUrl:`https://kasvio.network/`});
      // Match Android: show each validated holding immediately, rather than
      // waiting for every other catalogue token's paced balance request.
      publish([...assets]);
      } catch {failures++;}
    }));
  }
  return {assets,warning:failures ? `Some standard KCC20 balances could not be loaded (${failures}). Other tokens remain visible. Please retry.` : ''};
}
export function cachedStandardKcc20Asset(get:Get,owner:string,cid:string) {
  const discovered=pending.get(get)?.get(owner)?.assets.find(a=>a.covenantId===cid);
  if(discovered)return discovered; // Display metadata only; never a signing proof.
  const value=holdings.get(get)?.get(owner);
  return value && Date.now()-value.at<300_000 ? value.assets.find(a=>a.covenantId===cid) : undefined;
}
const historyCaches = new WeakMap<Get,Map<string,Promise<any>>>();
function historyRead(get:Get,path:string) {
  let cache=historyCaches.get(get);if(!cache){cache=new Map();historyCaches.set(get,cache);}
  if(cache.size>1024)cache.clear();
  let task=cache.get(path);
  if(!task) {
    task=read(get,path,true).then(v=>{
      if(path.includes('/transactions/') && v?.data?.components_complete!==true)throw Error('Incomplete KCC20 history.');
      return v?.data;
    }).catch(error=>{cache!.delete(path);throw error;});
    cache.set(path,task);
  }
  return task;
}
export async function standardKcc20HistoryMetadata(get:Get,cid:string) {
  const token=await historyRead(get,`/tokens/${cid}`);
  if(token?.covenant_id!==cid||!recognized.includes(token?.recognition))return undefined;
  const decimals=standardKcc20Decimals(token),m=token.metadata??{};
  return decimals===undefined?{ticker:'KCC20_RAW',decimals:0}:{ticker:String(m.binding_verified===true?(m.ticker??m.symbol??'KCC20'): 'KCC20'),decimals,unitSource:'verified-kcc20'};
}
/** Exact wallet-related receipts only; never walk a token's global trade feed. */
export async function standardKcc20History(get:Get,owner:string,references:Map<string,Set<string>>,limit=51) {
  if(!hex64.test(owner))return {items:[],warnings:[]};
  const refs=new Map([...references].map(([cid,ids])=>[cid,new Set(ids)]));
  for(const asset of holdings.get(get)?.get(owner)?.assets??[]) {
    const ids=refs.get(asset.covenantId)??new Set<string>();
    for(const id of (asset.activityOrigins??[]).slice(0,limit))ids.add(id);
    refs.set(asset.covenantId,ids);
  }
  const entries=[...refs].filter(([cid])=>hex64.test(cid)),items:any[]=[];
  let failures=0;
  for(let start=0;start<entries.length;start+=4) {
    await Promise.all(entries.slice(start,start+4).map(async([cid,ids])=>{
      let token:any;
      try { token=await historyRead(get,`/tokens/${cid}`); }
      catch(error) { if((error as {httpStatus?:number}).httpStatus!==404)failures++;return; }
      if(token?.covenant_id!==cid||!recognized.includes(token?.recognition))return;
      const metadata=token.metadata??{},verified=metadata.binding_verified===true;
      const decimals=standardKcc20Decimals(token);
      const symbol=String(verified?(metadata.ticker??metadata.symbol??'KCC20_RAW'):'KCC20_RAW').toUpperCase();
      if(decimals===undefined||!/^[A-Z0-9_.-]{1,32}$/.test(symbol)){failures++;return;}
      for(const id of [...ids].filter(id=>hex64.test(id)).slice(0,limit*2)) {
        try {
          const tx=await historyRead(get,`/tokens/${cid}/transactions/${id}`);
          if(tx?.txid!==id||tx?.token?.covenant_id!==cid||tx?.components_complete!==true)throw Error('Mismatched KCC20 transaction.');
          const total=(direction:string)=>(Array.isArray(tx[direction])?tx[direction]:[])
            .filter((r:any)=>r.actor==='KCC20'&&r.covenant_id===cid&&r.owner_scheme===0&&r.owner_value===owner&&r.state_hash_verified===true)
            .reduce((sum:bigint,r:any)=>{if(!/^\d+$/.test(String(r.token_amount)))throw Error('Invalid KCC20 amount.');return sum+BigInt(r.token_amount);},0n);
          const delta:bigint=total('outputs')-total('inputs'),time=Number(tx.time_ms);
          if(delta===0n||!Number.isSafeInteger(time)||time<1577836800000||time>Date.now()+300000)continue;
          items.push({transactionId:id,blockTime:time,isAccepted:true,incoming:delta>0n,assetKind:'KCC20',assetSymbol:symbol,
            tokenId:cid,covenantId:cid,unitSource:'verified-kcc20',displayAmount:formatRawTokenAmount(String(delta<0n?-delta:delta),decimals),counterparty:'',from:[],to:[]});
        } catch {failures++;}
      }
    }));
  }
  items.sort((a,b)=>b.blockTime-a.blockTime);
  return {items:items.slice(0,limit),warnings:failures?['Some KCC20 transaction details are temporarily unavailable. Retry to complete history.']:[]};
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
    if(!Number.isInteger(s.borrow_scheme)||s.borrow_scheme<0||s.borrow_scheme>3||!hex64.test(s.borrow_guard))throw Error('Invalid KCC20 borrowing policy.');
    const little=Array.from({length:8},(_,i)=>Number((BigInt(units)>>BigInt(8*i))&255n).toString(16).padStart(2,'0')).join('');
    const redeemScript=`${program.template.prefix}08${little}20${owner}010001${s.borrow_scheme.toString(16).padStart(2,'0')}20${s.borrow_guard}20${s.extension_commitment}${program.template.suffix}`;
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
/** Permissionless threshold borrowing only. Signature/hash-chain policies are
 * not permissionless; absent recipient authorization they stay untouched. */
export async function standardKcc20BorrowedReceive(get:Get,cid:string,recipientOwner:string,amount:number,firstCell:{redeemScript:string},templateId:string,options:ReadOptions={}) {
  if(!hex64.test(cid)||!hex64.test(recipientOwner)||!Number.isSafeInteger(amount)||amount<=0)throw Error('Invalid borrowed receive request.');
  const program=kcc20Program(templateId===STANDARD_TEMPLATE?HASH:templateId==='argent-kcc20-c8a0871-10x10'?'ff3ae732e3a2819bf9181f5aed6b1e9d0f7abea70a1dd655b8e777cbcbd2422b':'');
  const prefixLength=program.template.prefix.length;
  const extension=firstCell.redeemScript.slice(prefixLength+160,prefixLength+224);
  if(!hex64.test(extension))throw Error('Missing sender token identity.');
  const b=await balance(get,cid,recipientOwner),rows=Array.isArray(b.outputs)?[...b.outputs]:[];
  rows.sort((a,b)=>Number(b.acceptance_id??0)-Number(a.acceptance_id??0));
  // Bound optional discovery. A missing proof never authorizes a cell spend.
  for(const raw of rows.slice(0,32)) {
    options.signal?.throwIfAborted();
    const id=String(raw.txid??''),index=Number(raw.output_index);
    if(!hex64.test(id)||!Number.isSafeInteger(index)||index<0)continue;
    const {data:tx}=await read(get,`/tokens/${cid}/transactions/${id}`,true);
    const states=(tx?.outputs??[]).filter((s:any)=>s.io_index===index&&s.covenant_id===cid&&s.actor==='KCC20');
    if(tx?.txid!==id||states.length!==1)continue;
    const s=states[0],units=Number(s.token_amount);
    if(s.state_hash_verified!==true||s.template_hash!==program.hash||s.owner_scheme!==0||s.owner_value!==recipientOwner||s.borrow_scheme!==1||!hex64.test(s.borrow_guard)||s.extension_commitment!==extension||!Number.isSafeInteger(units)||units<0||String(s.token_amount)!==String(raw.balance_raw)||!Number.isSafeInteger(units+amount))continue;
    const guard=BigInt('0x'+s.borrow_guard.slice(0,16).match(/../g)!.reverse().join(''));
    const threshold=(guard>>63n)!==0n?0n:guard;
    if(BigInt(amount)<=threshold)continue;
    const origin=await get(`${NODE}/transactions/${id}`),outputs=(origin?.outputs??[]).filter((o:any)=>o.index===index);
    const o=outputs[0];
    if(origin?.transaction_id!==id||origin?.is_accepted!==true||outputs.length!==1||o.covenant_id!==cid||String(o.amount)!==String(raw.amount_sompi)||!/^kaspa:[a-z0-9]{61,63}$/.test(o.script_public_key_address))continue;
    const live=await get(`${NODE}/addresses/${o.script_public_key_address}/utxos`);
    const matches=(Array.isArray(live)?live:[]).filter((r:any)=>r.outpoint?.transactionId===id&&r.outpoint?.index===index);
    const e=matches[0]?.utxoEntry;
    if(matches.length!==1||e?.isCoinbase!==false||e.scriptPublicKey?.scriptPublicKey!==o.script_public_key||String(e.amount)!==String(o.amount)||!Number.isSafeInteger(Number(e.amount))||!Number.isSafeInteger(Number(e.blockDaaScore)))continue;
    const little=Array.from({length:8},(_,i)=>Number((BigInt(units)>>BigInt(8*i))&255n).toString(16).padStart(2,'0')).join('');
    const redeemScript=`${program.template.prefix}08${little}20${recipientOwner}0100010120${s.borrow_guard}20${extension}${program.template.suffix}`;
    return {transactionId:id,index,valueSompi:Number(e.amount),blockDaaScore:Number(e.blockDaaScore),scriptPublicKey:o.script_public_key,tokenAmount:units,redeemScript};
  }
  return null;
}
