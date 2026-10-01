import { core } from "./core";

export interface EncryptedVault { version: 2; salt: string; iv: string; ciphertext: string }
export type PortableBackup =
  | {format:"kaspire-backup-v1";kdf:"pbkdf2-sha256";iterations:600000;salt:string;iv:string;ciphertext:string}
  | {format:"kaspire-backup-v2";kdf:"argon2id-v19";memoryKiB:32768;iterations:3;parallelism:1;salt:string;iv:string;ciphertext:string}
  | {format:"kaspire-backup-v3";kdf:"argon2id-v19";memoryKiB:65536;iterations:4;parallelism:1;address:string;salt:string;iv:string;ciphertext:string};
const encoder = new TextEncoder(); const decoder = new TextDecoder();
const MAX_BACKUP_BASE64_BYTES = 3 * 1024 * 1024;

function hex(bytes: Uint8Array) { return [...bytes].map(value => value.toString(16).padStart(2, "0")).join(""); }
function bytes(value: string) { const result = new Uint8Array(value.length / 2); for (let i=0;i<result.length;i++) result[i]=Number.parseInt(value.slice(i*2,i*2+2),16); return result; }
function b64(value: Uint8Array) { let binary=""; for (const item of value) binary+=String.fromCharCode(item); return btoa(binary); }
function unb64(value: string) { return Uint8Array.from(atob(value), item => item.charCodeAt(0)); }

async function key(password: string, salt: Uint8Array, version: 2|3 = 2) {
  const wasm = await core();
  const derived = bytes(version === 3
    ? wasm.deriveBackupKeyV3(password, hex(salt))
    : wasm.deriveBackupKey(password, hex(salt)));
  try { return await crypto.subtle.importKey("raw", derived, "AES-GCM", false, ["encrypt", "decrypt"]); }
  finally { derived.fill(0); }
}

async function legacyKey(password: string, salt: Uint8Array) {
  const material = await crypto.subtle.importKey(
    "raw",
    encoder.encode(password),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(salt), iterations: 600000 },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
}

export async function createVault(password: string, payload: unknown) {
  if (password.length < 12) throw new Error("Use at least 12 password characters.");
  const salt=crypto.getRandomValues(new Uint8Array(32)); const iv=crypto.getRandomValues(new Uint8Array(12));
  const ciphertext=await crypto.subtle.encrypt({name:"AES-GCM",iv,additionalData:encoder.encode("kaspire-extension-v2")},await key(password,salt),encoder.encode(JSON.stringify(payload)));
  const vault:EncryptedVault={version:2,salt:b64(salt),iv:b64(iv),ciphertext:b64(new Uint8Array(ciphertext))};
  await chrome.storage.local.set({encryptedVault:vault});
}

export async function unlockVault(password: string): Promise<Record<string, unknown>> {
  const {encryptedVault}=await chrome.storage.local.get("encryptedVault"); const vault=encryptedVault as EncryptedVault|undefined;
  return decryptVault(vault, password);
}

export async function decryptVault(vault: EncryptedVault|undefined, password: string): Promise<Record<string, unknown>> {
  if (!vault || vault.version!==2) throw new Error("No encrypted Kaspire vault exists.");
  if (![vault.salt,vault.iv,vault.ciphertext].every(value=>typeof value==="string"&&value.length>0)) throw new Error("Damaged Kaspire backup.");
  if (vault.salt.length > 128 || vault.iv.length > 128 || vault.ciphertext.length > MAX_BACKUP_BASE64_BYTES) throw new Error("Backup is too large.");
  try { const plaintext=await crypto.subtle.decrypt({name:"AES-GCM",iv:unb64(vault.iv),additionalData:encoder.encode("kaspire-extension-v2")},await key(password,unb64(vault.salt)),unb64(vault.ciphertext)); return JSON.parse(decoder.decode(plaintext)); }
  catch { throw new Error("Incorrect password or damaged vault."); }
}

export async function createPortableBackup(password:string,payload:unknown):Promise<PortableBackup>{
  if(password.length<12)throw new Error("Use at least 12 characters.");
  const salt=crypto.getRandomValues(new Uint8Array(32)),iv=crypto.getRandomValues(new Uint8Array(12));
  const ciphertext=await crypto.subtle.encrypt({name:"AES-GCM",iv},await key(password,salt,3),encoder.encode(JSON.stringify(payload)));
  const address=String((payload as {address?:unknown})?.address??"").trim();
  if(!address)throw new Error("Backup address is missing.");
  return{format:"kaspire-backup-v3",kdf:"argon2id-v19",memoryKiB:65536,iterations:4,parallelism:1,address,salt:b64(salt),iv:b64(iv),ciphertext:b64(new Uint8Array(ciphertext))};
}

export async function decryptPortableBackup(backup:PortableBackup,password:string):Promise<Record<string,unknown>>{
  const version=backup?.format==="kaspire-backup-v3"?3:backup?.format==="kaspire-backup-v2"?2:backup?.format==="kaspire-backup-v1"?1:0;
  const valid=version===3
    ? backup?.kdf==="argon2id-v19"&&backup?.memoryKiB===65536&&backup?.iterations===4&&backup?.parallelism===1
    : version===2
      ? backup?.kdf==="argon2id-v19"&&backup?.memoryKiB===32768&&backup?.iterations===3&&backup?.parallelism===1
      : version===1&&backup?.kdf==="pbkdf2-sha256"&&backup?.iterations===600000;
  if(!valid)throw new Error("Unsupported Kaspire backup parameters.");
  if(typeof backup.salt!=="string"||typeof backup.iv!=="string"||typeof backup.ciphertext!=="string"||backup.salt.length>128||backup.iv.length>128||backup.ciphertext.length>MAX_BACKUP_BASE64_BYTES)throw new Error("Backup is too large.");
  const salt=unb64(backup.salt),iv=unb64(backup.iv),ciphertext=unb64(backup.ciphertext);if(salt.length!==32||iv.length!==12||ciphertext.length<16)throw new Error("Damaged Kaspire backup.");
  try{const decryptionKey=version===1?await legacyKey(password,salt):await key(password,salt,version as 2|3);const plaintext=await crypto.subtle.decrypt({name:"AES-GCM",iv},decryptionKey,ciphertext);return JSON.parse(decoder.decode(plaintext))}
  catch{throw new Error("Incorrect password or damaged backup.")}
}
