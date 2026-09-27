import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const background = await readFile(
  new URL("../src/background/index.ts", import.meta.url),
  "utf8",
);
const state = await readFile(
  new URL("../src/background/state.ts", import.meta.url),
  "utf8",
);
const vault = await readFile(
  new URL("../src/background/vault.ts", import.meta.url),
  "utf8",
);
const rocket = await readFile(
  new URL("../src/background/kasparocket.ts", import.meta.url),
  "utf8",
);
const volatileSession = await readFile(
  new URL("../src/offscreen/session.ts", import.meta.url),
  "utf8",
);
const manifest = JSON.parse(
  await readFile(new URL("../manifest.json", import.meta.url), "utf8"),
);

test("decrypted wallet secrets are never persisted in Chrome session storage", () => {
  assert.doesNotMatch(background, /session\.set\(\{\s*unlockedVault/s);
  assert.match(background, /session\.remove\("unlockedVault"\)/);
});

test("timed unlock uses an encrypted volatile offscreen session", () => {
  assert(manifest.permissions.includes("offscreen"));
  assert.match(volatileSession, /AES-GCM/);
  assert.match(volatileSession, /extractable|false/);
  assert.match(background, /sessionGeneration/);
  assert.match(background, /rejectApprovals/);
  assert.match(background, /unlockOnly/);
});

test("public wallet state is explicitly allow-listed and encrypted vault remains Argon2id", () => {
  assert.doesNotMatch(state, /\.\.\.walletState/);
  assert.match(state, /"wallets" in walletState/);
  assert.match(vault, /deriveBackupKey/);
  assert.match(vault, /AES-GCM/);
});

test("KaspaRocket provider IDs cannot replace the locally computed consensus ID", () => {
  assert.match(rocket, /delete normalized\.id/);

});
