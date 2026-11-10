import {KCC20_PROGRAMS} from '../shared/kcc20Programs';
import {verifiedKascovDeclaration} from '../shared/kcc20Metadata';
import {hex64,p2shScript,ownerAddress} from '../shared/publicCrypto';
type Get=(url:string)=>Promise<any>;
const BASE='https://kascov.io/data/mainnet';
export const OBSOLETE_KCC20=new Set([
  '9bf2df2cd4a05b8124082c868e79c52eb4d719362af2e1a75c025cfb50a2844e',
  '36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f',
]);
const reference=KCC20_PROGRAMS[0]!.template.referenceCommit;
const envelope=(data:any,extra:any={})=>({data,meta:{network:'mainnet',reference_commit:reference,read_source:'kascov'} as any,...extra});
export class Kcc20Kascov {
  constructor(readonly get:Get){}
  private reads=new Map<string,{at:number;task:Promise<any>}>();
  private states=new Map<string,Map<string,any>>();
  private owners=new Map<string,Set<string>>();
  rememberOwner(cid:string,owner:string){if(hex64.test(cid)&&hex64.test(owner)){if(this.owners.size>128)this.owners.clear();let values=this.owners.get(cid);if(!values)this.owners.set(cid,values=new Set());values.add(owner);}}
  async fetch(path:string){
    const old=this.reads.get(path);if(old&&Date.now()-old.at<10000)return old.task;
    if(this.reads.size>128)this.reads.clear();
    const task=this.get(BASE+path).then(v=>{if(v?.network!=='mainnet')throw Error('Kascov returned a different network.');return v;});
    this.reads.set(path,{at:Date.now(),task});try{return await task;}catch(e){this.reads.delete(path);throw e;}
  }
  async token(cid:string){
    const detail=await this.fetch(`/token/${cid}`),t=detail?.token;
    if(t?.covenant_id!==cid||t.status!=='verified')throw Error('Kascov token is not verified.');
    const hash=t.layout==='kcc20-46'?[...OBSOLETE_KCC20][0]:t.standard?.template_hash??t.template_hash;
    const declaration=verifiedKascovDeclaration(cid,t),decimals=declaration?.decimals;
    return {covenant_id:cid,template_hash:hash,
      ...(detail.market?.program?.token_covenant_id===cid&&String(detail.market.program.skeleton).toLowerCase().startsWith('kasseal ')?{wallet_standard:'kasseal-kcc20'}:{}),
      recognition:KCC20_PROGRAMS.some(p=>p.hash===hash)?'hash_proven_program_artifact':'unsupported',
      metadata:declaration?{...declaration,covenant_id:cid,binding_verified:true,image_uri:declaration.image}:{},
      ...(Number.isInteger(decimals)?{token_units:{status:'verified',decimals}}:{})};
  }
  async balance(cid:string,owner:string){
    if(!hex64.test(cid)||!hex64.test(owner))throw Error('Invalid Kascov token owner.');
    const token=await this.token(cid),program=KCC20_PROGRAMS.find(p=>p.hash===token.template_hash);
    if(!program||program.template.referenceCommit!==reference)throw Error('Unsupported Kascov KCC20 program.');
    const {prefix,suffix}=program.template;
    const data=await this.fetch(`/token/${cid}/cells?owner=00${owner}&limit=1000`);
    if(data.token_id!==cid||data.owner!==`00${owner}`||!Array.isArray(data.cells)||data.cells.length>1000||
      ['omitted_over_limit','omitted_unproven','omitted_unvalued'].some(k=>data[k]!==0))throw Error('Kascov cell discovery is incomplete; no zero balance is assumed.');
    const outputs:any[]=[],seen=new Set<string>();let total=0n;
    let states=this.states.get(cid);if(!states)this.states.set(cid,states=new Map());
    if(this.states.size>128)this.states.delete(this.states.keys().next().value!);
    for(const cell of data.cells){
      const point=String(cell?.outpoint??''),parts=point.split(':'),index=Number(parts[1]),redeem=String(cell?.program_hex??'');
      if(!cell||typeof cell!=='object'||parts.length!==2||!hex64.test(parts[0]!)||!/^(0|[1-9][0-9]{0,9})$/.test(parts[1]!)||!Number.isInteger(index)||index<0||index>0xffffffff||seen.has(point)||
        cell.is_minter!==false||!redeem.startsWith(prefix)||!redeem.endsWith(suffix)||redeem.length!==prefix.length+224+suffix.length)throw Error('Invalid, duplicate or unsupported Kascov cell.');
      seen.add(point);const s=redeem.slice(prefix.length,prefix.length+224);
      if(s.slice(0,2)!=='08'||s.slice(18,20)!=='20'||s.slice(20,84)!==owner||s.slice(84,90)!=='010001'||s.slice(92,94)!=='20'||s.slice(158,160)!=='20')throw Error('Kascov cell ownership or state layout differs.');
      const amount=BigInt('0x'+s.slice(2,18).match(/../g)!.reverse().join('')),borrow=parseInt(s.slice(90,92),16),guard=s.slice(94,158),extension=s.slice(160,224),deposit=String(cell.value_sompi);
      if(amount>0x7fffffffffffffffn||!Number.isInteger(borrow)||borrow>3||!hex64.test(guard)||!hex64.test(extension)||
        cell.amount_str!==amount.toString()||cell.owner!==`00${owner}`||cell.borrow_scheme!==borrow.toString(16).padStart(2,'0')||cell.borrow_guard!==guard||cell.extension_commitment!==extension||
        !/^\d+$/.test(deposit)||BigInt(deposit)<=0n||BigInt(deposit)>0x7fffffffffffffffn||cell.script_hex!==await p2shScript(redeem))throw Error('Kascov program, policy, amount or P2SH commitment differs.');
      total+=amount;if(total>0x7fffffffffffffffn)throw Error('KCC20 balance overflow.');
      outputs.push({txid:parts[0],output_index:index,balance_raw:String(amount),amount_sompi:deposit});
      states.set(point,{io_index:index,covenant_id:cid,actor:'KCC20',token_amount:String(amount),owner_scheme:0,owner_value:owner,state_hash_verified:true,template_hash:program.hash,borrow_scheme:borrow,borrow_guard:guard,extension_commitment:extension});
    }
    return envelope({covenant_id:cid,owner_scheme:0,owner_value:owner,available:true,balance_raw:String(total),outputs});
  }
  async read(path:string,ownerHint?:string){
    const url=new URL('https://reader.invalid'+path),p=url.pathname.split('/').filter(Boolean).map(decodeURIComponent),q=url.searchParams;
    if(p.length===3&&p[0]==='addresses'&&p[2]==='tokens'){
      const address=p[1]!;if(!ownerHint||address!==await ownerAddress(ownerHint))throw Error('Invalid KCC20 address.');
      const query=new URLSearchParams({limit:'100',...(q.has('cursor')?{before_token:q.get('cursor')!}:{})});
      const page=await this.fetch(`/addr/${encodeURIComponent(address)}.json?${query}`);
      if(page.address!==address||page.pubkey!==ownerHint||!Array.isArray(page.token_holdings)||page.token_holdings.length>100)throw Error('Kascov account identity differs.');
      const amounts=new Map<string,bigint>(),seen=new Set<string>();let unverified=false;
      for(const row of page.token_holdings){
        const cid=String(row?.token_id??row?.covenant_id),text=String(row?.balance_str??row?.balance),key=`${cid}:${row?.class??''}`;
        if(!hex64.test(cid)||!/^\d+$/.test(text)||seen.has(key))throw Error('Invalid or duplicate Kascov account holding.');
        seen.add(key);const amount=BigInt(text);if(amount===0n)continue;if(row.status!=='verified'){unverified=true;continue;}amounts.set(cid,(amounts.get(cid)??0n)+amount);
      }
      const cursor=page.next_before_token,stale=!Number.isFinite(Number(page.tip_at_ms))||Math.abs(Date.now()-Number(page.tip_at_ms))>300000;
      const result=envelope([...amounts].map(([cid,amount])=>({covenant_id:cid,owner_scheme:0,owner_value:ownerHint,balance_raw:String(amount),balance_complete:true})),{
        address_context:{address,network:'mainnet',owner_scheme:0,owner_value:ownerHint,balances_complete:Object.hasOwn(page,'next_before_token')&&!unverified&&!stale,unknown_tokens_attributable_to_address:unverified||!Object.hasOwn(page,'next_before_token')},
        pagination:{has_more:cursor!=null,next_cursor:cursor}});
      result.meta.snapshot_id=`kascov:${page.tip_daa}`;result.meta.stale=stale;return result;
    }
    if(p[0]==='tokens'&&hex64.test(p[1]??'')){
      const cid=p[1]!;if(p.length===2)return envelope(await this.token(cid));
      if(p.length===3&&p[2]==='balance'&&q.get('scheme')==='00')return this.balance(cid,q.get('owner')??'');
      if(p.length===4&&p[2]==='transactions'&&hex64.test(p[3]!)){
        const id=p[3]!;if(![...(this.states.get(cid)?.keys()??[])].some(k=>k.startsWith(id+':')))for(const owner of [...(this.owners.get(cid)??[])].slice(0,32))await this.balance(cid,owner);
        const outputs=[...(this.states.get(cid)??[])].filter(([k])=>k.startsWith(id+':')).map(([,v])=>v);
        if(!outputs.length)throw Error('Kascov has no verified current state for this transaction.');
        return envelope({txid:id,outputs,components_complete:false});
      }
    }
    throw Error('This KCC20 read is unavailable from Kascov.');
  }
}
