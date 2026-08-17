import{isProviderRequest,PROVIDER_CHANNEL,type ProviderEvent,type ProviderResponse}from"../shared/protocol";
const script=document.createElement("script");script.src=chrome.runtime.getURL("inpage.js");script.async=false;(document.head||document.documentElement).appendChild(script);script.remove();
addEventListener("message",async event=>{if(event.source!==window||event.origin!==location.origin||!isProviderRequest(event.data))return;const request=event.data;let response:ProviderResponse;try{const result=await chrome.runtime.sendMessage({kind:"provider",origin:location.origin,request});response={channel:PROVIDER_CHANNEL,direction:"response",id:request.id,...result}}catch{response={channel:PROVIDER_CHANNEL,direction:"response",id:request.id,error:{code:-32603,message:"Kaspire could not process this request."}}}postMessage(response,location.origin)});

type StoredState={network?:string;selectedAddress?:string|null;permissions?:Record<string,{accounts?:boolean;evmChainId?:number}>};
chrome.runtime.onMessage.addListener(message=>{if(message?.kind!=="providerStateChanged")return;const previous=(message.previous??{})as StoredState;const current=(message.current??{})as StoredState;const wasConnected=previous.permissions?.[location.origin]?.accounts===true;const connected=current.permissions?.[location.origin]?.accounts===true;const emit=(event:ProviderEvent["event"],data:unknown)=>postMessage({channel:PROVIDER_CHANNEL,direction:"event",event,data} satisfies ProviderEvent,location.origin);
  if(wasConnected&&!connected){emit("accountsChanged",[]);emit("disconnect",{code:4900,message:"Kaspire disconnected this site."});return}
  if(!connected)return;
  if(!wasConnected||previous.selectedAddress!==current.selectedAddress)emit("accountsChanged",current.selectedAddress?[current.selectedAddress]:[]);
  if(previous.network!==current.network)emit("networkChanged",current.network);
  const previousChain=previous.permissions?.[location.origin]?.evmChainId;
  const currentChain=current.permissions?.[location.origin]?.evmChainId;
  if(previousChain!==currentChain&&currentChain)emit("chainChanged",`0x${currentChain.toString(16)}`);
});
