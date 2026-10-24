import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {SidePanelApprovals} from './generated/sidePanelApprovals.mjs';
const root='chrome-extension://fixture/';
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
function port({documentId='panel-doc',windowId=1,contextType='SIDE_PANEL',url=root+'sidepanel.html?view=00000000-0000-4000-8000-000000000001'}={}) {
  const messages=[],listeners=[],disconnects=[];
  return {name:'wallet-sidepanel-approvals',sender:{url,documentId},messages,
    onMessage:{addListener:fn=>listeners.push(fn)},onDisconnect:{addListener:fn=>disconnects.push(fn)},
    postMessage:message=>messages.push(message),receive:message=>listeners.forEach(fn=>fn(message)),close:()=>disconnects.forEach(fn=>fn()),
    context:{contextType,documentId,documentUrl:url,windowId}};
}
const view=(id='one',origin='https://dapp.example')=>({id,origin,title:'Review request',description:'Native review',details:['To: verified recipient','Fee: 0.01 KAS']});
test('only an actual verified SIDE_PANEL document can register as a presenter',async()=>{
  for(const opts of [{contextType:'TAB'},{contextType:'POPUP'},{url:root+'approval.html'},{url:'https://evil.example/sidepanel.html'}]){
    const p=port(opts),r=new SidePanelApprovals(root,async()=>[p.context]);
    assert.equal(await r.connect(p,1),false);assert.equal(p.messages.length,0);
  }
  const p=port(),r=new SidePanelApprovals(root,async filter=>{assert.deepEqual(filter.documentIds,['panel-doc']);return [p.context];});
  assert.equal(await r.connect(p,1),true);assert.equal(p.messages[0].kind,'ready');
});
test('a matching browser window receives the original review and only an explicit matching decision resolves it',async()=>{
  const p=port(),r=new SidePanelApprovals(root,async()=>[p.context]),decisions=[];await r.connect(p,1);
  await r.inRequestWindow('https://dapp.example',1,async()=>{
    const approval=view();assert.equal(r.present(approval,value=>{decisions.push(value);}),true);
    assert.deepEqual(p.messages.at(-1),{kind:'approval',view:approval});
    p.receive({kind:'decision',id:'wrong',approved:true});assert.deepEqual(decisions,[]);
    p.receive({kind:'decision',id:'one',approved:true});await tick();assert.deepEqual(decisions,[true]);
    p.receive({kind:'decision',id:'one',approved:true});assert.deepEqual(decisions,[true]);
  });
});
test('requests from other windows and unknown callers retain the popup fallback',async()=>{
  const p=port(),r=new SidePanelApprovals(root,async()=>[p.context]);await r.connect(p,1);
  assert.equal(r.present(view(),()=>{}),false);
  for(const windowId of [2,undefined])await r.inRequestWindow('https://dapp.example',windowId,async()=>assert.equal(r.present(view(),()=>{}),false));
  assert.equal(p.messages.filter(m=>m.kind==='approval').length,0);
});
test('simultaneous origins queue in one panel and rejection is never approval',async()=>{
  const p=port(),r=new SidePanelApprovals(root,async()=>[p.context]),decisions=[];await r.connect(p,1);
  let release;const done=new Promise(resolve=>{release=resolve;});
  const a=r.inRequestWindow('https://a.example',1,async()=>{r.present(view('a','https://a.example'),v=>decisions.push(['a',v]));await done;});
  const b=r.inRequestWindow('https://b.example',1,async()=>{r.present(view('b','https://b.example'),v=>decisions.push(['b',v]));await done;});
  assert.deepEqual(p.messages.filter(m=>m.kind==='approval').map(m=>m.view.id),['a']);
  p.receive({kind:'decision',id:'b',approved:true});assert.deepEqual(decisions,[]);
  p.receive({kind:'decision',id:'a',approved:false});await tick();
  assert.deepEqual(p.messages.filter(m=>m.kind==='approval').map(m=>m.view.id),['a','b']);
  p.receive({kind:'decision',id:'b',approved:true});await tick();
  assert.deepEqual(decisions,[['a',false],['b',true]]);release();await Promise.all([a,b]);
});
test('closing a panel rejects both visible and queued requests instead of creating duplicate windows',async()=>{
  const p=port(),r=new SidePanelApprovals(root,async()=>[p.context]),decisions=[];await r.connect(p,1);
  await r.inRequestWindow('https://dapp.example',1,async()=>{
    r.present(view('one'),v=>decisions.push(v));r.present(view('two'),v=>decisions.push(v));p.close();await tick();
    assert.deepEqual(decisions,[false,false]);assert.equal(r.present(view('three'),()=>{}),false);
  });
});
test('native timeout or session lock cancels the exact displayed request',async()=>{
  const p=port(),r=new SidePanelApprovals(root,async()=>[p.context]),decisions=[];await r.connect(p,1);
  await r.inRequestWindow('https://dapp.example',1,async()=>{
    r.present(view(),v=>decisions.push(v));r.cancel('one');
    assert.deepEqual(p.messages.at(-1),{kind:'cancel',id:'one'});
    p.receive({kind:'decision',id:'one',approved:true});await tick();assert.deepEqual(decisions,[]);
  });
});
test('registration that finishes after page close does not resurrect a presenter',async()=>{
  let release;const p=port(),r=new SidePanelApprovals(root,()=>new Promise(resolve=>{release=resolve;}));
  const connected=r.connect(p,1);p.close();release([p.context]);assert.equal(await connected,false);
});
test('Chrome without sender document/window IDs still binds an exact unique SIDE_PANEL document',async()=>{
  const p=port({windowId:-1});delete p.sender.documentId;
  const r=new SidePanelApprovals(root,async filter=>{assert.deepEqual(filter.documentUrls,[p.sender.url]);return [p.context];},async id=>id===1);
  assert.equal(await r.connect(p,1),true);
  const duplicate=port({windowId:-1});delete duplicate.sender.documentId;
  const ambiguous=new SidePanelApprovals(root,async()=>[duplicate.context,{...duplicate.context,contextType:'TAB'}]);
  assert.equal(await ambiguous.connect(duplicate,1),false);
});
test('presentation never sends heartbeats or updates wallet activity / lock preferences',async()=>{
  const client=await readFile(new URL('../src/ui/sidePanelApprovals.ts',import.meta.url),'utf8');
  const router=await readFile(new URL('../src/background/sidePanelApprovals.ts',import.meta.url),'utf8');
  assert.doesNotMatch(client,/setInterval|touchSession|autoLockMinutes|lastActivity/);
  assert.doesNotMatch(router,/touchSession|autoLockMinutes|lastActivity|storage\./);
});
