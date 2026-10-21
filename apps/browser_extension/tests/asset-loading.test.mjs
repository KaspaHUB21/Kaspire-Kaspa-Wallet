import test from 'node:test';
import assert from 'node:assert/strict';
import {walletAssetCategory,kcc20DiscoveryWarning,selectedKcc20Asset} from './generated/api.mjs';

test('KRC20 uses the healthy direct mirror, sorts A-Z and does not query unrelated categories', async () => {
  const previous = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async url => {
    calls.push(String(url));
    if (String(url).includes('api.kasplex.org')) throw new Error('Kasplex offline');
    assert.match(String(url), /kaspire\.kaslab\.space.*tokenlist/);
    return new Response(JSON.stringify({result:[{tick:'ZZZ',balance:'100',dec:0},{tick:'AAA',balance:'200',dec:0}]}));
  };
  try {
    const rows = await walletAssetCategory('kaspa:test-loading', 'mainnet', 'tokens');
    assert.deepEqual(rows.map(row=>row.symbol), ['AAA','ZZZ']);
    assert.equal(calls.length, 2);
  } finally {globalThis.fetch=previous;}
});

test('invalid fast mirror cannot hide tokens from a slower valid response', async () => {
  const previous=globalThis.fetch;
  globalThis.fetch=async url=>new Response(JSON.stringify(String(url).includes('kaspire.kaslab.space')?{}:{result:[{tick:'TEST',dec:8,balance:'100000000'}]}));
  try {assert.equal((await walletAssetCategory('kaspa:test-invalid', 'mainnet', 'tokens'))[0].symbol,'TEST');}
  finally {globalThis.fetch=previous;}
});
test('preparing a selected KCC20 token never scans the wallet or complete catalogue',async()=>{
  const previous=globalThis.fetch,calls=[],cid='e'.repeat(64);
  globalThis.fetch=async input=>{
    const url=String(input);calls.push(url);
    assert.ok(url.endsWith('/tokens/'+cid));
    return new Response(JSON.stringify({data:{covenant_id:cid,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:{binding_verified:true,ticker:'WALLET',decimals:8}},meta:{network:'mainnet',reference_commit:'c8a087117735a1f87c5c6d115fcddeaf2562c784'}}));
  };
  try {
    const token=await selectedKcc20Asset('kaspa:qp30ahte7r7qq6lum8utxf99nftffwgeg6sewgs49fz89tzpc36mxk89jjqlf',cid);
    assert.equal(token.standard,'kcc20');assert.equal(token.symbol,'WALLET');assert.equal(calls.length,1);
  } finally {globalThis.fetch=previous;}
});

test('real KCC20 category path keeps standard tokens when another balance fails',async()=>{
  const previous=globalThis.fetch;
  // Valid public fixture address, including its checksum.
  const wallet='kaspa:qp30ahte7r7qq6lum8utxf99nftffwgeg6sewgs49fz89tzpc36mxk89jjqlf';
  const ids=['a'.repeat(64),'b'.repeat(64),'c'.repeat(64)];
  const meta={network:'mainnet',reference_commit:'c8a087117735a1f87c5c6d115fcddeaf2562c784'};
  globalThis.fetch=async input=>{
    const u=new URL(String(input));
    if(!u.pathname.startsWith('/api/kcc20/v1/'))throw Error('Other KCC20 sources offline');
    let data;
    if(u.pathname.endsWith('/status'))data={status:'ready'};
    else if(u.pathname.endsWith('/tokens'))data=ids.map((id,i)=>({covenant_id:id,profile_id:'KCC20PublicMint@c8a0871',recognition:'hash_proven_reference_actor_family',metadata:{binding_verified:true,ticker:['WALLET','Wobbly.k','BROKEN'][i],decimals:0}}));
    else if(u.pathname.includes(ids[2]))return new Response('{}',{status:503});
    else data={covenant_id:u.pathname.split('/').at(-2),owner_value:u.searchParams.get('owner'),owner_scheme:0,available:true,balance_raw:'42',outputs:[]};
    return new Response(JSON.stringify({data,meta}));
  };
  try {
    const assets=await walletAssetCategory(wallet,'mainnet','kcc20');
    assert.deepEqual(assets.map(a=>a.symbol),['WALLET','WOBBLY.K']);
    assert.match(kcc20DiscoveryWarning(wallet),/Some standard KCC20 balances/);
  }finally{globalThis.fetch=previous;}
});
