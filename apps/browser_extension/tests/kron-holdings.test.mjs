import test from 'node:test';
import assert from 'node:assert/strict';
import {directKronAssets, directKronTransfer} from './generated/kronHoldings.mjs';
import {walletAssetCategory, kcc20TransferData} from './generated/api.mjs';
const id = '05f2718333af36854fa503f6cac402dcf5485a925ef0614874482b752efe848a';
const address = 'kaspa:qrtfmlgmpa4k7el9xmuu9m477h24y24gpwxfhpg40rdxpmeuqy6ecfjxwudq4';
const txid = 'a'.repeat(64), script = 'aa20' + 'b'.repeat(64) + '87';
function source({kasvioDown=false, decimals=0, duplicate=false, wrongId=false, spent=false, nativeConflict=false}={}) {
  return async url => {
    if (url.endsWith('/info')) return {result:{network:'mainnet',networkOk:true,synced:true,divergent:false}};
    const holding = {tick:'KASM',balance:'1000000',dec:decimals,covenantId:id};
    if (url.endsWith('/tokenlist')) return {result:[holding,...(duplicate?[holding]:[])]};
    if (url.startsWith('https://kasvio.network')) {
      if (kasvioDown) throw new Error('offline');
      return {stale:false,source:{available:true},tokens:[{id,price:'0.01',logo:'https://example.org/kasm.png',balance:'0'}]};
    }
    if (url.includes('/local-node/transactions/')) return {transaction_id:txid,is_accepted:true,outputs:[{index:0,covenant_id:id,amount:'23000000',script_public_key:script,script_public_key_address:address}]};
    if (url.includes('/local-node/addresses/')) return spent ? [] : [{outpoint:{transactionId:txid,index:0},utxoEntry:{amount:nativeConflict?'1':'23000000',scriptPublicKey:{scriptPublicKey:script},isCoinbase:false}}];
    if (url.endsWith('/utxos')) return {result:[{outpoint:{transactionId:txid,index:0},amount:'1000000',ownerAddress:address,redeemScriptHex:'aa',scriptPublicKey:script}]};
    return {result:[{...holding,covenantId:wrongId?'c'.repeat(64):id,graduated:false}]};
  };
}
test('launchpad holdings survive Kasvio outage', async () => {
  const [asset] = await directKronAssets(source({kasvioDown:true}),address);
  assert.equal(asset.rawBalance,'1000000'); assert.equal(asset.standard,'kron-native'); assert.equal(asset.image_url,'');
});
test('Kasvio cannot replace balances and prices use display units', async () => {
  const [asset] = await directKronAssets(source({decimals:3}),address);
  assert.equal(asset.rawBalance,'1000000'); assert.equal(asset.priceKas,10); assert.equal(asset.image_url,'https://example.org/kasm.png');
});
test('duplicate covenant holdings are rejected', async () => {
  await assert.rejects(directKronAssets(source({duplicate:true}),address),/duplicate/);
});
test('ticker cannot resolve to a different covenant for signing', async () => {
  await assert.rejects(directKronTransfer(source({wrongId:true}),address,id,1,'https://node'),/ticker/);
});
test('native UTXO value comes from the node, never the token amount', async () => {
  const data = await directKronTransfer(source(),address,id,1,'https://node');
  assert.equal(data.cells[0].tokenAmount,1000000); assert.equal(data.cells[0].value,23000000);
});
test('spent or conflicting token outputs cannot reach signing', async () => {
  for (const opts of [{spent:true},{nativeConflict:true}]) await assert.rejects(directKronTransfer(source(opts),address,id,1,'https://node'),/spent or pending/);
});
test('overspending is rejected with a balance error', async () => {
  await assert.rejects(directKronTransfer(source(),address,id,1000001,'https://node'),/Insufficient/);
});
test('extension keeps direct KRON assets when kcc20.info and Kascov fail', async () => {
  const previous = globalThis.fetch;
  globalThis.fetch = async url => {
    if (String(url).includes('kcc20.info') || String(url).includes('kascov.io')) return new Response('offline',{status:503});
    return new Response(JSON.stringify(await source()(String(url))),{status:200});
  };
  try {
    const assets = await walletAssetCategory(address,'mainnet','kcc20');
    assert.equal(assets.length,1); assert.equal(assets[0].rawBalance,'1000000'); assert.equal(assets[0].covenantId,id);
  } finally {globalThis.fetch = previous;}
});
test('legacy KCC20 lookup and node-checked transfer survive kcc20.info shutdown', async () => {
  const wallet = 'kaspa:qpxavn7m8d9tqhj4j3gjnpkdlnhj4c3rznnd85xps4368hhx6etlqtsmtgvwr';
  const owner = '4dd64fdb3b4ab05e5594512986cdfcef2ae22314e6d3d0c18563a3dee6d657f0';
  const legacyId = 'c'.repeat(64), previous = globalThis.fetch;
  globalThis.fetch = async input => {
    const url = String(input);
    if (url.includes('kcc20.info') || url.includes('idx.kron.technology') || url.includes('kasvio.network')) return new Response('offline',{status:503});
    let result;
    if (url.includes('/addr/')) result = {pubkey:owner,token_holdings:[{token_id:legacyId,status:'verified'}]};
    else if (url.includes(`/token/${legacyId}`)) result = {token:{status:'verified',claimed_ticker:'LEGACY',claimed_decimals:2},
      balances:[{owner,balance:'1000'}],events:[{owner_to:owner,txid,delta_idx:0,balance_to:1000}]};
    else if (url.includes(`/c/${legacyId}.json`)) result = {kcc1_template_hash:'d'.repeat(64),lineage_complete:true,
      utxos:[{outpoint:`${txid}:0`,value:23000000,created_daa:123,script_hex:script}]};
    else if (url.includes('/local-node/transactions/')) result = {transaction_id:txid,is_accepted:true,outputs:[{index:0,covenant_id:legacyId,amount:'23000000',script_public_key:script,script_public_key_address:wallet}]};
    else if (url.includes('/local-node/addresses/')) result = [{outpoint:{transactionId:txid,index:0},utxoEntry:{amount:'23000000',scriptPublicKey:{scriptPublicKey:script},isCoinbase:false}}];
    else throw new Error(`Unexpected ${url}`);
    return new Response(JSON.stringify(result),{status:200});
  };
  try {
    const assets = await walletAssetCategory(wallet,'mainnet','kcc20');
    assert.equal(assets[0].symbol,'LEGACY'); assert.equal(assets[0].rawBalance,'1000');
    const data = await kcc20TransferData(wallet,legacyId,1);
    assert.equal(data.ticker,'LEGACY'); assert.equal(data.cells[0].tokenAmount,1000);
    assert.equal(data.cells[0].valueSompi,23000000);
    await assert.rejects(kcc20TransferData(wallet,legacyId,1001),/Insufficient/);
  } finally {globalThis.fetch = previous;}
});
