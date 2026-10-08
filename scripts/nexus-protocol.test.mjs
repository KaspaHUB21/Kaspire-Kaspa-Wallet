import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validateOffer,createNexusToken,readNexusToken} from './nexus-protocol.mjs';
test('offer duration and non-binding acknowledgement are enforced',()=>{
  const offer={collectionId:'KASGOTHS',tokenId:'12',amountKas:'1.25',durationDays:30,acknowledgedNonBinding:true};
  assert.equal(validateOffer(offer).durationDays,30);
  assert.equal(validateOffer({...offer,durationDays:60}).durationDays,60);
  for(const patch of [{durationDays:3},{acknowledgedNonBinding:false},{amountKas:'0'},{amountKas:'1e3'},{tokenId:'../secret'}])assert.throws(()=>validateOffer({...offer,...patch}));
});
test('native sessions are authenticated, time-limited and purpose separated',()=>{
  const secret='test-only-session-secret-32-characters',address='kaspa:'+'a'.repeat(61),token=createNexusToken(address,secret,100);
  assert.equal(readNexusToken(token,secret,101),address);
  assert.equal(readNexusToken(token,secret,99),null);
  assert.equal(readNexusToken(token,secret,100+7*86400000),null);
  assert.equal(readNexusToken(token,secret+'x',101),null);
  assert.equal(readNexusToken(token+'x',secret,101),null);
});
