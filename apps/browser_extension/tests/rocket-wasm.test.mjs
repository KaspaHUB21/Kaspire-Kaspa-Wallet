import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init,* as raw from './generated/wasm/kaspa_secure_core.mjs';
import {secureCore} from './generated/secretInputs.mjs';
const exports=await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const core=secureCore(raw,exports.memory);
const request=JSON.parse(await readFile(new URL('../../../crates/kaspa_secure_core/src/fixtures/kasparocket-mainnet-buy.json',import.meta.url),'utf8'));
test('Actual packaged WASM accepts a real public unsigned Mainnet plan and binds its profile',()=>{
  const result=JSON.parse(core.preparePskt(JSON.stringify(request)));
  assert.equal(result.profile,'kasparocket-mainnet-v1');assert.equal(result.tokenId,request.tokenId);
  assert(result.walletInputSompi>0);assert(result.reviewHash);
});
for(const mutation of ['network','fees','sighash'])test(`Actual WASM rejects altered Mainnet ${mutation}`,()=>{
  const changed=structuredClone(request);
  if(mutation==='network')changed.profile='kasparocket-testnet-v1';
  if(mutation==='fees')changed.tradeSummary.partnerFeeSompi='1';
  if(mutation==='sighash')changed.signInputs[0].expectedSighash='00'.repeat(32);
  assert.throws(()=>core.preparePskt(JSON.stringify(changed)));
});
