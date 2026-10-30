// Mirrors the standalone server entry point and its CommonJS/ESM loader boundary.
// Public, disposable test key only. No network access, secrets or live offers.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { verifyWalletSignatureDetailed } from '../services/nft-nexus/src/lib/auth/wallet-verifier';

const require = createRequire(new URL('../services/nft-nexus/package.json', `file://${__filename}`));
const kaspa = require('kaspa-wasm');
const privateKey = '1'.padStart(64, '0');
const pair = new kaspa.PrivateKey(privateKey).toKeypair();
const message = 'Kaspire internal login loader regression';
void (async () => {
  for (const publicKey of [pair.xOnlyPublicKey, pair.publicKey]) {
    const result = await verifyWalletSignatureDetailed({
      walletAddress: pair.toAddress('mainnet').toString(), message,
      signature: kaspa.signMessage({ message, privateKey }), publicKey,
    });
    assert.equal(result.valid, true, result.reason);
  }
  console.log('Standalone Nexus loader accepts genuine Kaspire-format Schnorr signatures.');
})();
