// Independent TN10 state, never Kasseal's transaction history or provider hints.
import {sdk} from '@kassealhq/sdk/node';
import {NETWORK, PREFIX} from './network.mjs';
let connecting;
export function normalizeEntry(u) {
  const entry=u.entry;
  return {outpoint:{transactionId:u.outpoint.transactionId,index:u.outpoint.index},utxoEntry:{
    amount:String(u.amount),scriptPublicKey:{version:u.scriptPublicKey.version,script:u.scriptPublicKey.script},
    blockDaaScore:String(u.blockDaaScore),isCoinbase:u.isCoinbase,
    covenantId:entry.covenantId == null ? null : String(entry.covenantId)}};
}
export function checkAddress(address) {
  if(typeof address!=='string'||!new RegExp('^'+PREFIX+'[a-z0-9]{61,120}$').test(address)) throw Error(`A valid ${NETWORK} address is required.`);
  new (sdk().Address)(address).free();
}
async function node() {
  if(!connecting) connecting=(async()=>{
    const k=sdk(),rpc=new k.RpcClient({url:NETWORK==='mainnet'?'ws://172.30.0.1:17110':'wss://muon-10.kaspa.blue/kaspa/testnet-10/wrpc/borsh',
      encoding:k.Encoding.Borsh,networkId:NETWORK});
    try {
      await rpc.connect({timeoutDuration:10000,strategy:'fallback'});
      const info=await rpc.getInfo(),dag=await rpc.getBlockDagInfo();
      if(!info.isSynced||!info.isUtxoIndexed||dag.network!==NETWORK) throw Error(`Independent ${NETWORK} node is not ready.`);
      return {rpc,active:0,retired:false};
    } catch(e) {await rpc.disconnect();rpc.free();throw e;}
  })().catch(e=>{connecting=null;throw e;});
  return connecting;
}
export async function utxos(address) {
  checkAddress(address);
  const connection=await node(),{rpc}=connection;
  connection.active++;
  try {
    const info=await rpc.getInfo();
    if(!info.isSynced||!info.isUtxoIndexed) throw Error('Independent TN10 node is not ready.');
    const {entries}=await rpc.getUtxosByAddresses([address]);
    if(entries.length>10000) throw Error('Too many TN10 outputs to verify in one request.');
    return {network:NETWORK,covenantIdsIncluded:true,entries:entries.map(normalizeEntry)};
  } catch(e) {
    if(!connection.retired){connection.retired=true;connecting=null;}
    throw e;
  } finally {
    connection.active--;
    if(connection.retired&&connection.active===0){await rpc.disconnect();rpc.free();}
  }
}
