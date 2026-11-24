import {useState} from "react";
import {Link} from "react-router-dom";
import type {Kcc20WalletStatus,WalletTokenBalance} from "../types/token";
import {formatTokenAmount} from "../utils/format";
import {publicImage,kcc20LogoFallback} from '../images';
import {TokenLogo} from './TokenLogo';
import {exactTokenAmount} from '../amount';

import {displayableKcc20} from "../utils/kcc20Visibility";

interface Props {tokens:WalletTokenBalance[];loading:boolean;error:string|null;confirmed:boolean;status:Kcc20WalletStatus|null}
export const visibleKcc20Holdings=(tokens:WalletTokenBalance[])=>tokens.filter(displayableKcc20);
export function kcc20BalanceCount({tokens,loading,error,confirmed,status}:Props):string {
  tokens=visibleKcc20Holdings(tokens);
  if(tokens.length)return String(tokens.length);
  if(loading)return "Loading…";
  if(error||status?.balance_state==="unavailable")return "Unavailable";
  return confirmed&&status?.balance_state==="ready"?"0":"Incomplete";
}

export function WalletKcc20Holdings(props:Props){
  const [expanded,setExpanded]=useState(false);
  const {loading,error,status,confirmed}=props,tokens=visibleKcc20Holdings(props.tokens),visible=expanded?tokens:tokens.slice(0,8);
  return <div className="kaspa-panel mb-5 rounded-md p-5" data-wallet-standard="kcc20">
    <div className="flex flex-wrap items-center justify-between gap-3">
      <h2 className="text-lg font-bold text-kaspa-text">KCC20 Balances</h2>
      {tokens.length>8?<button onClick={()=>setExpanded(v=>!v)} className="focus-ring rounded-md border border-kaspa-border px-3 py-2 text-sm font-bold">{expanded?"Show less":"Show all"}</button>:null}
    </div>
    {loading?<p role="status" className="mt-3 text-sm text-kaspa-muted">Loading KCC20 balances independently…</p>:null}
    {error||status?.balance_state==="unavailable"?<p role="alert" className="mt-3 text-sm text-kaspa-muted">KCC20 balances are temporarily unavailable. This is not a confirmed empty wallet.</p>:null}
    {!loading&&!error&&status?.balance_state==="partial"?<p role="status" className="mt-3 text-sm text-kaspa-muted">KCC20 coverage is incomplete. Already discovered holdings are shown; more balances may still be indexing.</p>:null}
    {!loading&&!error&&confirmed&&status?.balance_state==="ready"&&!tokens.length?<p className="mt-3 text-sm text-kaspa-muted">No KCC20 balances found</p>:null}
    {status?.balance_warnings?.length?<p className="mt-2 text-xs text-kaspa-muted">{status.balance_warnings.join(" ")}</p>:null}
    <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{visible.map(token=><Link key={token.token_id||token.contract_address} to={`/kcc20/${token.contract_address||token.token_id?.replace(/^kcc20-/,"")}`} className="rounded-md border border-kaspa-border bg-kaspa-background p-4 transition hover:border-kaspa-primary/70">
      <div className="flex items-center gap-3"><TokenLogo src={publicImage(token.image_url)} fallbackSrcs={[kcc20LogoFallback(token.contract_address||token.token_id?.replace(/^kcc20-/,""))]} symbol={token.symbol}/><div className="min-w-0"><div className="break-all text-sm font-bold">{token.symbol}</div>{token.name!==token.symbol?<div className="truncate text-xs text-kaspa-muted">{token.name}</div>:null}</div></div>
      <div className="mt-3 text-lg font-bold text-kaspa-primary">{token.raw_balance?exactTokenAmount(token.raw_balance,token.decimals??null):formatTokenAmount(token.balance)}</div>{token.balance===null?<p className="text-xs text-kaspa-muted">Token decimals {token.units_status==='conflict'?'conflict':'are not published'}. No display amount is assumed.</p>:null}
    </Link>)}</div>
  </div>;
}

