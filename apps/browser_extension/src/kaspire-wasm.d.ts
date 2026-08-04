declare module "kaspire-wasm" {
  const init: (input?: unknown) => Promise<unknown>;
  export default init;
  export const generateWallet: (...args: unknown[]) => string;
}
