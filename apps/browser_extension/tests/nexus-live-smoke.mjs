// Controlled, empty synthetic wallet only. Never prints mnemonic or bearer.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import init,{generateWallet,publicKey,signPersonalMessage} from './generated/wasm/kaspa_secure_core.mjs';
await init({module_or_path:await readFile(new URL('./generated/wasm/kaspa_secure_core_bg.wasm',import.meta.url))});
const base='https://kaspire.kaslab.space/nexus-test-v1';
const wallet=JSON.parse(generateWallet('')),secret='mnemonic:'+wallet.mnemonic;
async function post(path,body){const r=await fetch(base+'/'+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});return {status:r.status,body:await r.json()};}
const challenge=await post('auth/internal-challenge',{walletAddress:wallet.address});assert.equal(challenge.status,200);
assert.ok(challenge.body.message.startsWith('Kaspire Internal NFT Offers\n'));
const signature=signPersonalMessage(secret,wallet.address,challenge.body.message);
const wrongPurpose=await post('auth/verify',{walletAddress:wallet.address,nonce:challenge.body.nonce,signature,publicKey:publicKey(secret)});assert.equal(wrongPurpose.status,404);
const login=await post('auth/internal-verify',{walletAddress:wallet.address,nonce:challenge.body.nonce,signature,publicKey:publicKey(secret)});assert.equal(login.status,200,login.body.error);
assert.equal(login.body.walletAddress,wallet.address);assert.equal(typeof login.body.token,'string');
const replay=await post('auth/internal-verify',{walletAddress:wallet.address,nonce:challenge.body.nonce,signature,publicKey:publicKey(secret)});assert.equal(replay.status,401);
const unread=await fetch(base+'/dashboard/notifications',{headers:{authorization:'Bearer '+login.body.token}});assert.equal(unread.status,200);assert.deepEqual(await unread.json(),[]);
const forbidden=await fetch(base+'/dashboard/received');assert.equal(forbidden.status,401);
console.log('Live Nexus login verified: Kaspire message signature accepted, replay rejected, private dashboard requires bearer. No offers or transactions created.');
