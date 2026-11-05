// Independent, fixed TN10 nodes only. Never accept a DEX-provided node URL.
// Each read has its own connection so a half-open shared socket cannot retain
// every unsigned-planner slot indefinitely. Mainnet uses its existing own node.
// The official Rusty-Kaspa resolvers currently publish vector-10. Keep the
// previous endpoint only as a fixed fallback, not a provider-selected URL.
const HOSTS=['vector-10.kaspa.green','muon-10.kaspa.blue'];
export function createTn10UtxoReader(factory,{timeoutMs=5500,disconnectMs=300}={}){
  const quarantined=new Map();
  return async address=>{
    for(const host of HOSTS){
      if(quarantined.has(host))continue;
      const rpc=factory(`wss://${host}/kaspa/testnet-10/wrpc/borsh`);
      let settled=false,disconnected=false,retired=false,freed=false,timer;
      const cleanup=()=>{
        if(settled&&disconnected&&!freed){
          freed=true;
          try{rpc.free();}catch{/* No key material or signing exists here. */}
          const set=quarantined.get(host);set?.delete(rpc);
          if(set?.size===0)quarantined.delete(host);
        }
      };
      const check=()=>{if(retired)throw Error('TN10 read was retired.');};
      const operation=(async()=>{
        await rpc.connect({timeoutDuration:2500,strategy:'fallback'});check();
        const info=await rpc.getInfo();check();
        const dag=await rpc.getBlockDagInfo();check();
        if(!info.isSynced||!info.isUtxoIndexed||dag.network!=='testnet-10')throw Error('Independent TN10 node is not ready.');
        const result=await rpc.getUtxosByAddresses([address]);check();
        if(!Array.isArray(result.entries)||result.entries.length>10000)throw Error('Invalid TN10 output coverage.');
        return result.entries;
      })();
      operation.then(()=>{settled=true;cleanup();},()=>{settled=true;cleanup();});
      try{
        return await Promise.race([operation,new Promise((_,reject)=>{
          timer=setTimeout(()=>reject(Error('TN10 input lookup timed out.')),timeoutMs);
        })]);
      }catch{/* Retry the other fixed public node, never assume zero outputs. */}
      finally{
        clearTimeout(timer);retired=true;
        const set=quarantined.get(host)??new Set();set.add(rpc);quarantined.set(host,set);
        // Do not free a WASM handle while a request may still be in flight. If
        // cancellation itself stalls, quarantine that endpoint until cleanup
        // really completes, bounding retained handles by the server's slots.
        const disconnect=Promise.resolve().then(()=>rpc.disconnect());
        disconnect.then(()=>{disconnected=true;cleanup();},()=>{});
        let closeTimer;
        await Promise.race([disconnect.catch(()=>{}),new Promise(resolve=>{closeTimer=setTimeout(resolve,disconnectMs);})]);
        clearTimeout(closeTimer);cleanup();
      }
    }
    throw Error('Independent TN10 inputs are temporarily unavailable. Saved orders remain preserved.');
  };
}
