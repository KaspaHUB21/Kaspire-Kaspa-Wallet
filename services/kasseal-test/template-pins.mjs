// Reproducible native allowlist from the integrity-checked official SDK.
import * as sdk from '@kassealhq/sdk/node';
import {createHash} from 'node:crypto';
sdk.verifyArtifacts(); sdk.verifyKaspaSdk();
const network=process.argv[2];
if(!['mainnet','testnet-10'].includes(network))throw Error('Specify network');
const bases=sdk.curveBasesOf(network);
function pin(t,creator=false,token=false){
 const bytes=Buffer.from(token?sdk.tokenProgram(t,sdk.userToken(0n,new Uint8Array(32))):t.bytecode), stateOffset=token?34:t.stateOffset,stateLength=token?112:t.stateLength;
 const creatorOffsets=[];
 if(creator){
   const key=Buffer.from(t.params.creatorSpk);
   for(let start=stateOffset+stateLength;;){const i=bytes.indexOf(key,start);if(i<0)break;creatorOffsets.push(i);start=i+key.length;}
   if(creatorOffsets.length!==(sdk.hasCreatorWindow(t)?5:4))throw Error('Unexpected creator layout');
   for(const i of creatorOffsets)bytes.fill(0,i,i+36);
 }
 bytes.fill(0,stateOffset,stateOffset+stateLength);
 return {length:bytes.length,stateOffset,stateLength,creatorOffsets,...(creator?{creatorWindow:sdk.hasCreatorWindow(t)}:{}),sha256:createHash('sha256').update(bytes).digest('hex')};
}
console.log(JSON.stringify({source:'@kassealhq/sdk@0.3.0',sdk:'0.3.0',network,
 curves:bases.map(b=>pin(b.curve,true)),pool:pin(bases[0].pool),token:pin(bases[0].token,false,true)},null,2));
