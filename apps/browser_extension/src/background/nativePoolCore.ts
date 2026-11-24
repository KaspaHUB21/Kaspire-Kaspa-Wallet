import init,* as native from 'kaspire-trestly-wasm';
declare const KASPIRE_TRESTLY_WASM_SHA256:string;
let loading:Promise<void>|undefined;
async function load(){
 return loading??=(async()=>{
  const response=await fetch(chrome.runtime.getURL('wasm/trestly_web_core_bg.wasm'),{cache:'no-store',redirect:'error',credentials:'omit'});
  if(!response.ok)throw Error('Native swap core is unavailable. Reload the complete extension.');
  const bytes=await response.arrayBuffer(),sha=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(n=>n.toString(16).padStart(2,'0')).join('');
  if(sha!==KASPIRE_TRESTLY_WASM_SHA256)throw Error('Mixed native swap core detected. Reload the complete extension. Nothing was signed.');
  await init({module_or_path:bytes});
 })().catch(error=>{loading=undefined;throw error;});
}
export async function nativePoolCore(){
 await load();
 return {describe:(request:string)=>JSON.parse(native.describeTrestly(request)),prepare:(request:string)=>JSON.parse(native.prepareTrestly(request)),
  sign:(secret:string,request:string,hash:string)=>{
   const bytes=new TextEncoder().encode(secret);
   try{return JSON.parse(native.signTrestly(bytes,request,hash));}finally{bytes.fill(0);}
  }};
}
