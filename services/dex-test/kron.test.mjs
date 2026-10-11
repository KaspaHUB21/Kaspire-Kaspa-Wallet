import {test} from 'node:test';
import assert from 'node:assert/strict';
import {quoteFor,REF} from './kron.mjs';
test('partner ref is fixed',()=>assert.equal(REF,'kaspirewallet'));
test('reject invalid sides and precision before curve calculations',()=>{
  for(const[side,value]of[['buy','0'],['buy','1'],['sell','-1'],['other','100000000'],['sell','1.2']])assert.throws(()=>quoteFor({}, {}, side,value));
});
