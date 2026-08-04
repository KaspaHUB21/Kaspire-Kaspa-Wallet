import assert from "node:assert/strict";
import test from "node:test";
import { mapKcc20Cells, normalizeKcc20Script, parseKcc20BroadcastId } from "./generated/api.mjs";

const owner="70a6797d23559f172df63438dc36cb2f9cef467978a4077ad80f129d866f143a";
const covenantId="d0d4abf9a6b197570d334ba9f730efc1ad56282fd8b8ffaf4fcedf9587a9ac22";
const templateHash="36205a78ae657a7f1db798f6c52925ca82aca7361df71ef6a8202ce05aa7ec5f";
const tx="ed45e53543a353d5d6afece718e3b40ed98292a07cac43e0e22b430ce69c361d";

test("maps current kcc20.info state.amount signing cells",()=>{
  const cells=mapKcc20Cells({cells:[{outpoint_tx_id:tx,outpoint_index:1,covenant_id:covenantId,value:23000000,script_public_key:"0000aa202faa6076c95d0e574e089d3ec52c62ff39962660b1637d5d2a535f0777396ee387",state:{owner,amount:100000000,is_minter:false},created_daa:501701964,signing_ready:true}],unmapped:[]},covenantId,owner,100000000,templateHash);
  assert.equal(cells.length,1);assert.equal(cells[0].tokenAmount,100000000);assert.equal(cells[0].transactionId,tx);assert.equal(cells[0].scriptPublicKey,"aa202faa6076c95d0e574e089d3ec52c62ff39962660b1637d5d2a535f0777396ee387");
});

test("normalizes only a version-0 encoded KCC20 P2SH script",()=>{
  const raw="aa20"+"ab".repeat(32)+"87";assert.equal(normalizeKcc20Script(`0000${raw}`),raw);assert.equal(normalizeKcc20Script(raw),raw);assert.equal(normalizeKcc20Script(`0001${raw}`),`0001${raw}`);
});

test("rejects cells for another owner and incomplete sums",()=>{
  assert.throws(()=>mapKcc20Cells({cells:[{outpoint_tx_id:tx,outpoint_index:1,covenant_id:covenantId,value:23000000,script_public_key:"0000aa20ff87",state:{owner:"f".repeat(64),amount:100000000},signing_ready:true}],unmapped:[]},covenantId,owner,100000000,templateHash),/discovery is incomplete/);
});

test("accepts the Toccata txId response used by the mobile app",()=>{
  assert.equal(parseKcc20BroadcastId({txId:tx},tx),tx);
  assert.equal(parseKcc20BroadcastId({transactionId:tx},tx),tx);
  assert.equal(parseKcc20BroadcastId({transaction_id:tx},tx),tx);
  assert.throws(()=>parseKcc20BroadcastId({txId:"f".repeat(64)},tx),/mismatching transaction ID/);
  assert.throws(()=>parseKcc20BroadcastId({},tx),/no valid transaction ID/);
});
