import {useCallback,useEffect,useRef,useState} from 'react';
import {Link,useParams} from 'react-router-dom';
import {DagCanvas} from '../components/DagCanvas';
import {parseDag,type DagBlock,type DagSnapshot} from '../dag';
import {readJson,State} from '../nativeApi';
import {chainRead} from '../chain';
import {transactionLink} from '../blockTransaction';
export const DAG_URL='https://kaspire.kaslab.space/api/explorer/blockdag';
type Feed={data:DagSnapshot|null;error:string;loading:boolean;receivedAt:number;progressAt:number};
function useDag(paused:boolean){
 const hidden=()=>document.visibilityState==='hidden';
 const [state,set]=useState<Feed>({data:null,error:'',loading:true,receivedAt:0,progressAt:0}),last=useRef<DagSnapshot|null>(null),progress=useRef(0);
 useEffect(()=>{if(paused)return;let alive=true,busy=false,timer:ReturnType<typeof setTimeout>,controller:AbortController|null=null;
  const load=async()=>{if(!alive||busy||hidden())return;busy=true;controller=new AbortController();const current=controller,timeout=setTimeout(()=>current.abort(),8000);
   try{const data=parseDag(await readJson(DAG_URL,current.signal));if(last.current?.epoch===data.epoch&&data.sequence<last.current.sequence)throw Error('Older BlockDAG response rejected.');const now=Date.now();if(!last.current||last.current.epoch!==data.epoch||data.sequence>last.current.sequence)progress.current=now;last.current=data;if(alive&&!current.signal.aborted)set({data,error:'',loading:false,receivedAt:now,progressAt:progress.current});}
   catch(e){if(alive&&!hidden())set(s=>({...s,error:current.signal.aborted?'BlockDAG read timed out. Last observation is preserved.':(e as Error).message,loading:false}));}
   finally{clearTimeout(timeout);busy=false;if(alive&&!hidden())timer=setTimeout(load,1000);}
  };
  const visible=()=>{clearTimeout(timer);if(document.visibilityState==='hidden')controller?.abort();else void load();};document.addEventListener('visibilitychange',visible);void load();
  return()=>{alive=false;clearTimeout(timer);controller?.abort();document.removeEventListener('visibilitychange',visible);};
 },[paused]);
 return state;
}
export function BlockDagPage(){
 const [paused,setPaused]=useState(false),[follow,setFollow]=useState(true),[zoom,setZoom]=useState(.65),[selected,setSelected]=useState<DagBlock|null>(null),[now,setNow]=useState(Date.now());
 const feed=useDag(paused),d=feed.data;
 useEffect(()=>{const timer=setInterval(()=>{if(document.visibilityState!=='hidden')setNow(Date.now());},1000);return()=>clearInterval(timer);},[]);
 const age=d?.lastBlockAt===null||!d?null:Math.max(0,d.serverTime-d.lastBlockAt+now-feed.receivedAt,now-feed.progressAt);
 const status=paused?'paused':feed.error?'unavailable':d?.status==='live'&&age!==null&&age>8000?'stale':d?.status??'connecting';
 const live=status==='live',select=useCallback((block:DagBlock)=>setSelected(block),[]),pan=useCallback(()=>setFollow(false),[]),changeZoom=useCallback((n:number)=>setZoom(Math.max(.2,Math.min(2,n))),[]);
 const recent=[...(d?.blocks??[])].sort((a,b)=>b.observedAt-a.observedAt||b.hash.localeCompare(a.hash)).slice(0,8);
 return <section className="space-y-4" data-blockdag-page>
  <div className="kaspa-panel rounded-md p-4"><div className="flex flex-wrap items-center justify-between gap-3"><h1>Live Kaspa BlockDAG</h1><span data-dag-status role="status" className="rounded-md border border-kaspa-border px-3 py-1 text-sm font-bold text-kaspa-primary">{status==='live'?'Live':status==='paused'?'Paused':status==='warming'?'Collecting blocks':status==='node-unsynced'?'Node syncing':status==='stale'?'Stale data':status==='connecting'?'Connecting':'Reconnecting'}</span></div><p className="mt-2 text-sm text-kaspa-muted">Real Mainnet blocks and parent links from Kaspire’s own node. No simulated blocks.</p></div>
  <div className="grid gap-3 sm:grid-cols-3">
   {[['Observed rate',live&&d?.observedBps!==null?`${d?.observedBps} blocks/s`:'Measuring…'],['Virtual DAA score',d?.info?BigInt(d.info.virtualDaaScore).toLocaleString('en-US'):'Unavailable'],['Blocks in window',d?.blocks.length?`${d.blocks.length} / ${d.windowLimit}`:'Collecting…']].map(([label,value])=><div className="kaspa-panel min-w-0 rounded-md p-3" key={label}><div className="text-xs text-kaspa-muted">{label}</div><div className="mt-1 break-all font-bold">{value}</div></div>)}
  </div>
  <div className="kaspa-panel rounded-md p-3">
   <div className="mb-3 flex flex-wrap items-center gap-2">
    <button aria-label="Zoom out" disabled={zoom<=.2} className="min-h-11 min-w-11 rounded-md border border-kaspa-border px-3" onClick={()=>changeZoom(zoom/1.25)}>−</button><span className="text-xs tabular-nums" data-dag-zoom>{Math.round(zoom*100)}%</span><button aria-label="Zoom in" disabled={zoom>=2} className="min-h-11 min-w-11 rounded-md border border-kaspa-border px-3" onClick={()=>changeZoom(zoom*1.25)}>+</button>
    <button aria-pressed={follow} onClick={()=>setFollow(true)} className="min-h-11 rounded-md border border-kaspa-border px-3 text-sm">Follow live</button><button data-dag-pause aria-pressed={paused} onClick={()=>setPaused(v=>!v)} className="min-h-11 rounded-md border border-kaspa-border px-3 text-sm">{paused?'Resume':'Pause'}</button>
   </div>
   <div className="relative overflow-hidden rounded-md border border-kaspa-border bg-kaspa-background/90"><DagCanvas snapshot={d} zoom={zoom} follow={follow} selected={selected?.hash??null} onSelect={select} onPan={pan} onZoom={changeZoom}/>{!d?.blocks.length?<p className="absolute inset-0 flex items-center justify-center p-5 text-center text-sm text-kaspa-muted">{feed.error?'Block data is unavailable. Waiting to reconnect…':'Waiting for real blocks from the node…'}</p>:null}</div>
   <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-kaspa-muted"><span>■ Observed block</span><span>━ Selected-parent link</span><span>─ Other parent link</span></div>
   <p className="mt-2 text-xs text-kaspa-muted">Drag to pan. Pinch or use +/− to zoom. Tap a block for details. Bottom labels show DAA scores.</p>
  </div>
  {feed.error?<p role="alert" className="kaspa-panel rounded-md p-3 text-sm">{feed.error}</p>:null}
  {status!=='live'&&d?.blocks.length?<p className="kaspa-panel rounded-md p-3 text-sm text-kaspa-muted">{paused?'Updates are paused.':'The stream is interrupted or still warming up.'} The last observed blocks stay visible; no replacement blocks are invented.</p>:null}
  <p className="kaspa-panel rounded-md p-3 text-xs text-kaspa-muted">A bounded window of the latest {d?.windowLimit??240} observed blocks, refreshed every second while this page is active. Parents outside the window are not drawn. Highlighted links identify the block’s selected parent, not final confirmation or a full GHOSTDAG blue/red classification.{age!==null?` Last block observed ${Math.floor(age/1000)}s ago.`:''}</p>
  {selected?<div className="kaspa-panel rounded-md p-4" data-dag-details><h2>Selected block</h2><Link className="my-3 block break-all font-mono text-xs text-kaspa-primary" to={'/block/'+selected.hash}>{selected.hash}</Link><dl className="explorer-facts grid gap-3 sm:grid-cols-2">{[['DAA score',selected.daaScore],['Blue score',selected.blueScore],['Block time',new Date(selected.timestampMs).toLocaleString()],['Transactions',selected.txCount??'Unavailable'],['Parent links',selected.parents.length]].map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl><Link className="mt-3 inline-flex min-h-11 items-center rounded-md border border-kaspa-border px-3 text-sm" to={'/block/'+selected.hash}>Open block details</Link></div>:null}
  <div className="kaspa-panel rounded-md p-4"><h2>Recent blocks</h2><div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{recent.map(b=><button data-recent-block={b.hash} key={b.hash} onClick={()=>setSelected(b)} className="min-w-0 rounded-md border border-kaspa-border p-3 text-left"><div className="font-mono text-sm text-kaspa-primary">{b.hash.slice(0,8)}…{b.hash.slice(-6)}</div><div className="mt-1 text-xs text-kaspa-muted">DAA {BigInt(b.daaScore).toLocaleString('en-US')} · {b.parents.length} parents</div></button>)}</div></div>
 </section>;
}

export function BlockDetailPage(){
 const {hash=''}=useParams(),[state,set]=useState<{loading:boolean;error:string;data:any}>({loading:true,error:'',data:null}),[revision,retry]=useState(0),[page,setPage]=useState(0);
 useEffect(()=>{const c=new AbortController();set({loading:true,error:'',data:null});setPage(0);if(!/^[a-f0-9]{64}$/i.test(hash)){set({loading:false,error:'Invalid block hash.',data:null});return;}
  chainRead('/blocks/'+hash.toLowerCase()+'?includeTransactions=true',c.signal).then(data=>{if((data.verboseData?.hash??data.header?.hash)!==hash.toLowerCase())throw Error('Block identity differs.');if(!c.signal.aborted)set({loading:false,error:'',data});}).catch(e=>{if(!c.signal.aborted)set({loading:false,error:e.message,data:null});});return()=>c.abort();
 },[hash,revision]);
 const d=state.data,h=d?.header,v=d?.verboseData,parents:string[]=h?.parents?.[0]?.parentHashes??h?.parentsByLevel?.[0]??[],transactions:string[]|null=Array.isArray(v?.transactionIds)?v.transactionIds.filter((id:unknown)=>typeof id==='string'&&/^[a-f0-9]{64}$/.test(id)):Array.isArray(d?.transactions)?d.transactions.map((t:any)=>t.verboseData?.transactionId??t.transaction_id).filter((id:unknown)=>typeof id==='string'&&/^[a-f0-9]{64}$/.test(id)):null;
 return <section className="space-y-4"><Link to="/blockdag" className="kaspa-panel inline-block rounded-md p-3">← Live BlockDAG</Link><div className="kaspa-panel rounded-md p-4"><h1>Kaspa block</h1><p className="my-3 break-all font-mono text-xs">{hash}</p><State state={{...state,retry:()=>retry(n=>n+1)}}/>{d?<dl className="explorer-facts grid gap-3 sm:grid-cols-2">{[['Network','Kaspa Mainnet'],['DAA score',h?.daaScore??'Unavailable'],['Blue score',h?.blueScore??v?.blueScore??'Unavailable'],['Block time',h?.timestamp?new Date(Number(h.timestamp)).toLocaleString():'Unavailable'],['Transactions',transactions?.length??'Unavailable']].map(([label,value])=><div key={label}><dt>{label}</dt><dd>{String(value)}</dd></div>)}</dl>:null}</div>
  {d?<><div className="kaspa-panel rounded-md p-4"><h2>Parents ({parents.length})</h2>{parents.filter(p=>/^[a-f0-9]{64}$/.test(p)).map(p=><Link className="mt-3 block break-all font-mono text-xs text-kaspa-primary" key={p} to={'/block/'+p}>{p}</Link>)}</div><div className="kaspa-panel rounded-md p-4"><h2>Transactions</h2>{transactions===null?<p>Transaction IDs are unavailable.</p>:<><div className="mt-3 grid gap-3 sm:grid-cols-2">{transactions.slice(page*20,(page+1)*20).map(id=><Link className="min-w-0 break-all rounded-md border border-kaspa-border p-3 font-mono text-xs text-kaspa-primary" key={id} to={transactionLink(id,hash)}>{id}</Link>)}</div><div className="mt-3 flex justify-between gap-2"><button className="min-h-11" disabled={!page} onClick={()=>setPage(p=>p-1)}>Previous</button><span>Page {page+1}</span><button className="min-h-11" disabled={(page+1)*20>=transactions.length} onClick={()=>setPage(p=>p+1)}>Next</button></div></>}</div></>:null}
 </section>;
}
