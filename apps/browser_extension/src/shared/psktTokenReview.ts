import {formatTokenDisplay} from './tokenAmount';
/** Only structured, core-produced state proofs belong here, never dApp metadata. */
export function psktTokenDetails(review:any):string[]{
 const lines:string[]=[];
 for(const token of review.tokenReviews??[]){
  const amount=(raw:string)=>formatTokenDisplay(raw,token.decimals)+' '+token.ticker;
  lines.push(`Token: ${token.ticker} · ${token.covenantId}`);
  if(token.walletNetRaw!=null)lines.push(`Draft token balance change: ${BigInt(token.walletNetRaw)>0n?'+':''}${amount(token.walletNetRaw)}${token.outputsBound?'':' · NOT FIXED BY THIS SIGNATURE'}`);
  else lines.push('Full token balance change unavailable: some token states could not be verified. Unknown does not mean zero.');
  for(const [role,cells] of [['Input',token.inputs],['Output',token.outputs]] as const)
   for(const cell of cells??[])lines.push(`${role} ${cell.index}: ${amount(cell.amountRaw)}${cell.walletOwned?' · YOUR WALLET':''}${role==='Output'&&!cell.signatureBound?' · UNBOUND':''} · carrier reserve ${formatTokenDisplay(cell.reserveSompi,8)} KAS (not token amount)`);
  if(!token.complete)lines.push(`Undecoded token states: inputs ${(token.undecodedInputs??[]).join(', ')||'none'}; outputs ${(token.undecodedOutputs??[]).join(', ')||'none'}.`);
 }
 return lines;
}
