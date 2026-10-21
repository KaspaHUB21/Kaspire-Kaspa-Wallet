import * as wasmModule from "kaspire-wasm";
import { secureCore } from './secretInputs';

type CoreModule = {
  secretBoundaryVersion(): number;
  default(input: { module_or_path: RequestInfo | URL | Response | BufferSource | WebAssembly.Module }): Promise<unknown>;
  generateWallet(passphrase: string): string;
  generateWalletWithWordCount(passphrase: string, wordCount: number): string;
  importWallet(words: string, passphrase: string): string;
  mnemonicWordStatus(phrase: string): string;
  importPrivateKey(key: string): string;
  deriveAddressRange(secret: string, coin: number, account: number, change: number, start: number, count: number): string;
  addressWithPrefix(address: string, testnet: boolean): string;
  deriveEvmAddress(secret: string): string;
  exportEvmPrivateKey(secret: string): string;
  prepareEvmTransaction(request: string): string;
  signEvmTransaction(secret: string, request: string, reviewHash: string): string;
  exportPrivateKey(secret: string): string;
  publicKey(secret: string): string;
  deriveHiddenKas(secret: string, branch: number, start: number, count: number): string;
  validateHiddenKasUtxos(secret: string, address: string, rows: string): string;
  prepareHiddenKas(secret: string, request: string): string;
  signHiddenKas(secret: string, request: string, reviewHash: string): string;
  verifyHiddenKasRecovery(secret: string, saved: string): string;
  deriveDotkDeed(request: string): string;
  describeDotkMarket(request: string): string;
  prepareDotkMarket(request: string): string;
  signDotkMarket(secret: string, request: string, reviewHash: string): string;
  deriveBackupKey(password: string, saltHex: string): Uint8Array<ArrayBuffer>;
  deriveBackupKeyV3(password: string, saltHex: string): Uint8Array<ArrayBuffer>;
  prepareTransaction(request: string): string;
  signTransaction(secret: string, request: string, reviewHash: string): string;
  signPersonalMessage(secret: string, address: string, message: string): string;
  preparePskt(request: string): string;
  prepareKronTransfer(request: string): string;
  prepareKcc20Plan(request: string): string;
  signKcc20Plan(secret: string, request: string, reviewHash: string): string;
  prepareNftMarket(request: string): string;
  signPskt(secret: string, request: string, reviewHash: string): string;
  prepareInscription(request: string): string;
  prepareReveal(request: string): string;
  signReveal(secret: string, request: string, reviewHash: string): string;
  prepareKcc20Transfer(request: string): string;
  signKcc20Transfer(secret: string, request: string, reviewHash: string): string;
  preparePolicyTransaction(request: string): string;
  signPolicyTransaction(secret: string, request: string, reviewHash: string): string;
  prepareWyrmGenesis(request: string): string;
  signWyrmGenesis(secret: string, request: string, reviewHash: string): string;
  prepareWyrmTransition(request: string): string;
  signWyrmTransition(secret: string, request: string, reviewHash: string): string;
  describeCovenantVault(terms: string): string;
  prepareCovenantVault(request: string): string;
  signCovenantVault(secret: string, request: string, reviewHash: string): string;
  validateVaultRecord(record: string): string;
  sealVaultRecovery(password: Uint8Array, record: string): string;
  openVaultRecovery(password: Uint8Array, envelope: string): string;
};

let loading: Promise<CoreModule> | null = null;
export function core(): Promise<CoreModule> {
  loading ??= (async () => {
    const wasmUrl = chrome.runtime.getURL("wasm/kaspa_secure_core_bg.wasm");
    const module = wasmModule as unknown as CoreModule;
    const exports = await module.default({ module_or_path: wasmUrl }) as { memory: WebAssembly.Memory };
    if (module.secretBoundaryVersion?.() !== 1) throw Error('Incompatible signing core. Reload the complete Kaspire extension package.');
    return secureCore(module, exports.memory);
  })();
  return loading;
}
