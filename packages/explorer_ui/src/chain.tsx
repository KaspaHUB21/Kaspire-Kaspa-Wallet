import {useEffect,useState} from 'react';
import {Link,useParams,useSearchParams} from 'react-router-dom';
import {node,readJson,State,useRead} from './nativeApi';
import {TransactionTokens} from './TokenFlow';
import {transactionLink,transactionReadPath,isCoinbase} from './blockTransaction';
// Preserve JSON u64s before JS can round them. Only native-chain DTOs use this.
export function exactJson(raw:string):any{let out='',quoted=false,escape=false;for(let i=0;i<raw.length;){const c=raw[i]!;if(quoted){out+=c;i++;if(escape)escape=false;else if(c==='\\')escape=true;else if(c==='"')quoted=false;continue;}if(c==='"'){quoted=true;out+=c;i++;continue;}if(c==='-'||/\d/.test(c)){const m=/^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(raw.slice(i));if(m){const n=m[0];if(!/[.eE]/.test(n)&&!Number.isSafeInteger(Number(n)))out+=JSON.stringify(n);else out+=n;i+=n.length;continue;}}out+=c;i++;}return JSON.parse(out);}
export async function chainRead(path:string,signal?:AbortSignal){const r=await fetch(node+path,{signal});if(!r.ok)throw Error('Kaspa data unavailable ('+r.status+'). Please retry.');return exactJson(await r.text());}
export function rawAmount(v:unknown):bigint|null{if(typeof v==='number'&&!Number.isSafeInteger(v))return null;if(typeof v!=='string'&&typeof v!=='number')return null;return /^\d+$/.test(String(v))?BigInt(v):null;}
export function kas(v:unknown){const n=typeof v==='bigint'?v:rawAmount(v);if(n===null)return 'Unavailable';const a=n<0n?-n:n;return(n<0n?'-':'')+(a/100000000n).toLocaleString('en-US')+((a%100000000n)?'.'+String(a%100000000n).padStart(8,'0').replace(/0+$/,''):'')+' KAS';}
const addr=(v:any)=>String(v?.previous_outpoint_address??v?.script_public_key_address??v?.address??'');
const inputValue=(v:any)=>rawAmount(v?.previous_outpoint_amount??v?.amount??v?.value);
const outputValue=(v:any)=>rawAmount(v?.amount??v?.value);
export function movement(tx:any,address:string){let ins=0n,outs=0n,known=true;for(const i of tx.inputs??[]){if(!addr(i)||inputValue(i)===null)known=false;else if(addr(i)===address)ins+=inputValue(i)!;}for(const o of tx.outputs??[]){if(!addr(o)||outputValue(o)===null)known=false;else if(addr(o)===address)outs+=outputValue(o)!;}return known?outs-ins:null;}
export const txId=(t:any)=>String(t.transaction_id??t.transactionId??t.id??'');
const when=(t:any)=>{const n=Number(t.block_time??t.timestamp??0);return n?new Date(n<1e12?n*1000:n).toLocaleString():'Time unavailable';};
function Status({tx,observed=false}:{tx:any;observed?:boolean}){return <span className={tx.is_accepted===true?'tx-status accepted':'tx-status'}>{tx.is_accepted===true?'Accepted':tx.is_accepted===false?(observed?'Acceptance not confirmed':'Not accepted'):'Status unavailable'}</span>}
export function ChainBalance({address}:{address:string}){const [s,set]=useState<any>({loading:true,error:'',data:null}),[rev,retry]=useState(0);useEffect(()=>{const c=new AbortController();set({loading:true,error:'',data:null});chainRead('/addresses/'+encodeURIComponent(address)+'/balance',c.signal).then(data=>{if(!c.signal.aborted)set({loading:false,error:'',data})}).catch(e=>{if(!c.signal.aborted)set({loading:false,error:e.message,data:null})});return()=>c.abort()},[address,rev]);return <div className="kaspa-panel my-4 rounded-md p-5"><h2>Kaspa balance</h2><State state={{...s,retry:()=>retry(n=>n+1)}}/>{s.data?<strong>{kas(s.data.balance)}</strong>:null}</div>}
export function ChainActivity({address}:{address:string}){const [page,setPage]=useState(0),[s,set]=useState<any>({key:'',loading:true,error:'',rows:[]}),[revision,retry]=useState(0);const key=address+':'+page;
 useEffect(()=>{setPage(0)},[address]);useEffect(()=>{const c=new AbortController();set({key,loading:true,error:'',rows:[]});chainRead('/addresses/'+encodeURIComponent(address)+'/full-transactions?'+new URLSearchParams({limit:'20',offset:String(page*20),resolve_previous_outpoints:'light'}),c.signal).then(data=>{const rows=Array.isArray(data)?data:data.transactions;if(!Array.isArray(rows)||rows.some((r:any)=>!/^[a-f0-9]{64}$/.test(txId(r))))throw Error('Invalid Kaspa transaction page.');if(!c.signal.aborted)set({key,loading:false,error:'',rows})}).catch(e=>{if(!c.signal.aborted)set({key,loading:false,error:e.message,rows:[]})});return()=>c.abort()},[key,revision]);
 const current=s.key===key?s:{loading:true,error:'',rows:[]};return <section className="kaspa-panel my-5 rounded-md p-4"><h2 className="text-lg font-bold">Transactions · All Kaspa L1 activity</h2><p className="text-sm text-kaspa-muted">KAS, token inscriptions and covenant transactions · 20 per page</p><State state={{...current,retry:()=>retry(n=>n+1)}}/>{!current.loading&&!current.error&&current.rows.length===0?<p>No transactions on this page.</p>:null}{current.rows.map((tx:any)=>{const delta=movement(tx,address),direction=delta===null?'unknown':delta>0n?'in':delta<0n?'out':'self',peers=[...new Set((direction==='in'?(tx.inputs??[]):(tx.outputs??[])).map(addr).filter((a:string)=>a&&a!==address))] as string[];return <article className={'chain-row '+direction} key={txId(tx)}><div className="flex flex-wrap justify-between gap-2"><span>{when(tx)}</span><Status tx={tx}/></div><Link to={'/tx/'+txId(tx)} className="break-all text-kaspa-primary">{txId(tx)}</Link><div className="tx-value">{direction==='in'?'↓ +':direction==='out'?'↑ ':direction==='self'?'↔ ':''}{delta===null?'Amount unavailable':kas(delta)}</div><details><summary>{peers.length?peers.length+' counterparty address(es)':'Inputs / outputs'}</summary>{peers.map(a=><Link className="block break-all" key={a} to={'/wallet/krc20/'+encodeURIComponent(a)}>{a}</Link>)}<Link to={'/tx/'+txId(tx)}>View transaction details</Link></details></article>})}<div className="flex items-center justify-between gap-2 mt-4"><button disabled={page===0||current.loading} onClick={()=>setPage(p=>p-1)}>Previous</button><span>Page {page+1}</span><button disabled={current.loading||!!current.error||current.rows.length<20} onClick={()=>setPage(p=>p+1)}>Next</button></div></section>;
}
function Coins({items,input}:{items:any[],input:boolean}){return <div data-tx-panel={input?'inputs':'outputs'} className={'kaspa-panel rounded-md p-4 coin-list '+(input?'out':'in')}><h2>{input?'Inputs':'Outputs'} ({items.length})</h2>{items.map((v,i)=>{const a=addr(v);return <article className="chain-row" key={i}><b>{input?'↑ ':'↓ '}{kas(input?inputValue(v):outputValue(v))}</b>{a?<Link className="block break-all" to={'/wallet/krc20/'+encodeURIComponent(a)}>{a}</Link>:<p>Address unavailable · script output</p>}{v.covenant?<p className="break-all">Covenant: {String(v.covenant.covenant_id??v.covenant.covenantId??'')}</p>:null}</article>})}</div>}
export function TransactionPage(){
 const {id=''}=useParams(),[query]=useSearchParams(),blocks=query.getAll('blockHash'),context=JSON.stringify(blocks),key=id+':'+context;
 const [state,set]=useState<any>({key:'',loading:true,error:'',data:null}),[revision,retry]=useState(0);
 useEffect(()=>{
  const c=new AbortController();set({key,loading:true,error:'',data:null});
  try{
   const path=transactionReadPath(id,blocks);
   chainRead(path,c.signal).then(data=>{
    if(txId(data)!==id.toLowerCase())throw Error('Transaction identity differs.');
    if(!c.signal.aborted)set({key,loading:false,error:'',data});
   }).catch(e=>{if(!c.signal.aborted)set({key,loading:false,error:e.message,data:null});});
  }catch(e){set({key,loading:false,error:(e as Error).message,data:null});}
  return()=>c.abort();
 },[id,context,revision]);
 const s=state.key===key?state:{loading:true,error:'',data:null},t=s.data,observed=blocks.length===1;
 const iv=t?.inputs?.map(inputValue),ov=t?.outputs?.map(outputValue),coinbase=!!t&&isCoinbase(t);
 const fee=iv?.every((v:any)=>v!==null)&&ov?.every((v:any)=>v!==null)?iv.reduce((a:bigint,b:bigint)=>a+b,0n)-ov.reduce((a:bigint,b:bigint)=>a+b,0n):null;
 return <section className="transaction-detail space-y-4">
  <div data-tx-panel="identity" className="kaspa-panel rounded-md p-4"><h1>Transaction</h1><p className="break-all my-3 font-mono text-xs">{id}</p><State state={{...s,retry:()=>retry(n=>n+1)}}/>{t?<><Status tx={t} observed={observed}/>{observed?<><p className="mt-3 text-xs text-kaspa-muted">Live block data can appear before the transaction index confirms acceptance.</p><button className="mt-3 min-h-11 rounded-md border border-kaspa-border px-3 text-sm" onClick={()=>retry(n=>n+1)}>Refresh transaction</button></>:null}</>:null}</div>
  {t?<><TransactionTokens tx={t}/><div data-tx-panel="summary" className="kaspa-panel rounded-md p-4">{coinbase?<h2 className="mb-3">Mining reward (coinbase)</h2>:null}<dl className="grid gap-4 sm:grid-cols-2"><div><dt className="text-xs text-kaspa-muted">Time</dt><dd className="mt-1">{when(t)}</dd></div><div><dt className="text-xs text-kaspa-muted">Network fee</dt><dd className="mt-1 font-bold">{coinbase?'Not applicable (coinbase)':fee!==null&&fee>=0n?kas(fee):'Unavailable'}</dd></div></dl></div><div className="grid items-start gap-4 md:grid-cols-2"><Coins input items={t.inputs??[]}/><Coins input={false} items={t.outputs??[]}/></div></>:null}
 </section>;
}
export function LookupPage(){
 const {id=''}=useParams(),s=useRead(node+'/blocks/'+encodeURIComponent(id)+'?includeTransactions=true');
 const ids=(s.data?.transactions??[]).map((t:any)=>txId(t)||t.verboseData?.transactionId).filter((v:unknown)=>typeof v==='string'&&/^[a-f0-9]{64}$/i.test(v));
 const block=s.data?.verboseData?.hash??id;
 return <section><h1>TX ID / Block hash</h1><p className="break-all">{id}</p><Link to={'/tx/'+id}>Look up transaction →</Link><h2 className="mt-5">Block</h2><State state={s}/>{s.data?<div className="kaspa-panel p-4"><p className="break-all">Hash: {block}</p><p>DAA score: {String(s.data.header?.daaScore??'Unavailable')}</p><p>Blue score: {String(s.data.verboseData?.blueScore??'Unavailable')}</p>{/^[a-f0-9]{64}$/i.test(block)?ids.map((tx:string)=><Link className="block break-all" key={tx} to={transactionLink(tx,block)}>{tx}</Link>):null}</div>:null}</section>;
}
