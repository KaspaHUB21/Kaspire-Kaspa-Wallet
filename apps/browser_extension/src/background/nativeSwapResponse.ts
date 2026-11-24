const clockUrl='https://kaspire.kaslab.space/api/local-node/info/blockdag';
const exactError='Native swap data exceeds exact browser integer range. Nothing was signed.';
// Android's pool planner only reads virtualDaaScore from this endpoint. Node
// difficulty is floating-point telemetry, not a coin amount or signing input.
// Project that one response BEFORE applying the unchanged exact-number guard.
export function nativeSwapResponse(url:string,bytes:Uint8Array<ArrayBuffer>):Uint8Array<ArrayBuffer>{
 let raw=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
 if(url===clockUrl){
  const body=JSON.parse(raw),daa=body?.virtualDaaScore;
  if(!body||Array.isArray(body)||(typeof daa!=='number'&&typeof daa!=='string')||
   (typeof daa==='number'&&!Number.isSafeInteger(daa))||!/^\d{1,16}$/.test(String(daa))||
   BigInt(daa)<10n||BigInt(daa)>BigInt(Number.MAX_SAFE_INTEGER))throw Error('Invalid exact native swap node clock. Nothing was signed.');
  raw=JSON.stringify({virtualDaaScore:daa});
 }
 JSON.parse(raw,(_,value)=>{
  if(typeof value==='number'&&(!Number.isFinite(value)||Number.isInteger(value)&&!Number.isSafeInteger(value)))throw Error(exactError);
  return value;
 });
 return url===clockUrl?new TextEncoder().encode(raw):bytes;
}
