import test from 'node:test';
import assert from 'node:assert/strict';
import {family,page,orderId,browseBody,issueToken,readToken,writeBody,purchaseOutcome,rankedKrc20,rankedKrc721,historyFilters,sellerTransportMetadata} from './kaspacom-market-protocol.mjs';
test('NFT catalog matches explorer volume ranking before twenty-item pagination',()=>{
  const tokens=Array.from({length:45},(_,i)=>({symbol:'NFT'+i,volume_30d_kas:i}));
  tokens.push({symbol:'NFT44',volume_30d_kas:9999},{symbol:'../invalid',volume_30d_kas:99999});
  const ranked=rankedKrc721(tokens);
  assert.equal(ranked.length,45);
  assert.deepEqual(ranked.slice(0,20).map(t=>t.symbol),Array.from({length:20},(_,i)=>'NFT'+(44-i)));
  assert.equal(ranked.slice(20,40).length,20);assert.equal(ranked.slice(40,60).length,5);
  assert.deepEqual(rankedKrc721([
    {symbol:'A',volume_30d_kas:1,volume_7d_kas:1},
    {symbol:'B',volume_30d_kas:1,volume_7d_kas:2},
    {symbol:'C',volume_30d_kas:1,volume_7d_kas:2,volume_24h_kas:2},
    {symbol:'D',volume_30d_kas:1,volume_7d_kas:2,volume_24h_kas:2,all_time_volume_kas:10},
  ]).map(t=>t.symbol),['D','C','B','A']);
});
test('seller and buyer history are separated upstream before pagination',()=>{
  assert.deepEqual(historyFilters('seller'),{isSeller:true,isBuyer:false,statuses:['LISTED_FOR_SALE']});
  assert.deepEqual(historyFilters('buyer'),{isSeller:false,isBuyer:true});
  assert.deepEqual(historyFilters('sales'),{isSeller:true,isBuyer:false,statuses:['COMPLETED']});
  assert.throws(()=>historyFilters('invalid'));
});
test('KRC20 unit-price order is global and independent of requested sort',()=>{
  for(const sort of ['recent','low','high']) assert.deepEqual(browseBody('krc20',new URLSearchParams({sort,offset:'20'})).sort,{direction:'asc',field:'pricePerToken'});
});
test('NFT transport restores only original seller DAA metadata without touching signatures',()=>{
  const input={transactionId:'a'.repeat(64),index:0,signatureScript:'signed',utxo:{amount:'105000000',scriptPublicKey:'script',blockDaaScore:'555484350',isCoinbase:false}};
  const buyer={id:'b'.repeat(64),inputs:[input,{signatureScript:'buyer-signature'}],outputs:[{value:'100'}]};
  const seller={inputs:[{...input,utxo:{...input.utxo,blockDaaScore:'555484348'}}]};
  const actual=JSON.parse(sellerTransportMetadata(JSON.stringify(buyer),JSON.stringify(seller)));
  assert.equal(actual.inputs[0].utxo.blockDaaScore,'555484348');
  actual.inputs[0].utxo.blockDaaScore=input.utxo.blockDaaScore;
  assert.deepEqual(actual,buyer);
  for(const field of ['transactionId','index']){
    const bad=structuredClone(seller);bad.inputs[0][field]='wrong';
    assert.throws(()=>sellerTransportMetadata(JSON.stringify(buyer),JSON.stringify(bad)));
  }
  for(const field of ['amount','scriptPublicKey','isCoinbase','blockDaaScore']){
    const bad=structuredClone(seller);bad.inputs[0].utxo[field]='wrong';
    assert.throws(()=>sellerTransportMetadata(JSON.stringify(buyer),JSON.stringify(bad)));
  }
});
test('catalog uses explorer ranking, warning tokens last and deterministic ties',()=>{
  const rows=[{symbol:'DAGAS',verified:true,market_cap_usd:1e9},{symbol:'B',volume_30d_usd:9},{symbol:'A',volume_30d_usd:9},{symbol:'NACHO',verified:true,market_cap_usd:99},{symbol:'BAD/PATH'}];
  assert.deepEqual(rankedKrc20(rows).map(t=>t.symbol),['NACHO','A','B','DAGAS']);
  assert.equal(rows[0].symbol,'DAGAS');
});
test('purchase refusal preserves a bounded backend reason without exposing signed data',()=>{
  const success={success:true,transactionId:'a'.repeat(64)};
  assert.equal(purchaseOutcome(success),success);
  assert.throws(()=>purchaseOutcome({success:false,errorCode:17,errorMessage:'Order unavailable',signedBuyerPskt:'PRIVATE_PAYLOAD'}),/code 17.*Order unavailable/);
  assert.throws(()=>purchaseOutcome({success:false,error:{message:'Invalid buyer'}}),/Invalid buyer/);
  assert.throws(()=>purchaseOutcome({success:false,signedBuyerPskt:'PRIVATE_PAYLOAD'}),/No reason supplied/);
  assert.throws(()=>purchaseOutcome({success:'true'}),/refused/);
  try{purchaseOutcome({success:false,errorMessage:'x'.repeat(1000)});}catch(e){assert.ok(e.message.length<450);}
});
const address='kaspa:qqnvxvumjvzwmn755v8nrp4jxm2w50dv9mr2u4qrfqpq3h2hzyjx7tgkdtdgs';
test('relay allows only the three marketplace families and bounded pagination',()=>{
  for(const k of ['krc20','krc721','kns'])assert.ok(family(k));
  for(const k of ['admin','../auth','constructor','__proto__'])assert.throws(()=>family(k));
  for(const n of [-1,1.5,'NaN',1000001])assert.throws(()=>page(n));
  assert.equal(page('10'),10);assert.throws(()=>orderId('../auth'));
});
test('browse sorting is upstream/global and KNS search is escaped',()=>{
  const b=browseBody('kns',new URLSearchParams({search:'a.*.kas',sort:'low',offset:'20'}));
  assert.deepEqual(b.sort,{direction:'asc',field:'totalPrice'});
  assert.equal(b.pagination.limit,10);assert.equal(b.pagination.offset,20);
  assert.deepEqual(b.filters.assets,['a\\.\\*\\.kas']);assert.equal(b.onlyDecentralize,true);
});
test('NFT rank and traits are sent upstream before ten-item pagination',()=>{
  for(const [sort,direction]of [['rankLow','asc'],['rankHigh','desc']]){
    const b=browseBody('krc721',new URLSearchParams({sort,search:'KASZOMBIES',offset:'10',traits:JSON.stringify({Background:'bloodDAG'})}));
    assert.deepEqual(b.sort,{direction,field:'rarityRank'});assert.deepEqual(b.traits,{Background:'bloodDAG'});assert.equal(b.pagination.offset,10);
  }
  assert.throws(()=>browseBody('krc20',new URLSearchParams({sort:'rankLow'})));
  for(const traits of ['null','[]','{"a":1}'])assert.throws(()=>browseBody('krc721',new URLSearchParams({traits})));
});
test('wallet tokens expire, are purpose bound and reject tampering',()=>{
  const secret=Buffer.alloc(32,1),token=issueToken(address,secret,1000);
  assert.equal(readToken(token,secret,2000),address);
  assert.equal(readToken(token,secret,3601000),null);
  assert.equal(readToken(token,Buffer.alloc(32,2),2000),null);
  assert.equal(readToken(token+'x',secret,2000),null);
  assert.equal(readToken(token,secret,999),null);
});
test('writes strip arbitrary fields and enforce price/PSKT/asset identity',()=>{
  const base={totalPrice:1.25,psktSeller:JSON.stringify({inputs:[{}],outputs:[{}]}),ticker:'NACHO',quantity:2,admin:true};
  assert.equal(writeBody('krc20','create',base).admin,undefined);
  for(const totalPrice of [0,-1,NaN,1.251])assert.throws(()=>writeBody('krc20','create',{...base,totalPrice}));
  assert.throws(()=>writeBody('krc20','create',{...base,ticker:'../x'}));
  assert.throws(()=>writeBody('krc721','create',{...base,tokenId:'foo'}));
  assert.throws(()=>writeBody('kns','create',{...base,assetId:'foo'}));
  assert.throws(()=>writeBody('krc20','verify',{transactionId:'bad'}));
  assert.throws(()=>writeBody('krc20','buy',{signedBuyerPskt:'not json'}));
});
