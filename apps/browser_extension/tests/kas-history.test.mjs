import test from 'node:test';
import assert from 'node:assert/strict';
import {walletHistory, walletHistoryForAddresses} from './generated/api.mjs';

const own='kaspa:wallet-fixture', rotated='kaspa:rotated-fixture', pool='kaspa:pool-fixture', other='kaspa:recipient-fixture';
const input=(address, amount, covenant='')=>({previous_outpoint_address:address,previous_outpoint_amount:String(amount),covenant_id:covenant});
const output=(address, amount, covenant='')=>({script_public_key_address:address,amount:String(amount),covenant_id:covenant});
const tx=(inputs,outputs)=>({transaction_id:'a'.repeat(64),block_time:1792024147269,is_accepted:true,inputs,outputs});
async function read(t, row, addresses=[own]) {
  const previous=globalThis.fetch;
  globalThis.fetch=async()=>new Response(JSON.stringify([row]),{status:200});
  t.after(()=>{globalThis.fetch=previous;});
  const single=await walletHistory(own,'mainnet');
  const account=await walletHistoryForAddresses(addresses,'mainnet');
  assert.equal(account.length,1,'one transaction even if returned for multiple receive addresses');
  if(addresses.length===1)assert.deepEqual(single,account,'single and account paths use the same calculation');
  return account[0];
}
const buy=()=>tx([
  input(pool,50760024000000n,'pool-covenant'),input('kaspa:token',50000000,'token-covenant'),input(own,8362180460120n),
],[
  output(pool,50760824000000n,'pool-covenant'),output('kaspa:token',50000000,'token-covenant'),output('kaspa:token-change',50000000,'token-covenant'),
  output('kaspa:fee1',20000000),output('kaspa:fee2',20000000),output(own,8361253140120n),
]);
test('reported KRON buy shows 9.2732 KAS wallet debit, never 507609.64 KAS pool outputs',async t=>{
  const row=await read(t,buy());
  assert.equal(row.amountSompi,927320000); assert.equal(row.displayAmount,'9.2732');
  assert.equal(row.incoming,false);assert.equal(row.amountIsWalletChange,true);
  assert.equal(row.walletBalanceChangeSompi,-927320000);assert.equal(row.feeSompi,37320000);
  assert.equal(row.walletInputSompi,8362180460120);assert.equal(row.walletOutputSompi,8361253140120);
  assert.equal(row.totalInputSompi,59122254460120);assert.equal(row.totalOutputSompi,59122217140120);
  assert.equal(row.from[0].amountSompi,50760024000000);assert.equal(row.to[0].amountSompi,50760824000000);
  assert.equal(row.from[2].isWallet,true);assert.equal(row.from[0].isWallet,false);assert.equal(row.counterparty,'');
});
test('KRON sale with wallet-funded inputs is Received and shows net credit',async t=>{
  const row=await read(t,tx([input(pool,50762000000000n,'pool'),input(own,8361078980120n)],[output(pool,50760824000000n,'pool'),output(own,8362180460120n)]));
  assert.equal(row.incoming,true);assert.equal(row.amountSompi,1101480000);assert.equal(row.displayAmount,'11.0148');
});
test('swap aggregates funding and change across rotated addresses',async t=>{
  const row=buy();row.inputs.push(input(rotated,100000000));row.outputs.at(-1).script_public_key_address=rotated;
  row.outputs.at(-1).amount=String(BigInt(row.outputs.at(-1).amount)+100000000n);
  const result=await read(t,row,[own,rotated,own.toUpperCase()]);
  assert.equal(result.amountSompi,927320000);assert.equal(result.walletBalanceChangeSompi,-927320000);
});
test('ordinary KAS send keeps amount excluding separately shown fee',async t=>{
  const row=await read(t,tx([input(own,1000000000)],[output(other,100000000),output(own,899990000)]));
  assert.equal(row.amountSompi,100000000);assert.equal(row.feeSompi,10000);assert.equal(row.amountIsWalletChange,false);
  assert.equal(row.walletBalanceChangeSompi,-100010000);assert.equal(row.counterparty,other);
});
test('ordinary incoming transfer reports only wallet outputs',async t=>{
  const row=await read(t,tx([input(other,200000000)],[output(own,100000000),output(other,99990000)]));
  assert.equal(row.amountSompi,100000000);assert.equal(row.incoming,true);assert.equal(row.counterparty,other);
});
test('HD self-transfer is not reported as a payment to the rotated address',async t=>{
  const row=await read(t,tx([input(own,1000000000)],[output(rotated,999990000)]),[own,rotated]);
  assert.equal(row.amountSompi,0);assert.equal(row.selfTransfer,true);assert.equal(row.walletBalanceChangeSompi,-10000);
});
test('multi-party fee is not subtracted from or added again to the wallet delta',async t=>{
  const row=await read(t,tx([input(own,1000000000),input(other,500000000)],[output(own,800000000),output(other,600000000)]));
  assert.equal(row.amountSompi,200000000);assert.equal(row.feeSompi,100000000);assert.equal(row.amountIsWalletChange,true);
});
test('input/output ordering cannot change the wallet amount',async t=>{
  const row=buy();row.inputs.reverse();row.outputs.reverse();
  assert.equal((await read(t,row)).amountSompi,927320000);
});
test('very large pool amounts preserve exact integer totals',async t=>{
  const row=await read(t,tx([input(pool,900719925474099300n,'pool'),input(own,1000000000)],[output(pool,900719926474099299n,'pool')]));
  assert.equal(row.amountSompi,1000000000);assert.equal(row.feeSompi,1);
  assert.equal(row.totalInputSompi,'900719926474099300');
});
test('coinbase receipt has no negative synthetic fee',async t=>{
  const row=await read(t,tx([],[output(own,100000000)]));
  assert.equal(row.amountSompi,100000000);assert.equal(row.isCoinbase,true);assert.equal(row.feeSompi,0);
});
test('unresolved external address is not dropped before multi-party calculation',async t=>{
  const row=await read(t,tx([input(own,1000000000),input('',500000000)],[output(own,800000000),output(other,600000000)]));
  assert.equal(row.hasExternalInputs,true);assert.equal(row.amountSompi,200000000);assert.equal(row.from.length,2);
});
