import test from 'node:test';
import assert from 'node:assert/strict';
import {walletHistory,walletHistoryForAddresses,krc20History,walletAssetCategory,observeCovenantAssets} from './generated/api.mjs';
const address='kaspa:activity-fixture';
const tx=i=>({transaction_id:i.toString(16).padStart(64,'0'),block_time:1792800000000+i,inputs:[],outputs:[{amount:'100000000',script_public_key_address:address}]});
test('standard KCC20 holdings publish before stalled legacy AND later standard balances finish, and reopen replays them',async t=>{
  const wallet='kaspa:qq6gtjt56mnekawylufsacxdyz4srwq3sv5cx7edhrknkun4wa7lgt8fklfu0',owner='3485c974d6e79b75c4ff130ee0cd20ab01b8118329837b2db8ed3b7275777df4',cid='82f033aed87d6eb39f509b51b1c817a49e0b07c4789b619cab08d4c8fb82d18e';
  const old=globalThis.fetch;let release,releaseTail,publish,finished=false,timer;
  const legacy=new Promise(resolve=>{release=resolve;}),progress=new Promise(resolve=>{publish=resolve;});
  const tail=new Promise(resolve=>{releaseTail=resolve;});
  const stop=observeCovenantAssets(wallet,items=>{if(items.some(r=>r.covenantId===cid))publish(items);});
  t.after(()=>{release();releaseTail();stop();clearTimeout(timer);globalThis.fetch=old;});
  globalThis.fetch=async url=>{
    if(String(url).includes('kcc20.info/v1/status'))await legacy;
    if(!String(url).startsWith('https://kasvio.network/api/kcc20/v1/'))return new Response('{}',{status:503});
    const path=new URL(url).pathname;
    const other='b'.repeat(64),token={covenant_id:cid,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:{binding_verified:true,ticker:'KASPIREISTHEBESTKASPAWALLET',decimals:8}};
    if(path.endsWith('/'+other+'/balance'))await tail;
    const data=path.endsWith('/status')?{status:'ready'}:path.endsWith('/tokens')?[token,{...token,covenant_id:other}]:{covenant_id:path.endsWith('/'+other+'/balance')?other:cid,owner_value:owner,owner_scheme:0,available:true,balance_raw:path.endsWith('/'+other+'/balance')?'0':'59973229',outputs:[]};
    return new Response(JSON.stringify({data,meta:{network:'mainnet',reference_commit:'c8a087117735a1f87c5c6d115fcddeaf2562c784'}}));
  };
  const job=walletAssetCategory(wallet,'mainnet','kcc20').finally(()=>{finished=true;});
  const rows=await Promise.race([progress,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('No independent standard holdings update')),5000);})]);
  assert.equal(finished,false);assert.equal(rows[0].rawBalance,'59973229');
  let replay;const stopReopened=observeCovenantAssets(wallet,items=>{replay=items;});
  assert.deepEqual(replay,rows);stopReopened();releaseTail();release();
  assert.equal((await job)[0].symbol,'KASPIREISTHEBESTKASPAWALLET');
});
test('native history paginates using bounded 100-row requests',async t=>{
  const old=globalThis.fetch,requests=[];t.after(()=>{globalThis.fetch=old;});
  globalThis.fetch=async url=>{
    const q=new URL(url).searchParams,n=Number(q.get('limit')),offset=Number(q.get('offset'));requests.push({n,offset});
    return new Response(JSON.stringify(Array.from({length:Math.min(n,160-offset)},(_,i)=>tx(offset+i))),{status:200});
  };
  const rows=await walletHistory(address,'mainnet',151);
  assert.equal(rows.length,151);assert.deepEqual(requests,[{n:100,offset:0},{n:51,offset:100}]);
});
test('invalid native history tries independent fallback and never means an empty wallet',async t=>{
  const old=globalThis.fetch; t.after(()=>{globalThis.fetch=old;});
  const hosts=[];globalThis.fetch=async url=>{hosts.push(new URL(url).host);return new Response(JSON.stringify({error:'invalid history'}));};
  await assert.rejects(walletHistory(address,'mainnet'),/Invalid account history/);
  assert.deepEqual(hosts,['kaspire.kaslab.space','api.kaspa.org']);
});
test('partial HD failure retains healthy address history and warns',async t=>{
  const old=globalThis.fetch;t.after(()=>{globalThis.fetch=old;});let warning='';
  globalThis.fetch=async url=>String(url).includes('bad-address')?new Response('{}',{status:503}):new Response(JSON.stringify([tx(1)]));
  const rows=await walletHistoryForAddresses([address,'kaspa:bad-address'],'mainnet',51,w=>{warning=w;});
  assert.equal(rows.length,1);assert.match(warning,/Some account addresses/);
});
test('large KRC20 history amounts are canonical, direct and paginated',async t=>{
  const old=globalThis.fetch;t.after(()=>{globalThis.fetch=old;});let calls=0;
  globalThis.fetch=async url=>{
    assert.equal(new URL(url).pathname,'/v1/krc20/oplist');const page=calls++;
    return new Response(JSON.stringify({result:Array.from({length:50},(_,i)=>({hashRev:(page*50+i+1).toString(16).padStart(64,'0'),tick:'souls',dec:'8',amt:'2100000000000',from:'kaspa:sender',to:address,mtsAdd:'1792800000000',opAccept:'1'})),next:page===0?'page2':''}));
  };
  const rows=await krc20History(address,51);
  assert.equal(rows.length,51);assert.equal(rows[0].displayAmount,'21000');assert.equal(calls,2);
});
test('progressive KRC20 assets have own-hosted logos before market enrichment',async t=>{
  const old=globalThis.fetch;t.after(()=>{globalThis.fetch=old;});
  globalThis.fetch=async()=>new Response(JSON.stringify({result:[{tick:'nacho',balance:'2100000000000',dec:'8'}]}));
  const rows=await walletAssetCategory('kaspa:logo-fixture','mainnet','tokens');
  assert.equal(rows[0].image_url,'https://kaspire.kaslab.space/api/token-logos/krc20/nacho');
});
