// Read-only, bounded transport. No injected wallet provider or signing channel.
(()=>{'use strict';const pending=new Map();let sequence=0;
 window.__explorerReply=(id,response)=>{const p=pending.get(id);if(!p)return;pending.delete(id);clearTimeout(p.timer);response.error?p.reject(Error(response.error)):p.resolve(new Response(response.body,{status:response.status,headers:{'content-type':'application/json'}}));};
 window.fetch=(input,options={})=>new Promise((resolve,reject)=>{
  if(pending.size>=24)return reject(Error('Explorer is busy. Please retry.'));
  if(!window.ExplorerRead)return reject(Error('Explorer read transport is unavailable.'));
  const url=String(input),id=String(++sequence),method=options.method||'GET';
  const timer=setTimeout(()=>{pending.delete(id);reject(Error('Explorer request timed out. Please retry.'));},45000);
  const abort=()=>{const p=pending.get(id);if(p){pending.delete(id);clearTimeout(timer);reject(new DOMException('Aborted','AbortError'));}};
  if(options.signal?.aborted){clearTimeout(timer);abort();reject(new DOMException('Aborted','AbortError'));return;}
  options.signal?.addEventListener('abort',abort,{once:true});
  pending.set(id,{resolve:v=>{options.signal?.removeEventListener('abort',abort);resolve(v)},reject:e=>{options.signal?.removeEventListener('abort',abort);reject(e)},timer});
  try{window.ExplorerRead.postMessage(JSON.stringify({id,url,method,body:options.body??null}));}catch(e){const p=pending.get(id);pending.delete(id);clearTimeout(timer);p.reject(e);}
 });
})();
