import {walletHistoryForAddresses,krc20History,kronHistory,inscriptionHistory,kcc20History,standardWalletHistory} from './api';
import type {KaspaNetwork} from '../shared/protocol';
import type {ActivityResult} from '../shared/activityFeed';

const native=new Map<string,{at:number;task:Promise<ActivityResult>}>();
function accountHistory(addresses:string[],network:KaspaNetwork,limit:number) {
  const key=JSON.stringify([network,[...addresses].sort(),limit]);
  const cached=native.get(key);
  if(cached&&Date.now()-cached.at<15000)return cached.task;
  const warnings:string[]=[];
  const task=walletHistoryForAddresses(addresses,network,limit,w=>warnings.push(w))
    .then(items=>({items,warnings})).catch(error=>{native.delete(key);throw error;});
  if(native.size>32)native.clear();
  native.set(key,{at:Date.now(),task});
  return task;
}
export async function activitySource(address:string,network:KaspaNetwork,addresses:string[],source:string,limit:number):Promise<ActivityResult> {
  if(!Number.isInteger(limit)||limit<1||limit>1000)throw Error('Invalid history limit.');
  if(source==='KAS history')return accountHistory(addresses,network,limit);
  if(network!=='mainnet')return {items:[]};
  if(source==='KRC20 history')return {items:await krc20History(address,limit)};
  if(source==='KRON history')return kronHistory(address,limit);
  if(source==='NFT/name history')return {items:await inscriptionHistory(address,limit)};
  if(source==='Legacy covenant history')return {items:(await kcc20History(address)).slice(0,limit)};
  if(source==='Covenant history') {
    const node=await accountHistory(addresses,network,limit);
    const result=await standardWalletHistory(address,node.items,limit);
    return {items:result.items,warnings:[...(node.warnings??[]),...result.warnings]};
  }
  throw Error('Unknown activity source.');
}
