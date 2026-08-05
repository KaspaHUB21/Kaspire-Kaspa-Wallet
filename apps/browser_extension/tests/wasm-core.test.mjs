import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import init,{addressWithPrefix,deriveBackupKey,generateWallet,generateWalletWithWordCount,importWallet,mnemonicWordStatus,prepareInscription,publicKey,signPersonalMessage}from"./generated/wasm/kaspa_secure_core.mjs";

await init(await readFile(new URL("./generated/wasm/kaspa_secure_core_bg.wasm",import.meta.url)));

test("browser WASM creates and deterministically restores a wallet",()=>{const created=JSON.parse(generateWallet(""));assert.equal(created.mnemonic.split(" ").length,24);const restored=JSON.parse(importWallet(created.mnemonic,""));assert.equal(restored.address,created.address);assert.match(publicKey(`mnemonic:${created.mnemonic}`),/^[0-9a-f]{64}$/)});
test("browser WASM creates requested 12 and 24 word wallets",()=>{for(const count of[12,24]){const created=JSON.parse(generateWalletWithWordCount("optional passphrase",count));assert.equal(created.mnemonic.split(" ").length,count);assert.match(created.address,/^kaspa:/)}assert.throws(()=>generateWalletWithWordCount("",18))});
test("browser WASM preserves ownership across TN10 prefix conversion",()=>{const created=JSON.parse(generateWallet(""));assert.match(addressWithPrefix(created.address,true),/^kaspatest:/)});
test("browser WASM derives a 256-bit backup key",()=>assert.match(deriveBackupKey("correct horse battery staple","07".repeat(32)),/^[0-9a-f]{64}$/));
test("browser WASM uses the canonical BIP-39 list for feedback",()=>{const status=JSON.parse(mnemonicWordStatus("aboot aban"));assert.deepEqual(status.invalidWords,["aboot","aban"]);assert(status.suggestions.includes("abandon"))});
test("browser WASM builds reviewed canonical assets and KIP-5 signatures",()=>{const wallet=JSON.parse(generateWallet(""));const secret=`mnemonic:${wallet.mnemonic}`;const plan=JSON.parse(prepareInscription(JSON.stringify({kind:"krc20",sender:wallet.address,recipient:wallet.address,ticker:"TEST",amount:"1",tokenId:"",assetId:""})));assert.equal(plan.namespace,"kasplex");assert.match(signPersonalMessage(secret,wallet.address,"WASM integration test"),/^[0-9a-f]{128}$/)});
