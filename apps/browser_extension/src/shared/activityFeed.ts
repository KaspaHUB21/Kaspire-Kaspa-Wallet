export type ActivityResult = {items:any[]; warnings?:string[]};
export function mergeActivity(sources:Iterable<any[]>) {
  const merged=new Map<string,any>();
  for(const rows of sources)for(const row of rows) {
    if(!row || typeof row.transactionId!=='string' || !row.transactionId)continue;
    const kind=String(row.assetKind??row.symbol??'').replaceAll('-','').toUpperCase();
    const identity=kind==='KAS'?'KAS':kind==='KRC20'?String(row.assetSymbol??'').toUpperCase():row.tokenId??row.covenantId??row.assetSymbol??'';
    const key=`${row.transactionId}:${kind}:${identity}`;
    const previous=merged.get(key)??{};
    if(previous.unitSource==='verified-kcc20'&&row.unitSource!=='verified-kcc20') {
      merged.set(key,{...row,...previous});continue;
    }
    merged.set(key,{...previous,...Object.fromEntries(Object.entries(row).filter(([,v])=>v!=null&&v!==''&&!(Array.isArray(v)&&!v.length)))});
  }
  return [...merged.values()].sort((a,b)=>Number(b.blockTime??0)-Number(a.blockTime??0));
}
/** Public display data only. Slow sources never block healthy sources. */
export class ActivityFeed {
  limit=50;
  rows=new Map<string,any[]>();
  loading=new Set<string>();
  warnings=new Map<string,string>();
  private versions=new Map<string,number>();
  snapshot() {
    const rows=mergeActivity(this.rows.values());
    return {items:rows.slice(0,this.limit),hasMore:rows.length>this.limit};
  }
  showMore(){this.limit+=50;}
  async load(source:string,loader:()=>Promise<ActivityResult>,change:()=>void) {
    const version=(this.versions.get(source)??0)+1;
    this.versions.set(source,version);this.loading.add(source);this.warnings.delete(source);change();
    try {
      const result=await loader();
      if(this.versions.get(source)!==version)return;
      if(!Array.isArray(result?.items))throw Error('Invalid activity response.');
      this.rows.set(source,result.warnings?.length?mergeActivity([this.rows.get(source)??[],result.items]):result.items);
      if(result.warnings?.length)this.warnings.set(source,result.warnings.join(' '));
    }catch {
      if(this.versions.get(source)===version)this.warnings.set(source,`${source} is temporarily unavailable. Previously loaded entries are retained.`);
    }finally {
      if(this.versions.get(source)===version){this.loading.delete(source);change();}
    }
  }
}
