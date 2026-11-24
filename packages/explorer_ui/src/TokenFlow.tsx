import {Link} from 'react-router-dom';import {useRead} from './nativeApi';import {publicImage} from './images';
import {exactTokenAmount} from './amount';
function TokenFlow({cid,txid}:{cid:string,txid:string}){const s=useRead('https://kaspatoken.kaslab.space/api/kcc20/token/'+cid+'/transaction/'+txid),d=s.data?.data;
 if(!d)return s.error?<details className="kaspa-panel rounded-md p-3 my-3 text-xs text-kaspa-muted"><summary>Additional covenant details are not indexed</summary><p className="break-all">{cid}</p><button onClick={s.retry}>Retry</button></details>:null;
 return <article className="kaspa-panel my-4 p-4 rounded-md" data-token-flow={cid}><div className="flex gap-3 items-center">{d.image_url?<img src={publicImage(d.image_url)} className="h-12 w-12 object-contain" alt=""/>:null}<div><h2>{d.symbol} · KCC20</h2><p className="text-sm text-kaspa-muted">Token transfer / covenant transition</p></div></div><Link className="break-all text-xs block my-3" to={'/kcc20/'+cid}>Token covenant: {cid}</Link>{!d.components_complete?<p>Token indexing is incomplete; known owner changes are shown.</p>:null}
 {d.changes.map((c:any,i:number)=><div className={'chain-row '+(c.direction==='from'?'out':'in')} key={i}><strong className="tx-value">{c.direction==='from'?'↑ −':'↓ +'}{exactTokenAmount(c.raw_amount,d.decimals)} {d.decimals!==null?d.symbol:''}</strong>{c.owner_address?<Link className="block break-all text-xs" to={'/wallet/krc20/'+encodeURIComponent(c.owner_address)}>{c.owner_address}</Link>:<p className="break-all text-xs">Contract owner: {c.owner_payload}</p>}</div>)}</article>;
}
export function TransactionTokens({tx}:{tx:any}){const ids=[...new Set<string>([...(tx.inputs??[]),...(tx.outputs??[])].map(c=>c.covenant_id??c.covenant?.covenant_id??'').filter(id=>/^[a-f0-9]{64}$/.test(id)&&!/^0+$/.test(id)))].slice(0,8);
 return <>{ids.map(cid=><TokenFlow key={cid} cid={cid} txid={tx.transaction_id}/>)}</>;
}
