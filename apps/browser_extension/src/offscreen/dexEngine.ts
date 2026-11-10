// No wallet secrets enter this engine. Each host call requires the background's
// per-operation capability; only one shared Dart context runs at a time.
declare global {interface Window {kaspireDexInvoke?:(request:string)=>Promise<string>;kaspireDexHost?:(request:string)=>Promise<string>;}}
let loading:Promise<void>|undefined,queue:Promise<unknown>=Promise.resolve();
function load(){return loading??=new Promise<void>((resolve,reject)=>{
  const script=document.createElement('script');script.src=chrome.runtime.getURL('dex/engine.js');
  script.onload=()=>{if(typeof window.kaspireDexInvoke!=='function'){loading=undefined;reject(Error('Shared DEX engine did not initialize.'));}else resolve();};
  script.onerror=()=>{loading=undefined;reject(Error('Shared DEX engine could not load.'));};document.head.append(script);
});}
chrome.runtime.onMessage.addListener((message,_sender,respond)=>{
  if(message?.kind!=='dex-engine-invoke')return false;
  if(!/^[a-f0-9]{64}$/.test(message.capability??'')||typeof message.payload!=='string'||message.payload.length>2000000){respond({error:'Invalid DEX engine request.'});return false;}
  const run=async()=>{
    await load();const capability=message.capability;
    window.kaspireDexHost=async request=>{
      const result=await chrome.runtime.sendMessage({kind:'dex-engine-host',capability,request});
      return JSON.stringify(result??{ok:false,error:'DEX background disconnected.'});
    };
    // Establish the caller's current account/network binding before any work.
    const ready=JSON.parse(await window.kaspireDexHost(JSON.stringify({operation:'guard',body:{}})));
    if(!ready.ok)throw Error(ready.error);
    try{return {result:await window.kaspireDexInvoke!(message.payload)};}
    finally{window.kaspireDexHost=async()=>JSON.stringify({ok:false,error:'DEX operation expired.'});}
  };
  const task=queue.then(run);queue=task.catch(()=>{});
  void task.then(respond).catch(e=>respond({error:String(e?.message??e)}));return true;
});
export {};
