import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as kaspa from 'kaspa-wasm';
import { verifyWalletSignatureDetailed } from './wallet-verifier';

// Public, disposable test vectors only; no funded wallet or live offer is used.
const privateKey = '1'.padStart(64, '0');
const key = new kaspa.PrivateKey(privateKey);
const pair = key.toKeypair();
const message = 'Kaspire Internal NFT Offers\n\nDisposable verification test';
const walletAddress = pair.toAddress('mainnet').toString();
const signature = kaspa.signMessage({ message, privateKey });

test('Kaspire x-only and compressed Schnorr keys verify against the same wallet', async () => {
  for (const publicKey of [pair.xOnlyPublicKey, pair.publicKey]) {
    const result = await verifyWalletSignatureDetailed({ walletAddress, message, signature, publicKey });
    assert.equal(result.valid, true, result.reason);
  }
});

test('wrong wallet, message, signature and invalid public key remain rejected', async () => {
  const input = { walletAddress, message, signature, publicKey: pair.xOnlyPublicKey };
  const other = new kaspa.PrivateKey('2'.padStart(64, '0')).toKeypair();
  for (const change of [
    { walletAddress: other.toAddress('mainnet').toString() },
    { message: message + 'changed' },
    { signature: '00'.repeat(64) },
    { publicKey: 'ff'.repeat(32) },
    { publicKey: 'not-a-key' },
    { publicKey: undefined },
  ]) {
    const result = await verifyWalletSignatureDetailed({ ...input, ...change });
    assert.equal(result.valid, false);
    assert.doesNotMatch(result.reason ?? '', /kasware/i);
  }
});

test('supported public-key and signature encodings preserve the challenge binding', async () => {
  for (const encoded of [signature, Buffer.from(signature, 'hex').toString('base64'), Buffer.from(signature, 'hex').toString('base64url')]) {
    const result = await verifyWalletSignatureDetailed({ walletAddress, message, signature: encoded, publicKey: '0x' + pair.xOnlyPublicKey.toUpperCase() });
    assert.equal(result.valid, true, result.reason);
  }
});
