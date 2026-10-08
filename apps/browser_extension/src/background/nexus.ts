// Notification bearer only: browser-session RAM, TRUSTED_CONTEXTS only. Never
// persistent local/sync storage, signing secrets or dApp-accessible storage.
const base='https://kaspire.kaslab.space/nexus-test-v1';
type Context={address:string,generation:number,revision:number};
let session:(Context&{token:string,expires:number})|null=null;
export function nexusDisconnect(){session=null;}
export function nexusConnected(context:Context){
  if(!session||session.address!==context.address||session.generation!==context.generation||session.revision!==context.revision||session.expires<Date.now()){session=null;return false;}
  return true;
}
export function nexusSetSession(context:Context,result:any){
  if(result.walletAddress!==context.address||typeof result.token!=='string'||result.token.length>1024)throw Error('Invalid Nexus wallet session.');
  session={...context,token:result.token,expires:Date.now()+7*86400000};
  if(typeof chrome!=='undefined'&&chrome.storage?.session){const saved={address:session.address,token:session.token,expires:session.expires};void (async()=>{await chrome.storage.session.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});await chrome.storage.session.set({kaspireNexusNotifications:saved});})().catch(()=>{});}
}
export async function nexusRestoreSession(context:Context){
  if(nexusConnected(context))return true;
  if(typeof chrome==='undefined'||!chrome.storage?.session)return false;
  await chrome.storage.session.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
  const saved=(await chrome.storage.session.get('kaspireNexusNotifications')).kaspireNexusNotifications;
  if(saved?.address!==context.address||typeof saved.token!=='string'||saved.token.length>1024||!Number.isFinite(saved.expires)||saved.expires<=Date.now())return false;
  session={...context,token:saved.token,expires:saved.expires};return true;
}
export async function nexusRequest(context:Context,path:string,query:Record<string,string>={},body?:Record<string,unknown>){
  if(!/^(?:auth\/internal-(?:challenge|verify)|search|collection\/[A-Za-z0-9_-]{1,32}|nft\/[A-Za-z0-9_-]{1,32}\/\d{1,20}|offers(?:\/active|\/c[a-z0-9]{10,64}\/(?:counter|decline|agree-to-relist|accept-counter|cancel))?|dashboard\/(?:sent|received|notifications)|notifications\/read)$/.test(path))throw Error('Invalid Nexus request.');
  const privateRequest=path.startsWith('dashboard/')||path==='notifications/read'||(path.startsWith('offers')&&body!==undefined);
  if(privateRequest&&!nexusConnected(context))throw Error('Unlock your wallet to access private offers.');
  const url=new URL(base+'/'+path);for(const[k,v]of Object.entries(query))url.searchParams.set(k,String(v));
  const response=await fetch(url,{method:body===undefined?'GET':'POST',headers:{'content-type':'application/json',...(privateRequest?{authorization:`Bearer ${session!.token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)}),redirect:'error',signal:AbortSignal.timeout(45000)});
  const data=await response.json();
  if(response.status===401){nexusDisconnect();if(typeof chrome!=='undefined'&&chrome.storage?.session)await chrome.storage.session.remove('kaspireNexusNotifications');}
  if(!response.ok)throw Error(data.error??`Nexus unavailable (${response.status}).`);
  return data;
}
export function validateNexusChallenge(address:string,challenge:any){
  const message=String(challenge.message??''),nonce=String(challenge.nonce??''),expiry=Date.parse(challenge.expiresAt);
  const issuedAt=message.match(/\nIssued at: ([^\n]+)\n/)?.[1]??'',issued=Date.parse(issuedAt);
  const expected=`Kaspire Internal NFT Offers\n\nDomain: kaspire.kaslab.space\nPurpose: internal-private-offers-v1\nWallet: ${address}\nNonce: ${nonce}\nIssued at: ${issuedAt}\nExpires at: ${challenge.expiresAt}\n\nAuthenticate this wallet for private offers and notifications inside Kaspire only.\nThis signature does not create a transaction or spend funds.`;
  if(message!==expected||!/^[A-Za-z0-9_-]{43}$/.test(nonce)||!Number.isFinite(issued)||!Number.isFinite(expiry)||expiry-issued<=0||expiry-issued>360000)throw Error('Invalid internal wallet authentication challenge. Nothing was signed.');
  return message;
}
