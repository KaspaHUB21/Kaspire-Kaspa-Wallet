import {test} from 'node:test';
import assert from 'node:assert/strict';
import {runKcc20PaymentPlan} from './generated/kcc20Plan.mjs';
const fixture=()=>({sender:'wallet-A',operation:{},reviewHash:'ab'.repeat(32),totalFeeSompi:30,
  nextStep:0,createdAt:1,transactions:Array.from({length:3},(_,i)=>({transactionId:String(i+1).repeat(64),signedTxJson:'exact-'+i,feeSompi:10,operation:{}}))});
test('saves all approved bytes before sending, waits for accepted parents and checkpoints each step',async()=>{
  const plan=fixture(),events=[],confirmed=new Set();let saved;
  const result=await runKcc20PaymentPlan(plan,'wallet-A',{
    save:async value=>{saved=structuredClone(value);events.push('save:'+value.nextStep);},
    accepted:async id=>confirmed.has(id),broadcast:async(bytes,id)=>{
      assert.equal(saved.transactions.length,3);assert.equal(bytes,saved.transactions[saved.nextStep].signedTxJson);
      if(saved.nextStep)assert.ok(confirmed.has(plan.transactions[saved.nextStep-1].transactionId));
      events.push('send:'+saved.nextStep);confirmed.add(id);
    },record:async()=>{},check:async()=>{},pause:async()=>{},
  });
  assert.equal(result.transactionId,plan.transactions[2].transactionId);
  assert.deepEqual(events,['save:0','send:0','save:1','send:1','save:2','send:2','save:3']);
});
test('ambiguous broadcast survives restart and never replaces or repeats an accepted payment',async()=>{
  let saved;const confirmed=new Set(),broadcasts=[];
  const io={save:async p=>{saved=structuredClone(p);},accepted:async id=>confirmed.has(id),
    record:async()=>{},check:async()=>{},pause:async()=>{},
    broadcast:async(bytes,id)=>{broadcasts.push(bytes);if(bytes==='exact-1')throw Error('offline');confirmed.add(id);}};
  await assert.rejects(runKcc20PaymentPlan(fixture(),'wallet-A',io),/saved at transaction 2/);
  assert.equal(saved.nextStep,1);
  // Transaction 2 actually reached the node despite the connection failure.
  confirmed.add(saved.transactions[1].transactionId);
  await runKcc20PaymentPlan(structuredClone(saved),'wallet-A',{...io,broadcast:async(bytes,id)=>{broadcasts.push(bytes);confirmed.add(id);}});
  assert.deepEqual(broadcasts,['exact-0','exact-1','exact-2']);
  assert.equal(saved.nextStep,3);
});
test('storage failure, changed wallet and cancellation never send another step',async()=>{
  let sends=0;
  const io={save:async()=>{},accepted:async()=>false,broadcast:async()=>{sends++;},record:async()=>{},check:async()=>{},pause:async()=>{}};
  await assert.rejects(runKcc20PaymentPlan(fixture(),'wallet-B',io),/different wallet/);
  await assert.rejects(runKcc20PaymentPlan(fixture(),'wallet-A',{...io,save:async()=>{throw Error('disk full');}}),/disk full/);
  await assert.rejects(runKcc20PaymentPlan(fixture(),'wallet-A',{...io,check:async()=>{throw Error('account closed');}}),/account closed/);
  assert.equal(sends,0);
});
