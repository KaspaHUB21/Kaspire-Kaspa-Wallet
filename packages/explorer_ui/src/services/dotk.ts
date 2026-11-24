import { useEffect, useState } from "react";
export interface DotkName { name: string; owner: string; ownerType: number; address: string | null; deedAddress: string; registryCovenantId: string }
export interface DotkList { names: DotkName[]; total: number; registeredTotal: number; page: number; pageSize: number; indexedAt: number }
export interface DotkMarket {
  source: string; indexedAt: number;
  coverage: { since: number; historicalComplete: boolean; note: string };
  totals: { volume_kas: number; trades: number };
  graph: { time: number; total_volume_kas: number; total_trades: number }[];
  top_domains: { domain: string; total_volume_kas: number; total_trades: number }[];
  recent_sales: { domain: string; price_kas: number; seller: string; buyer_deed_address: string | null; timestamp: number; transaction_id: string }[];
}
export function useDotk<T>(path: string | null, refreshMs=0) {
  const [state, setState] = useState<{ key:string|null;data: T | null; error: string; loading: boolean }>({key:path, data: null, error: "", loading: !!path });
  useEffect(() => {
    let active=true,controller:AbortController|null=null;
    setState({key:path, data: null, error: "", loading: !!path });
    if (!path) return () => {active=false;};
    const load=()=>{
      controller?.abort();const current=new AbortController();controller=current;
      const timer=setTimeout(()=>current.abort("timeout"),12000);
      fetch((import.meta.env.VITE_API_BASE_URL || "/api").replace(/\/$/, "") + "/dotk/" + path, {signal:current.signal}).then(async response=>{
        if(!response.ok)throw Error(response.status===404?"This dot.k name is not registered.":"dot.k data is temporarily unavailable. Please retry.");
        return response.json() as Promise<T>;
      }).then(data=>{if(active&&!current.signal.aborted)setState({key:path,data,error:"",loading:false});})
        .catch(error=>{if(active&&(!current.signal.aborted||current.signal.reason==="timeout"))setState(previous=>({...previous,error:current.signal.aborted?"dot.k request timed out. Please retry.":error.message,loading:false}));})
        .finally(()=>clearTimeout(timer));
    };
    load();const interval=refreshMs>0?window.setInterval(load,refreshMs):null;
    return()=>{active=false;controller?.abort();if(interval!==null)window.clearInterval(interval);};
  }, [path,refreshMs]);
  return state.key===path?state:{key:path,data:null,error:"",loading:!!path};
}

