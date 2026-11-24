import test from 'node:test';import assert from 'node:assert/strict';import {build} from 'esbuild';
await build({entryPoints:['src/chain.tsx'],outfile:'/tmp/explorer-chain.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {exactJson,rawAmount,kas,movement}=await import('/tmp/explorer-chain.mjs');
await build({entryPoints:['src/amount.ts'],outfile:'/tmp/explorer-amount.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {exactTokenAmount}=await import('/tmp/explorer-amount.mjs');
await build({entryPoints:['src/utils/chartScale.ts'],outfile:'/tmp/explorer-chart-scale.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {chartScale,axisUnit,axisNumber}=await import('/tmp/explorer-chart-scale.mjs');
await build({entryPoints:['src/utils/nftRarity.ts'],outfile:'/tmp/explorer-nft-rarity.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {nftRarityLabel,compareNftRarity}=await import('/tmp/explorer-nft-rarity.mjs');
await build({entryPoints:['src/components/WalletKcc20Holdings.tsx'],outfile:'/tmp/explorer-kcc20-holdings.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {visibleKcc20Holdings,kcc20BalanceCount}=await import('/tmp/explorer-kcc20-holdings.mjs');
await build({entryPoints:['src/blockTransaction.ts'],outfile:'/tmp/explorer-block-transaction.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {transactionLink,transactionReadPath,isCoinbase}=await import('/tmp/explorer-block-transaction.mjs');
test('block TX links retain a validated containing-block hint through the actual REST query',()=>{
 const id='a'.repeat(64),block='b'.repeat(64),link=transactionLink(id.toUpperCase(),block.toUpperCase());assert.equal(link,'/tx/'+id+'?blockHash='+block);
 const params=new URL(link,'https://local.test').searchParams,path=transactionReadPath(id,params.getAll('blockHash')),read=new URL(path,'https://local.test');
 assert.equal(read.pathname,'/transactions/'+id);assert.equal(read.searchParams.get('blockHash'),block);assert.equal(read.searchParams.get('resolve_previous_outpoints'),'light');
 assert.equal(transactionLink(id),'/tx/'+id);assert.equal(new URL(transactionReadPath(id),'https://local.test').searchParams.has('blockHash'),false);
 for(const v of ['', 'bad','https://evil.test',block+'&url=x']){assert.throws(()=>transactionLink(id,v));assert.throws(()=>transactionReadPath(id,[v]));}
 assert.throws(()=>transactionReadPath(id,[block,block]));assert.throws(()=>transactionReadPath('invalid',[block]));
});
test('coinbase is identified by its protocol subnetwork, never guessed from missing inputs',()=>{
 assert.equal(isCoinbase({subnetwork_id:'01'+'00'.repeat(19)}),true);assert.equal(isCoinbase({subnetwork_id:'00'.repeat(20)}),false);assert.equal(isCoinbase({}),false);
});
await build({entryPoints:['src/dag.ts'],outfile:'/tmp/explorer-dag.mjs',bundle:true,platform:'node',format:'esm',target:'node22'});
const {parseDag,layoutDag,hitDag}=await import('/tmp/explorer-dag.mjs');
const dagHash=n=>n.toString(16).padStart(64,'0');
const dagBlock=n=>({hash:dagHash(n),parents:[dagHash(n-1)],selectedParentHash:dagHash(n-1),daaScore:String(n),blueScore:String(n),timestampMs:1700000000000,observedAt:1700000000000,txCount:1});
const dagSnapshot=()=>({schemaVersion:1,network:'mainnet',epoch:'01234567-89ab-cdef-0123-456789abcdef',status:'live',serverTime:1700000000000,lastBlockAt:1700000000000,sequence:4,windowLimit:240,observedBps:10,info:{blockCount:'18446744073709551615',virtualDaaScore:'1000'},blocks:[dagBlock(2),dagBlock(3),dagBlock(4)]});
test('DAG validates network, bounded data, exact integers, real links and acyclic identity',()=>{
 const d=parseDag(dagSnapshot()),m=layoutDag(d.blocks);assert.equal(m.nodes.length,3);assert.equal(m.edges.length,2);assert(m.edges.every(e=>e.to.parents.includes(e.from.hash)&&e.selected));assert.equal(hitDag(m.nodes,m.nodes[0].x,m.nodes[0].y,1).hash,dagHash(2));assert.equal(hitDag(m.nodes,-100,-100,1),null);
 for(const change of [d=>d.network='testnet-10',d=>d.blocks.push(d.blocks[0]),d=>d.info.blockCount=9007199254740992,d=>d.blocks[0].selectedParentHash=dagHash(99),d=>d.blocks[0].parents=[dagHash(4)],d=>d.blocks=Array.from({length:241},(_,i)=>dagBlock(i+2))]){const d=dagSnapshot();change(d);assert.throws(()=>parseDag(d));}
});
test('DAG rolling layout keeps known positions, bounds its state and never invents parent edges',()=>{
 let previous=new Map();for(let n=3;n<340;n++){const blocks=Array.from({length:Math.min(240,n-1)},(_,i)=>dagBlock(Math.max(2,n-239)+i));const m=layoutDag(blocks,previous);for(const b of m.nodes)if(previous.has(b.hash))assert.equal(b.x,previous.get(b.hash).x);previous=new Map(m.nodes.map(n=>[n.hash,n]));assert(previous.size<=240);assert.equal(m.edges.length,m.nodes.length-1);}
 const d=dagSnapshot();d.blocks[1].parents=[];d.blocks[1].selectedParentHash=null;assert.equal(layoutDag(d.blocks).edges.length,1);
});
test('retired issuances and unidentified placeholders are display-only exclusions; partial never means zero',()=>{
 const rows=[{contract_address:'14ec7542182a0408f78f8ea4ad7ac135e7f41305c61e0053a67a2828e585984d',symbol:'HUB21',balance:null},{contract_address:'69001bc75394f3baf1863aad014c35275371935fad29e1d3a114aa23a4db721a',symbol:'TEST',balance:null},{contract_address:'1'.repeat(64),symbol:'NAMED',balance:null},{contract_address:'2'.repeat(64),symbol:'KCC20 222222',balance:null}];
 assert.equal(visibleKcc20Holdings(rows).length,1);assert.equal(visibleKcc20Holdings(rows)[0],rows[2]);assert.equal(rows.length,4);
 assert.equal(kcc20BalanceCount({tokens:[rows[0]],loading:false,error:null,confirmed:true,status:{balance_state:'ready'}}),'0');
 assert.equal(kcc20BalanceCount({tokens:[],loading:false,error:null,confirmed:true,status:{balance_state:'partial'}}),'Incomplete');
 assert.equal(kcc20BalanceCount({tokens:[],loading:false,error:'Source down',confirmed:false,status:null}),'Unavailable');
});
test('KASGOTHS Legendary order is 21, 420, 13, without relabelling ordinary ranks',()=>{
 const tokens=[{tokenId:'13',rarityRank:-1},{tokenId:'169',rarityRank:4},{tokenId:'420',rarityRank:-1},{tokenId:'21',rarityRank:-1},{tokenId:'2',rarityRank:null}];
 assert.deepEqual([...tokens].sort((a,b)=>compareNftRarity('KASGOTHS',a,b)).map(t=>t.tokenId),['21','420','13','169','2']);
 assert.deepEqual([...tokens].sort((a,b)=>String(a.tokenId).localeCompare(String(b.tokenId),undefined,{numeric:true})).map(t=>t.tokenId),['2','13','21','169','420']);
 for(const id of ['21','420','13'])assert.equal(nftRarityLabel('kasgoths',id,null),'Legendary');
 assert.equal(nftRarityLabel('hash','1',-1),'Legendary');assert.equal(nftRarityLabel('hash','21',100),100);assert.equal(nftRarityLabel('kasgoths','169',4),4);assert.equal(nftRarityLabel('hash','1',null),'Unavailable');
});
test('rounded chart ticks enclose observed values and align grid lines without duplicate labels',()=>{
 for(const values of [[.0243,.0284],[.02782317,.02782322],[.00000002,.00000003],[0,0],[500e12,620e12],[2,2],[999,1001]]){
  const s=chartScale(values);assert(s);assert(s.low<=Math.min(...values));assert(s.high>=Math.max(...values));assert(s.low>=0);assert(s.ticks.length>=3&&s.ticks.length<=8);
  assert(s.ticks.every((v,i)=>Number.isFinite(v)&&(!i||v<s.ticks[i-1])));const labels=s.ticks.map(v=>axisNumber(v,s.step));assert.equal(new Set(labels).size,labels.length);
 }
 assert.equal(chartScale([]),null);assert.equal(chartScale([NaN,Infinity,-1]),null);
 assert.equal(axisNumber(.0245,.0005),'0.0245');assert.equal(axisNumber(.02425,.00025),'0.02425');
});
test('hashrate axis uses a single explicit unit for the complete series',()=>{
 assert.deepEqual(axisUnit('price',.03),{label:'USD',divisor:1});assert.deepEqual(axisUnit('hashrate',800e12),{label:'PH/s',divisor:1e12});assert.equal(axisUnit('hashrate',1.2e15).label,'EH/s');
 const scale=chartScale([800e12,1200e12]),unit=axisUnit('hashrate',scale.high);assert.equal(unit.label,'EH/s');const labels=scale.ticks.map(v=>axisNumber(v/unit.divisor,scale.step/unit.divisor));assert.equal(new Set(labels).size,labels.length);
});
test('token displays preserve full raw integer precision and unknown units',()=>{assert.equal(exactTokenAmount('18446744073709551615',6),'18,446,744,073,709.551615');assert.equal(exactTokenAmount('3308',0),'3,308');assert.equal(exactTokenAmount('413005400000000',null),'413005400000000 raw units');assert.equal(exactTokenAmount('-1',8),'Unavailable')});
test('exact u64 amounts and signed wallet deltas, never rounded to JS doubles',()=>{const v=exactJson('{"a":18446744073709551615,"s":"18446744073709551615","n":1,"e":0.25}');assert.equal(v.a,'18446744073709551615');assert.equal(v.s,v.a);assert.equal(v.e,.25);assert.equal(rawAmount(9007199254740992),null);assert.equal(kas(v.a),'184,467,440,737.09551615 KAS');assert.equal(kas(-1n),'-0.00000001 KAS');assert.equal(movement({inputs:[{previous_outpoint_address:'A',previous_outpoint_amount:'200000000'}],outputs:[{script_public_key_address:'A',amount:'99999999'},{script_public_key_address:'B',amount:'100000000'}]},'A'),-100000001n)});
test('unresolved inputs do not fabricate an incoming amount; zero is explicit',()=>{assert.equal(movement({inputs:[{}],outputs:[{script_public_key_address:'A',amount:100}]},'A'),null);assert.equal(movement({inputs:[],outputs:[{script_public_key_address:'A',amount:100}]},'B'),0n);assert.equal(rawAmount(null),null);assert.equal(kas(null),'Unavailable')});
