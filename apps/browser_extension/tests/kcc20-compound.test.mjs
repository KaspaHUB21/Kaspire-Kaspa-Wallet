import {test} from 'node:test';
import assert from 'node:assert/strict';
import {planKcc20Step,kcc20TransactionCount} from './generated/kcc20Compound.mjs';
const cells=(amounts)=>amounts.map((tokenAmount,index)=>({tokenAmount,index:0,transactionId:index.toString(16).padStart(64,'0')}));
test('ten-input program only compounds above ten, with accurate transaction counts',()=>{
  for(const [n,count] of [[1,1],[3,1],[7,1],[10,1],[11,2],[19,2],[20,3]]){
    const p=planKcc20Step(cells(Array(n).fill(10)),n*10,10);
    assert.equal(p.compound,n>10);assert.equal(p.transactionCount,count);
    assert.equal(p.cells.length,Math.min(n,10));
  }
});
test('picks largest cells, not the first three small outputs',()=>{
  const plan=planKcc20Step(cells([1,1,1,90,1]),85,3);
  assert.equal(plan.compound,false);assert.equal(plan.cells.length,1);assert.equal(plan.amount,85);
});
test('fragmented balance becomes a full self-compound, not a partial payment',()=>{
  const plan=planKcc20Step(cells([10,10,10,10]),40,3);
  assert.equal(plan.compound,true);assert.equal(plan.amount,30);assert.equal(plan.cells.length,3);
});
test('three-input contract planning exposes the real total transaction count, not token quantity',()=>{
  for(const [cells,count] of [[1,1],[2,1],[3,1],[4,2],[5,2],[6,3],[1000,500],[2001,1000]])assert.equal(kcc20TransactionCount(cells),count);
  assert.equal(planKcc20Step(cells([21000000]),21000000,3).transactionCount,1);
  const plan=planKcc20Step(cells(Array(1000).fill(1)),1000,3);
  assert.equal(plan.requiredCells,1000);assert.equal(plan.transactionCount,500);
  assert.throws(()=>kcc20TransactionCount(0));
});
test('iterated compound converges, preserving every token and bounded input count',()=>{
  for(const limit of [2,3]) {
    let rows=cells(Array(25).fill(10)), steps=0;
    while(true) {
      const plan=planKcc20Step(rows,249,limit);
      assert.ok(plan.cells.length<=limit);
      if(!plan.compound){assert.equal(plan.amount,249);break;}
      rows=rows.filter(c=>!plan.cells.includes(c));
      rows.push({transactionId:(100+steps).toString(16).padStart(64,'0'),index:0,tokenAmount:plan.amount});
      assert.equal(rows.reduce((s,c)=>s+c.tokenAmount,0),250);
      assert.ok(++steps<25);
    }
  }
});
test('refuses duplicates, overflow and insufficient balance',()=>{
  const row=cells([1])[0];
  assert.throws(()=>planKcc20Step([row,row],1,3),/duplicate/);
  assert.throws(()=>planKcc20Step(cells([Number.MAX_SAFE_INTEGER,1]),1,3),/safe/);
  assert.throws(()=>planKcc20Step(cells([1,2]),4,3),/Insufficient/);
  assert.throws(()=>planKcc20Step(cells([1]),0,3));
});
