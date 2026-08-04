import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const compact = (value) => value.replace(/\s+/g, "");

test("KRON SafeJSON is broadcast directly through the current Kaspa wRPC client", async () => {
  const source = compact(await readFile(new URL("../src/background/index.ts", import.meta.url), "utf8"));
  const start = source.indexOf('if(stored.type==="kron")');
  const branch = source.slice(start, source.indexOf('title:"Authorizeassetcommit?"', start));
  assert.match(branch, /awaitbroadcastKron\(signed,stored\.review\.transactionId\)/);
  assert.doesNotMatch(branch, /awaitbroadcastKcc20\(signed,stored\.review\.transactionId\)/);
  assert.doesNotMatch(branch, /awaitbroadcast\(signed,state\.network\)/);
});

test("KRON fee estimation does not mutate covenant transaction inputs", async () => {
  const source = compact(await readFile(new URL("../src/background/index.ts", import.meta.url), "utf8"));
  assert.match(source, /estimateKronFeeWithoutMutation\(assembled,funding\.feeRate\)/);
  assert.doesNotMatch(source, /kronSpend\.estimateNativeFee\(kaspa,"mainnet",assembled/);
});

test("KRON resolves a URL instead of crossing WASM Resolver class instances", async () => {
  const source = compact(await readFile(new URL("../src/background/index.ts", import.meta.url), "utf8"));
  assert.match(source, /resolver\.getUrl\("borsh","mainnet"\)/);
  assert.match(source, /newkaspa\.RpcClient\(\{url,encoding:"borsh"\}\)/);
  assert.doesNotMatch(source, /newkaspa\.RpcClient\(\{resolver:/);
});

test("KRON submits a plain RPC transaction instead of a WASM Transaction wrapper", async () => {
  const source = compact(await readFile(new URL("../src/background/index.ts", import.meta.url), "utf8"));
  assert.match(source, /submitTransaction\(\{transaction:rpcTransaction,allowOrphan:false,?\}\)/);
  assert.doesNotMatch(source, /submitTransaction\(\{transaction,allowOrphan:false,?\}\)/);
});
