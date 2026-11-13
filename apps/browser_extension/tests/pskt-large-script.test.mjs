import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init,* as raw from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
import initKaspa,{payToScriptHashScript} from '../node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa.js';
import {feeHolderUnwrap} from './fixtures/kaspacom-fee-holder-unwrap.mjs';
await initKaspa({module_or_path:await readFile('node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa_bg.wasm')});
const exports=await init({module_or_path:await readFile('tests/generated/wasm/kaspa_secure_core_bg.wasm')});
const core=secureCore(raw,exports.memory),secret='private:'+'11'.repeat(32);
const sender=JSON.parse(core.importPrivateKey('11'.repeat(32))).address,owner=core.publicKey(secret);
const fixture=scriptBytes=>feeHolderUnwrap({sender,owner,scriptBytes,scriptPublicKey:redeem=>{const spk=payToScriptHashScript(redeem),value=spk.script;spk.free();return value;}});
test('new WASM reviews and signs the 56,899-byte fee-holder unwrap size fixture without changing its transaction',()=>{
  const f=fixture();assert.equal(f.redeem.length/2,56899);
  const prepared=JSON.parse(core.preparePskt(JSON.stringify(f.native)));
  assert.equal(prepared.selectedInputCount,1);assert(prepared.inputs[0].scriptAware);
  const signed=JSON.parse(core.signPskt(secret,JSON.stringify(f.native),prepared.reviewHash));
  const tx=JSON.parse(signed.signedTxJson),original=JSON.parse(f.native.txJsonString);
  assert(tx.inputs[0].signatureScript.endsWith(f.redeem));
  tx.inputs[0].signatureScript='';assert.deepEqual(tx,original);
  assert.throws(()=>core.signPskt(secret,JSON.stringify(f.native),'00'.repeat(32)),/review/i);
});
test('WASM per-script bound accepts 64 KiB and rejects the next byte; aggregate and encoding bounds remain',()=>{
  assert.doesNotThrow(()=>core.preparePskt(JSON.stringify(fixture(65536).native)));
  assert.throws(()=>core.preparePskt(JSON.stringify(fixture(65537).native)),/covenant script size.*65536/);
  const f=fixture().native;
  f.scripts[0].scriptHex='zz';assert.throws(()=>core.preparePskt(JSON.stringify(f)),/script encoding/);
  const aggregate=fixture().native;aggregate.scripts=Array(3).fill(aggregate.scripts[0]);
  assert.throws(()=>core.preparePskt(JSON.stringify(aggregate)),/script request exceeds size limit/);
});
test('preparePskt and signPskt retain strict original schema diagnostics',()=>{
  for(const malformed of [
    {...fixture().native,unknownIntegrationField:true},
    {...fixture().native,scripts:[{inputIndex:0,scriptHex:'51',unknownScriptField:1}]},
    {...fixture().native,signInputs:[{index:'zero'}]},
  ])for(const call of [r=>core.preparePskt(r),r=>core.signPskt(secret,r,'00'.repeat(32))]){
    assert.throws(()=>call(JSON.stringify(malformed)),/invalid PSKT request:.*(unknown field|invalid type).*line 1 column/);
  }
});
