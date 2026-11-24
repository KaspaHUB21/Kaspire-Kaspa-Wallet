import {useEffect,useState} from "react";
import {getWalletKcc20Holdings} from "./api";
import type {Kcc20WalletHoldings} from "../types/token";

export function useWalletKcc20Holdings(address:string|undefined,enabled:boolean){
  const key=enabled&&address?address:"";
  const [state,setState]=useState<{key:string;data:Kcc20WalletHoldings|null;loading:boolean;error:string|null}>({key,data:null,loading:!!key,error:null});
  useEffect(()=>{
    let active=true;setState({key,data:null,loading:!!key,error:null});
    if(!key)return()=>{active=false;};
    const load=()=>getWalletKcc20Holdings(key).then(envelope=>{
      if(active)setState({key,data:envelope.data,loading:false,error:null});
    }).catch((error:Error)=>{if(active)setState(previous=>({...previous,loading:false,error:error.message}));});
    void load();const timer=window.setInterval(load,60000);
    const visible=()=>{if(document.visibilityState==="visible")void load();};document.addEventListener("visibilitychange",visible);
    return()=>{active=false;window.clearInterval(timer);document.removeEventListener("visibilitychange",visible);};
  },[key]);
  return state.key===key?state:{key,data:null,loading:!!key,error:null};
}

