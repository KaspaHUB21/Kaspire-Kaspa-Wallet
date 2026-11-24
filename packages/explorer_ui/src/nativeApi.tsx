import {useEffect,useState} from 'react';
export const node='https://kaspire.kaslab.space/api/local-node';
export const nexus='https://kaspanftnexus.com';
export async function readJson<T=any>(url:string,signal?:AbortSignal,body?:unknown):Promise<T>{
 const r=await fetch(url,{signal,...(body===undefined?{}:{method:'POST',body:JSON.stringify(body)})});
 const text=await r.text();if(!r.ok){let message='Explorer data unavailable ('+r.status+').';try{message=JSON.parse(text).error||message}catch{}throw Error(message)}
 return JSON.parse(text);
}
export function useRead<T=any>(url:string|null){const [retry,setRetry]=useState(0),[s,set]=useState<{url:string|null,data:T|null,error:string,loading:boolean}>({url,data:null,error:'',loading:!!url});
 useEffect(()=>{const c=new AbortController();set({url,data:null,error:'',loading:!!url});if(url)readJson<T>(url,c.signal).then(data=>{if(!c.signal.aborted)set({url,data,error:'',loading:false})}).catch(e=>{if(!c.signal.aborted)set({url,data:null,error:e.message,loading:false})});return()=>c.abort()},[url,retry]);return {...(s.url===url?s:{url,data:null,error:'',loading:!!url}),retry:()=>setRetry(n=>n+1)};
}
export function State({state}:{state:{loading:boolean,error:string,retry():void}}){return state.loading?<p role="status">Loading…</p>:state.error?<div role="alert" className="explorer-error">{state.error} <button onClick={state.retry}>Retry</button></div>:null;}
