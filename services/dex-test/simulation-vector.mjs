// Emits a synthetic signed-core test vector, never submits a transaction.
// The known test key controls a fabricated funding script, NOT the chain UTXO.
import {loadKaspa} from '@kronsdk/kron-sdk/wasm';
import {plan} from './kron.mjs';
const token=process.argv[2]??'7a98370c0d6b037c28089d7b77cd8229120804cb416ef592ddb99e23820544e4';
const side=process.argv[3]??'buy';
const oldAddress=side==='sell'?(token==='7a98370c0d6b037c28089d7b77cd8229120804cb416ef592ddb99e23820544e4'?'kaspa:qz5enng5vzgpe4jk9avc2eznuyxkqtsx49hstsrvczm4j36sr0k5ykzjmdvdr':'kaspa:qrtfmlgmpa4k7el9xmuu9m477h24y24gpwxfhpg40rdxpmeuqy6ecfjxwudq4'):'kaspa:qz88qqxmjf5u4gghhervj64kyk24pkpegjjs0hw8fsgtckq7fupwcycu9zw7t';
const k=await loadKaspa(),key=new k.PrivateKey('11'.repeat(32)),address=key.toKeypair().toAddress('mainnet').toString();
const oldPub=k.payToAddressScript(new k.Address(oldAddress)).script.slice(2,-2),newSpk=k.payToAddressScript(new k.Address(address)).script,newPub=newSpk.slice(2,-2);
const {request}=await plan({tokenId:token,address:oldAddress,side,rawAmount:side==='buy'?'100000000':'1000',minimumReceive:'1'});
const tx=JSON.parse(request.txJsonString);delete tx.id;
// Preserve the market's immutable redeem program (the fixture seller may
// also be the creator, whose fee key must NOT change with synthetic ownership).
function lastPushStart(script){let last=0;for(let i=0;i<script.length;){const start=i,op=script[i++];let n=op<=75?op:0;if(op===76)n=script[i++];else if(op===77){n=script[i]|script[i+1]<<8;i+=2;}else if(op===78){n=script.readUInt32LE(i);i+=4;}if(n){last=start;i+=n;}}return last*2;}
for(const [i,input] of tx.inputs.entries()){
  if(i===0){const split=lastPushStart(Buffer.from(input.signatureScript,'hex'));input.signatureScript=input.signatureScript.slice(0,split).replaceAll(oldPub,newPub)+input.signatureScript.slice(split);}
  else input.signatureScript=input.signatureScript.replaceAll(oldPub,newPub);
  if(input.utxo.scriptPublicKey==='000020'+oldPub+'ac')input.utxo.scriptPublicKey='0000'+newSpk;
}
const terms=request.tradeSummary;
for(const row of terms.traderInputs){row.redeem=row.redeem.replaceAll(oldPub,newPub);tx.inputs[row.index].utxo.scriptPublicKey='0000'+k.payToScriptHashScript(Uint8Array.from(Buffer.from(row.redeem,'hex'))).script;}
terms.traderOutputRedeem=terms.traderOutputRedeem.replaceAll(oldPub,newPub);
const recipient=k.payToScriptHashScript(Uint8Array.from(Buffer.from(terms.traderOutputRedeem,'hex'))).script;
for(const role of terms.outputRoles)if(['trader','recipient','seller'].includes(role.role)){role.script=recipient;tx.outputs[role.index].scriptPublicKey='0000'+recipient;}
tx.outputs.at(-1).scriptPublicKey='0000'+newSpk;
request.sender=address;request.txJsonString=JSON.stringify(tx);
await new Promise(resolve=>process.stdout.write(JSON.stringify(request),resolve));
process.exit(0);
