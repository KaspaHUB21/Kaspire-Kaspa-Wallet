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

test('covenant vaults are internal-only, lock-bound and background polling does not extend timed unlock', () => {
  assert.match(background, /sender\.url !== chrome\.runtime\.getURL\('wallet\.html'\)/);
  assert.match(background, /port\.sender\?\.url !== chrome\.runtime\.getURL\('wallet\.html'\)/);
  assert.match(background, /clearCovenantVaultReviews\(\)/);
  assert.match(background, /'covenantVaultSaved', 'covenantVaultRefresh', 'covenantVaultDaa'\]\.includes\(message\.command\)/);
  const commands=background.slice(background.indexOf("if (String(message.command).startsWith('covenantVault'))"),background.indexOf("if (String(message.command).startsWith('kronDex'))"));
  assert.match(commands,/generation !== sessionGeneration/);
  assert.match(commands,/revision !== nftContextRevision/);
  assert.match(commands,/selected\.path !== entry\.path/);
  assert.match(commands,/const wasm = await core\(\); await guard\(\);/);
});

test('P2SH is wallet-UI-only, uses the root seed, binds session/account/network and stores its journal inside the encrypted vault', () => {
  assert.match(background, /startsWith\('p2sh'\).*sender\.url !== chrome\.runtime\.getURL\('wallet\.html'\)/);
  assert.match(background, /startsWith\('p2sh'\).*port\.sender\?\.url !== chrome\.runtime\.getURL\('wallet\.html'\)/);
  const commands=background.slice(background.indexOf("if (String(message.command).startsWith('p2sh'))"),background.indexOf("if (String(message.command).startsWith('covenantVault'))"));
  assert.match(commands,/generation !== sessionGeneration/); assert.match(commands,/revision !== nftContextRevision/);
  assert.match(commands,/fresh\.network !== 'mainnet'/);assert.match(commands,/selected\.path !== entry\.path/);
  assert.match(commands,/wallet\.type !== 'mnemonic'/);assert.match(commands,/signHiddenKas\(wallet\.secret/);
  assert.match(commands,/wallet\.hiddenKas = validateP2shState\(next\)/);assert.match(commands,/await persistVault\(guard\)/);
  assert.match(background,/hiddenKas: validateP2shState\(wallet\.hiddenKas\)/);
  assert.match(background,/verifyHiddenKasRecovery\(wallet\.secret, JSON\.stringify\(recovered\.pending\)\)/);
  assert.match(background,/clearP2shReviews\(\)/);
});
