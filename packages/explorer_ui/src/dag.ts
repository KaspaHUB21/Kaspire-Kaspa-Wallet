export type DagBlock={hash:string;parents:string[];selectedParentHash:string|null;daaScore:string;blueScore:string;timestampMs:number;txCount:number|null;observedAt:number};
export type DagSnapshot={schemaVersion:1;network:'mainnet';epoch:string;status:string;serverTime:number;lastBlockAt:number|null;sequence:number;windowLimit:number;observedBps:number|null;info:{blockCount:string;virtualDaaScore:string}|null;blocks:DagBlock[]};
const hash=(v:unknown):v is string=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const uint=(v:unknown):v is string=>typeof v==='string'&&/^\d{1,20}$/.test(v)&&BigInt(v)<(1n<<64n);
const time=(v:unknown):v is number=>typeof v==='number'&&Number.isSafeInteger(v)&&v>=0&&v<=8640000000000000;
export function parseDag(d:any):DagSnapshot {
 if(d?.schemaVersion!==1||d.network!=='mainnet'||typeof d.epoch!=='string'||!/^[a-f0-9-]{16,64}$/.test(d.epoch)||!['live','warming','stale','reconnecting','unavailable','node-unsynced'].includes(d.status)||!time(d.serverTime)||d.lastBlockAt!==null&&(!time(d.lastBlockAt)||d.lastBlockAt>d.serverTime)||!Number.isSafeInteger(d.sequence)||d.sequence<0||d.windowLimit!==240||!Array.isArray(d.blocks)||d.blocks.length>240)throw Error('Invalid Mainnet BlockDAG response.');
 if(d.observedBps!==null&&(typeof d.observedBps!=='number'||!Number.isFinite(d.observedBps)||d.observedBps<0||d.observedBps>10000))throw Error('Invalid block-rate observation.');
 if(d.info!==null&&(!uint(d.info.blockCount)||!uint(d.info.virtualDaaScore)))throw Error('Invalid DAG totals.');
 const seen=new Set();for(const b of d.blocks){if(!hash(b.hash)||seen.has(b.hash)||!uint(b.daaScore)||!uint(b.blueScore)||!time(b.timestampMs)||!time(b.observedAt)||b.observedAt>d.serverTime||!Array.isArray(b.parents)||b.parents.length>256||b.parents.some((p:unknown)=>!hash(p)||p===b.hash)||new Set(b.parents).size!==b.parents.length||b.selectedParentHash!==null&&(!hash(b.selectedParentHash)||!b.parents.includes(b.selectedParentHash))||b.txCount!==null&&(!Number.isSafeInteger(b.txCount)||b.txCount<0||b.txCount>100000))throw Error('Invalid observed block or parent links.');seen.add(b.hash);}
 layoutDag(d.blocks);
 return d;
}
export type DagNode=DagBlock&{column:number;lane:number;x:number;y:number};
export function layoutDag(blocks:DagBlock[],previous=new Map<string,DagNode>()) {
 const byHash=new Map(blocks.map(b=>[b.hash,b])),children=new Map<string,string[]>(),pending=new Map<string,number>(),columns=new Map<string,number>();
 for(const b of blocks){const known=b.parents.filter(p=>byHash.has(p));pending.set(b.hash,known.length);for(const p of known)children.set(p,[...(children.get(p)??[]),b.hash]);}
 const compare=(a:string,b:string)=>{const x=BigInt(byHash.get(a)!.daaScore),y=BigInt(byHash.get(b)!.daaScore);return x<y?-1:x>y?1:a.localeCompare(b);};
 const ready=blocks.filter(b=>!pending.get(b.hash)).map(b=>b.hash).sort(compare),order:DagBlock[]=[];
 while(ready.length){const id=ready.shift()!,b=byHash.get(id)!;const parentColumn=Math.max(-1,...b.parents.map(p=>columns.get(p)??previous.get(p)?.column??-1));columns.set(id,Math.max(previous.get(id)?.column??0,parentColumn+1));order.push(b);for(const c of children.get(id)??[]){pending.set(c,pending.get(c)!-1);if(!pending.get(c)){ready.push(c);ready.sort(compare);}}}
 if(order.length!==blocks.length)throw Error('Invalid cyclic block links.');
 const groups=new Map<number,DagBlock[]>();for(const b of order){const c=columns.get(b.hash)!;groups.set(c,[...(groups.get(c)??[]),b]);}
 const lanes=Math.max(7,...[...groups.values()].map(g=>g.length)),nodes:DagNode[]=[];
 for(const [column,group]of groups){const used=new Set<number>();for(const b of group){let lane=previous.get(b.hash)?.lane??parseInt(b.hash.slice(0,4),16)%lanes;while(used.has(lane))lane=(lane+1)%Math.max(lanes,group.length);used.add(lane);nodes.push({...b,column,lane,x:column*56+30,y:lane*48+32});}}
 const positions=new Map(nodes.map(n=>[n.hash,n]));
 const edges=nodes.flatMap(n=>n.parents.filter(p=>positions.has(p)).map(p=>({from:positions.get(p)!,to:n,selected:n.selectedParentHash===p})));
 return {nodes,edges,width:Math.max(100,...nodes.map(n=>n.x+40)),height:Math.max(340,...nodes.map(n=>n.y+40))};
}
export function hitDag(nodes:DagNode[],x:number,y:number,zoom:number):DagNode|null {
 let nearest:DagNode|null=null,distance=Infinity;for(const n of nodes){const d=Math.hypot(n.x-x,n.y-y);if(d<distance&&Math.abs(n.x-x)<Math.max(22,18/zoom)&&Math.abs(n.y-y)<Math.max(17,18/zoom)){nearest=n;distance=d;}}return nearest;
}
