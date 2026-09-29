import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const background = await readFile(new URL("../src/background/index.ts", import.meta.url), "utf8");
const api = await readFile(new URL("../src/background/api.ts", import.meta.url), "utf8");
const state = await readFile(new URL("../src/background/state.ts", import.meta.url), "utf8");

test("rotated receive addresses aggregate KAS while single wallets retain the legacy signer path", () => {
  assert.match(background, /function kasAccountEntries/);
  assert.match(background, /return entries\.length < 2 \? \[\]/);
  assert.match(background, /spendingDataForAddresses\(account\.map/);
  assert.match(background, /return signers\.length \? wallet\.secret : signingSecret/);
  assert.match(background, /receiveRotation: true/);
  assert.match(state, /receiveRotation\?: boolean/);
});

test("protected KRC20 fallback is accessed only through the credential-free Kaspire gateway", () => {
  assert.match(api, /https:\/\/kaspire\.kaslab\.space\/api\/krc20-fallback/);
  assert.doesNotMatch(api + background, /authorization\s*:/i);
  assert.doesNotMatch(api + background, /basic\s+[a-z0-9+/=]+/i);
});
