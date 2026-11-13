// Compact, deterministic size-regression fixture. NOT KaspaCom production code.
// The large inactive branch is followed by an actual owner CHECKSIG. Native
// tests execute the signed witness in Toccata's VM, not just a mocked parser.
import {readFileSync} from 'node:fs';
export const feeHolderCase=JSON.parse(readFileSync(new URL('../../../../crates/kaspa_secure_core/src/fixtures/kaspacom-fee-holder-unwrap-regression.json',import.meta.url),'utf8'));
export function feeHolderUnwrap({sender,owner,scriptPublicKey,scriptBytes=feeHolderCase.redeemScriptBytes}) {
  if(!Number.isInteger(scriptBytes)||scriptBytes<40||scriptBytes>65575)throw Error('Invalid synthetic script size');
  const count=scriptBytes-40;
  const redeem='00634d'+(count&255).toString(16).padStart(2,'0')+(count>>8).toString(16).padStart(2,'0')+'00'.repeat(count)+'6820'+owner+'ac';
  const spk=scriptPublicKey(redeem);
  const transaction={version:1,inputs:[{transactionId:'33'.repeat(32),index:0,sequence:'0',sigOpCount:1,
    computeBudget:feeHolderCase.computeBudget,signatureScript:'',utxo:{amount:feeHolderCase.inputSompi,
      scriptPublicKey:'0000'+spk,covenantId:feeHolderCase.covenantId,blockDaaScore:'100',isCoinbase:false}}],
    outputs:[{value:feeHolderCase.releasedSompi,scriptPublicKey:'000020'+owner+'ac'}],
    subnetworkId:'00'.repeat(20),lockTime:'0',gas:'0',storageMass:'0',payload:''};
  const scripts=[{inputIndex:0,scriptHex:redeem,signType:feeHolderCase.sighashType,signatureScript:{mode:'wrap-signature',args:[]}}];
  const signInputs=[{index:0,sighashType:feeHolderCase.sighashType}];
  const native={sender,txJsonString:JSON.stringify(transaction),signInputs,scripts};
  return {native,normalized:{sender,psktTransactionJson:native.txJsonString,scripts,options:{signInputs},submitTransaction:false},redeem};
}
