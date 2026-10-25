import {randomUUID} from 'node:crypto';
const id=/^[a-f0-9]{64}$/;
const unsigned=value=>/^\d+$/.test(String(value??''))?BigInt(value):null;
/** Shared, read-only snapshots. Rank the complete catalogue, never one page. */
export class RankedCatalogue {
  constructor(get,now=Date.now){this.get=get;this.now=now;this.snapshots=new Map();this.latest=null;this.pending=null;}
  async volumes(deadline=this.now()+25000) {
    const totals=new Map(),seen=new Set(),cursors=new Set();let cursor='';
    const since=this.now()-86400000;
    for(let page=0;page<20;page++) {
      if(this.now()>deadline)throw Error('Volume lookup deadline exceeded');
      const data=await this.get('/tape?'+new URLSearchParams({limit:'150',...(cursor?{cursor}:{})}));
      if(!Array.isArray(data.items))throw Error('Invalid volume feed');
      let allOlder=data.items.length>0;
      for(const row of data.items) {
        const time=Number(row.timeMs);
        if(!Number.isSafeInteger(time)||time>=since)allOlder=false;
        if(row.kind!=='trade')continue;
        const amount=unsigned(row.trade?.kasSompi);
        if(!id.test(row.tokenId??'')||!id.test(row.txid??'')||amount===null||!Number.isSafeInteger(time))throw Error('Invalid volume receipt');
        const key=row.tokenId+':'+row.txid;
        if(seen.has(key)||time<since||time>this.now()+300000)continue;
        seen.add(key);totals.set(row.tokenId,(totals.get(row.tokenId)??0n)+amount);
      }
      if(!data.nextCursor||allOlder)return totals;
      if(typeof data.nextCursor!=='string'||data.nextCursor.length>1024||cursors.has(data.nextCursor))throw Error('Incomplete volume feed');
      cursor=data.nextCursor;cursors.add(cursor);
    }
    throw Error('Volume feed exceeds bounded history');
  }
  async build() {
    const deadline=this.now()+25000;
    const tokens=new Map(),cursors=new Set();let cursor='';
    for(let page=0;page<20;page++) {
      if(this.now()>deadline)throw Error('Catalogue lookup deadline exceeded');
      const data=await this.get('/tokens?'+new URLSearchParams({sort:'mcap',limit:'100',...(cursor?{cursor}:{})}));
      if(!Array.isArray(data.tokens))throw Error('Invalid token catalogue');
      for(const row of data.tokens)if(row.verification==='verified'&&id.test(row.meta?.covenantId??''))tokens.set(row.meta.covenantId,row);
      if(!data.nextCursor)break;
      if(typeof data.nextCursor!=='string'||data.nextCursor.length>1024||cursors.has(data.nextCursor)||page===19)throw Error('Incomplete token catalogue');
      cursor=data.nextCursor;cursors.add(cursor);
    }
    let volumes=null;
    try{volumes=await this.volumes(deadline);}catch{/* Missing volume is unknown, never zero. Market-cap ranking remains available. */}
    const rows=[...tokens.values()].map(row=>({...row,volume24hSompi:volumes?(volumes.get(row.meta.covenantId)??0n).toString():null}));
    rows.sort((a,b)=>{
      for(const key of ['marketCapSompi','volume24hSompi']) {
        const x=unsigned(a[key]),y=unsigned(b[key]);
        if(x!==y){if(x===null)return 1;if(y===null)return -1;return x>y?-1:1;}
      }
      return a.meta.covenantId.localeCompare(b.meta.covenantId);
    });
    const snapshot={id:randomUUID(),at:this.now(),rows,volumeComplete:volumes!==null};
    this.snapshots.set(snapshot.id,snapshot);this.latest=snapshot;
    for(const [key,value]of this.snapshots)if(this.now()-value.at>300000||this.snapshots.size>6)this.snapshots.delete(key);
    return snapshot;
  }
  async page(cursor='',search='') {
    if(typeof cursor!=='string'||cursor.length>1024||typeof search!=='string'||search.trim().length>64)throw Error('Invalid ranked query');
    const query=search.trim().toLowerCase();let snapshot,offset=0;
    if(cursor) {
      let parsed;try{parsed=JSON.parse(Buffer.from(cursor,'base64url').toString());}catch{throw Error('Invalid ranked cursor');}
      if(!Array.isArray(parsed)||parsed.length!==4||parsed[0]!=='mcap-volume-v1'||parsed[2]!==query||!Number.isInteger(parsed[3])||parsed[3]<0||parsed[3]%20)throw Error('Cursor does not match this ranked query');
      snapshot=this.snapshots.get(parsed[1]);offset=parsed[3];
      if(!snapshot||this.now()-snapshot.at>300000)throw Error('Catalogue snapshot expired. Refresh to load the latest ranking.');
    }else{
      if(this.latest&&this.now()-this.latest.at<60000)snapshot=this.latest;
      else {if(!this.pending)this.pending=this.build().finally(()=>{this.pending=null;});snapshot=await this.pending;}
    }
    const rows=query?snapshot.rows.filter(row=>[row.meta.covenantId,row.meta.ticker,row.meta.name].some(value=>String(value??'').toLowerCase().includes(query))):snapshot.rows;
    return {tokens:rows.slice(offset,offset+20),nextCursor:offset+20<rows.length?Buffer.from(JSON.stringify(['mcap-volume-v1',snapshot.id,query,offset+20])).toString('base64url'):null,
      ranking:{primary:'marketCapSompi',secondary:'volume24hSompi',window:'24h',volumeComplete:snapshot.volumeComplete},
      ...(snapshot.volumeComplete?{}:{warning:'24h volume is temporarily unavailable. Tokens remain sorted by market cap.'})};
  }
}
