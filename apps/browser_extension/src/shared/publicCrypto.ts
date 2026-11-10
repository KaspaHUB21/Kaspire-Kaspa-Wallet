// Public-script operations only. No keys or signatures are accepted here.
// Reuse the already bundled Kaspa SDK, never remote executable code.
import {loadKaspa} from '@kronsdk/kron-sdk/wasm';
async function sdk():Promise<any>{
  return (loadKaspa as any)(typeof chrome!=='undefined'&&chrome.runtime?.getURL
    ?chrome.runtime.getURL('wasm/kron_kaspa_bg.wasm'):undefined);
}
export const hex64=/^[0-9a-f]{64}$/;
export async function p2shScript(program:string){
  if(!/^(?:[0-9a-f]{2})+$/.test(program)||program.length>2000000)throw Error('Invalid public script.');
  const k=await sdk(),script=k.payToScriptHashScript(program);
  try{return String(script.script);}finally{script.free();}
}
export async function publicDigest(program:string){return (await p2shScript(program)).slice(4,-2);}
export async function scriptAddress(packed:string,network='mainnet'){
  if(!/^(?:[0-9a-f]{2})+$/.test(packed)||packed.length<6)throw Error('Invalid script public key.');
  const k=await sdk(),script=new k.ScriptPublicKey(parseInt(packed.slice(0,4),16),packed.slice(4));
  try{const address=k.addressFromScriptPublicKey(script,network);if(!address)throw Error('Unsupported address script.');try{return address.toString();}finally{address.free();}}finally{script.free();}
}
export async function ownerAddress(owner:string,network='mainnet'){
  if(!hex64.test(owner))throw Error('Invalid public owner.');
  return scriptAddress(`000020${owner}ac`,network);
}
