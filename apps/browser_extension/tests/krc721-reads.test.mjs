import test from 'node:test';
import assert from 'node:assert/strict';
import {nftWalletPage,nftMetadata,requireUnlistedNft,nftImage} from './generated/krc721Reads.mjs';
import {walletAssetCategory} from './generated/api.mjs';
const address='kaspa:qz03mracsz6c0pjxmsdaql39453tn3jgmrldkqpy24ea39rxtvd9xxynslpyc';
const response=value=>new Response(JSON.stringify(value));
async function mocked(fetcher,run){const old=globalThis.fetch;globalThis.fetch=fetcher;try{await run();}finally{globalThis.fetch=old;}}
test('healthy local empty NFT inventory is authoritative',()=>mocked(async url=>{assert.match(String(url),/krc721-read-v1/);return response({result:[],next:null});},async()=>assert.deepEqual((await nftWalletPage(address)).result,[])));
test('unreachable local NFT source invokes only the official fallback',async()=>{const calls=[];await mocked(async url=>{calls.push(String(url));return calls.length===1?new Response('',{status:503}):response({result:[{tick:'TEST',tokenId:'1'}]});},async()=>assert.equal((await nftWalletPage(address)).result.length,1));assert.match(calls[1],/krc721-indexer.kaspa.com/);assert.equal(calls.length,2);});
test('local 404 and malformed successful JSON do not fall through',async()=>{for(const make of [()=>new Response('',{status:404}),()=>response({}),()=>new Response('bad-json')]){let calls=0;await mocked(async()=>{calls++;return make();},async()=>assert.rejects(nftWalletPage(address)));assert.equal(calls,1);}});
test('explicit local unknown rarity does not invoke KaspaCom',()=>mocked(async url=>{assert.match(String(url),/krc721-read-v1/);return response({items:[{tokenId:'55',rarityRank:null}],ranksAvailable:true});},async()=>assert.equal((await nftMetadata('KASZOMBIES',['55']))[0].rarityRank,null)));
test('metadata fallback preserves local traits and does not replace known ranks',async()=>{let calls=0;await mocked(async()=>++calls===1?response({items:[{tokenId:'1',rarityRank:12,traits:{color:'red'}},{tokenId:'2',rarityRank:null}],ranksAvailable:false}):response({items:[{tokenId:'1',rarityRank:999},{tokenId:'2',rarityRank:33}]}),async()=>{const rows=await nftMetadata('TEST',['1','2']);assert.equal(rows[0].rarityRank,12);assert.deepEqual(rows[0].traits,{color:'red'});assert.equal(rows[1].rarityRank,33);});});
test('transaction preflight is official-only and rejects existing listings',()=>mocked(async url=>{assert.match(String(url),/^https:\/\/krc721-indexer.kaspa.com/);return response({result:{owner:address,status:{state:'listed'}}});},()=>assert.rejects(requireUnlistedNft(address,'TEST','1'),/Cancel its listing/)));
test('transaction preflight fails closed if official indexer is unavailable',()=>mocked(async()=>new Response('',{status:503}),()=>assert.rejects(requireUnlistedNft(address,'TEST','1'),/unavailable/)));
test('images use the allowlisted local read gateway',()=>{assert.equal(nftImage('TEST','1'),'https://kaspire.kaslab.space/krc721-read-v1/images/TEST/1');assert.throws(()=>nftImage('../TEST','1'));});
test('collection thumbnails use held token IDs across wallet pagination',async()=>{
  let page=0;
  await mocked(async url=>{
    assert.match(String(url),/krc721-read-v1/);
    return response(++page===1?{result:[{tick:'HASH',tokenId:'423'},{tick:'HASH',tokenId:'424'}],next:'next-page'}:{result:[{tick:'KASZOMBIES',tokenId:'55'}],next:null});
  },async()=>{
    const rows=await walletAssetCategory(address,'mainnet','krc721');
    assert.equal(rows.find(row=>row.symbol==='HASH').balance,2);
    assert.equal(rows.find(row=>row.symbol==='HASH').image_url,nftImage('HASH','423'));
    assert.equal(rows.find(row=>row.symbol==='KASZOMBIES').image_url,nftImage('KASZOMBIES','55'));
    assert.equal(page,2);
  });
});
