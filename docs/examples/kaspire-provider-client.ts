// Kaspire provider-consumer example.
//
// This file documents calls to the public `window.kaspire` API. It is not the
// private KCOM adapter and does not implement KaspaCom's shared wallet layer.
// KaspaCom owns that mapping inside its KCC20/Kaspiano applications.

type KaspireNetwork = "mainnet" | "testnet-10";
type Listener = (value: unknown) => void;

interface KaspireProvider {
  request<T>(request: { method: string; params?: unknown }): Promise<T>;
  on(event: string, listener: Listener): KaspireProvider;
  removeListener(event: string, listener: Listener): KaspireProvider;
}

declare global {
  interface Window {
    kaspire?: KaspireProvider;
  }
}

export interface KaspirePsktRequest {
  psktTransactionJson: string;
  submitTransaction?: false;
  signInputs?: Array<{ index: number; sighashType?: number }>;
  scripts?: Array<{
    inputIndex: number;
    scriptHex: string;
    signType?: number;
    signatureScript?: {
      mode: "wrap-signature" | "signature-first-args" | "ordered-args";
      args?: Array<
        | { type: "i64"; value: string | number }
        | { type: "data"; hex: string }
        | { type: "byte"; value: number }
        | { type: "signature"; prefixHex?: string }
      >;
    };
  }>;
}

export function requireKaspireProvider(): KaspireProvider {
  if (!window.kaspire) {
    throw new Error("Kaspire extension is not installed.");
  }
  return window.kaspire;
}

export async function connectKaspire(): Promise<string> {
  const accounts = await requireKaspireProvider().request<string[]>({
    method: "requestAccounts",
  });
  if (accounts.length !== 1) {
    throw new Error("Kaspire account approval failed.");
  }
  return accounts[0];
}

export function getKaspireNetwork(): Promise<KaspireNetwork> {
  return requireKaspireProvider().request({ method: "getNetwork" });
}

export function switchKaspireNetwork(
  network: KaspireNetwork,
): Promise<KaspireNetwork> {
  return requireKaspireProvider().request({
    method: "switchNetwork",
    params: { network },
  });
}

export async function signKaspireAuth(message: string): Promise<{
  publicKey: string;
  signedMessage: string;
}> {
  const result = await requireKaspireProvider().request<{
    publicKey: string;
    signedMessage: string;
  }>({ method: "signMessage", params: { message } });
  if (
    !/^[0-9a-f]{64}$/i.test(result.publicKey) ||
    !/^[0-9a-f]{128}$/i.test(result.signedMessage)
  ) {
    throw new Error("Kaspire returned an invalid authentication result.");
  }
  return result;
}

export function getKaspireBalance(): Promise<{
  current: number;
  pending: number;
  outgoing: number;
}> {
  return requireKaspireProvider().request({ method: "getBalance" });
}

export async function sendKaspireKas(request: {
  to: string;
  amountSompi: string;
  priorityFeeSompi?: string;
}): Promise<{ transactionId: string }> {
  const result = await requireKaspireProvider().request<
    string | { transactionId: string }
  >({ method: "sendKaspa", params: request });
  return typeof result === "string" ? { transactionId: result } : result;
}

export function signKaspirePskt(
  request: KaspirePsktRequest,
): Promise<{ psktTransactionJson: string }> {
  return requireKaspireProvider().request({
    method: "signPskt",
    params: request,
  });
}

export function onKaspireEvent(
  event:
    | "accountsChanged"
    | "networkChanged"
    | "balanceChanged"
    | "disconnect",
  listener: Listener,
): () => void {
  const provider = requireKaspireProvider();
  provider.on(event, listener);
  return () => provider.removeListener(event, listener);
}

export async function disconnectKaspire(): Promise<void> {
  await requireKaspireProvider().request({ method: "disconnect" });
}
