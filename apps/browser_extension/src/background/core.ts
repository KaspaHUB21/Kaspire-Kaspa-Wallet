import * as wasmModule from "kaspire-wasm";

type CoreModule = {
  default(input?: RequestInfo | URL | Response | BufferSource | WebAssembly.Module): Promise<unknown>;
  generateWallet(passphrase: string): string;
  generateWalletWithWordCount(passphrase: string, wordCount: number): string;
  importWallet(words: string, passphrase: string): string;
  mnemonicWordStatus(phrase: string): string;
  importPrivateKey(key: string): string;
  deriveAddressRange(secret: string, coin: number, account: number, change: number, start: number, count: number): string;
  addressWithPrefix(address: string, testnet: boolean): string;
  deriveEvmAddress(secret: string): string;
  prepareEvmTransaction(request: string): string;
  signEvmTransaction(secret: string, request: string, reviewHash: string): string;
  exportPrivateKey(secret: string): string;
  publicKey(secret: string): string;
  deriveBackupKey(password: string, saltHex: string): string;
  prepareTransaction(request: string): string;
  signTransaction(secret: string, request: string, reviewHash: string): string;
  signPersonalMessage(secret: string, address: string, message: string): string;
  preparePskt(request: string): string;
  signPskt(secret: string, request: string, reviewHash: string): string;
  prepareInscription(request: string): string;
  prepareReveal(request: string): string;
  signReveal(secret: string, request: string, reviewHash: string): string;
  prepareKcc20Transfer(request: string): string;
  signKcc20Transfer(secret: string, request: string, reviewHash: string): string;
  preparePolicyTransaction(request: string): string;
  signPolicyTransaction(secret: string, request: string, reviewHash: string): string;
};

let loading: Promise<CoreModule> | null = null;
export function core(): Promise<CoreModule> {
  loading ??= (async () => {
    const wasmUrl = chrome.runtime.getURL("wasm/kaspa_secure_core_bg.wasm");
    const module = wasmModule as unknown as CoreModule;
    await module.default(wasmUrl);
    return module;
  })();
  return loading;
}
