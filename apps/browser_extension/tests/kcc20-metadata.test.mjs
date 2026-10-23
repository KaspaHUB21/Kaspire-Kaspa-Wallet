import test from 'node:test';
import assert from 'node:assert/strict';
import {verifiedKascovDeclaration} from './generated/kcc20Metadata.mjs';
const cid='82f033aed87d6eb39f509b51b1c817a49e0b07c4789b619cab08d4c8fb82d18e';
const token={covenant_id:cid,name:'brave-cobalt-urchin',kcc23:{binding:'verified',declaration:JSON.stringify({ticker:'KASPIREISTHEBESTKASPAWALLET',decimals:8})}};
test('Verified KCC23 declaration restores the actual ticker instead of an indexer alias',()=>{
 assert.equal(verifiedKascovDeclaration(cid,token).ticker,'KASPIREISTHEBESTKASPAWALLET');
 assert.equal(verifiedKascovDeclaration('a'.repeat(64),token),null);
 assert.equal(verifiedKascovDeclaration(cid,{...token,kcc23:{...token.kcc23,binding:'unverified'}}),null);
 assert.equal(verifiedKascovDeclaration(cid,{...token,kcc23:{binding:'verified',declaration:'not json'}}),null);
});
