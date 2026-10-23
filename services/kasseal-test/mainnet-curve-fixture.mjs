// Public deterministic key 1, synthetic funding, NEVER broadcast.
import * as sdk from '@kassealhq/sdk/node';
import {calculate,plan,NETWORK} from './planner.mjs';
if(NETWORK!=='mainnet')throw Error('Run with KASPIRE_KASSEAL_NETWORK=mainnet');
const k=sdk.sdk(),address=new k.PrivateKey('1'.padStart(64,'0')).toAddress(NETWORK).toString();
const body={network:NETWORK,address,tokenId:process.argv[2],side:'buy',rawAmount:'100000000'};
const ctx=await calculate(body);
body.minimumReceive=String(BigInt(ctx.quote.tokenAmount)*99n/100n);body.maxSpendSompi=ctx.quote.maxSpendSompi;
const built=await plan(body,{...ctx.sources,funding:async()=>[{outpoint:{txid:'aa'.repeat(32),index:0},amount:100_000_000_000n,
 spk:Buffer.from(k.payToAddressScript(new k.Address(address)).script,'hex'),daaScore:123n,address}]});
console.log(JSON.stringify(built.request,null,2));
