// WASM calls are synchronous. Own UTF-8 buffers only for the duration of a call,
// and wipe them even if encoding another argument or the WASM call fails.
// UI/session strings still follow JavaScript GC semantics; this is not a claim
// that browser memory can be made entirely wipeable or hardware-isolated.
export const secretArguments: Readonly<Record<string, readonly number[]>> = Object.freeze({
  generateWallet: [0], generateWalletWithWordCount: [0], importWallet: [0, 1],
  mnemonicWordStatus: [0], importPrivateKey: [0], deriveAddressRange: [0],
  deriveEvmAddress: [0], exportEvmPrivateKey: [0], exportPrivateKey: [0], publicKey: [0],
  deriveHiddenKas: [0], validateHiddenKasUtxos: [0], prepareHiddenKas: [0],
  signHiddenKas: [0], verifyHiddenKasRecovery: [0], signDotkMarket: [0],
  deriveBackupKey: [0], deriveBackupKeyV3: [0], signTransaction: [0],
  signEvmTransaction: [0], signPersonalMessage: [0], signPskt: [0], signReveal: [0],
  signKcc20Transfer: [0], signKcc20Plan: [0], signPolicyTransaction: [0], signWyrmGenesis: [0],
  signWyrmTransition: [0], signCovenantVault: [0],
});

export function secureCore<T extends object>(raw: T, memory: WebAssembly.Memory): T {
  const source = raw as Record<string, unknown>;
  const result = { ...raw } as Record<string, unknown>;
  const encoder = new TextEncoder();
  for (const [name, positions] of Object.entries(secretArguments)) {
    const fn = source[name];
    if (typeof fn !== 'function') continue;
    result[name] = (...values: unknown[]) => {
      const args = [...values], buffers: Uint8Array[] = [];
      try {
        for (const position of positions) {
          if (typeof args[position] !== 'string') throw Error('Invalid secret input.');
          const bytes = encoder.encode(args[position] as string);
          buffers.push(bytes); args[position] = bytes;
        }
        const value = Reflect.apply(fn, raw, args);
        if (name === 'deriveBackupKey' || name === 'deriveBackupKeyV3') {
          // Copy a native zeroizing key, then free/wipe the WASM allocation.
          // No immutable hex string of the derived AES key is created.
          try { return new Uint8Array(memory.buffer, value.pointer(), 32).slice(); }
          finally { try { value.wipe(); } finally { value.free(); } }
        }
        return value;
      } finally {
        for (const bytes of buffers) bytes.fill(0);
      }
    };
  }
  return result as T;
}
