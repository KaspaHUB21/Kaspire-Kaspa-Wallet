import {test} from 'node:test';
import assert from 'node:assert/strict';
import {operationDeadline} from './generated/operationDeadline.mjs';
function fakeClock() {
  let now=0,id=0;const timers=new Map();
  const clock={now:()=>now,set:(f,ms)=>{timers.set(++id,{f,due:now+ms});return id;},clear:i=>timers.delete(i)};
  const advance=ms=>{const until=now+ms;while(true){const next=[...timers].sort((a,b)=>a[1].due-b[1].due)[0];if(!next||next[1].due>until)break;now=next[1].due;timers.delete(next[0]);next[1].f();}now=until;};
  return {clock,advance,timers};
}
test('KCC20 progress survives 45 seconds, renews idle time, but never the five-minute hard cap',()=>{
  const {clock,advance}=fakeClock();let expired=0;
  const d=operationDeadline(()=>expired++,90000,300000,clock);
  advance(60000);assert.equal(expired,0);d.progress();
  advance(60000);assert.equal(expired,0);d.progress();
  advance(60000);d.progress();advance(60000);d.progress();
  advance(59999);assert.equal(expired,0);advance(1);assert.equal(expired,1);
  d.progress();advance(300000);assert.equal(expired,1);
});
test('stalled preparations time out and closing cancels their timers',()=>{
  const a=fakeClock();let expired=0;
  operationDeadline(()=>expired++,90000,300000,a.clock);a.advance(90000);assert.equal(expired,1);
  const b=fakeClock(),d=operationDeadline(()=>expired++,90000,300000,b.clock);
  d.close();b.advance(300000);assert.equal(expired,1);assert.equal(b.timers.size,0);
});
