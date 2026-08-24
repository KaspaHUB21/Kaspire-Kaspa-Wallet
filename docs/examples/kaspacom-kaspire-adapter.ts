type KaspaComNetwork = "mainnet" | "testnet-10" | "testnet-11" | "devnet";
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

export interface KaspaComPsktRequest {
  psktTransactionJson: string;
  submitTransaction?: boolean;
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

export class KaspaComKaspireAdapter {
  get available(): boolean {
    return Boolean(window.kaspire);
  }

  private get provider(): KaspireProvider {
    if (!window.kaspire) throw new Error("Kaspire extension is not installed.");
    return window.kaspire;
  }

  async initialize(): Promise<void> {
    const accounts = await this.provider.request<string[]>({
      method: "requestAccounts",
    });
    if (accounts.length !== 1) throw new Error("Kaspire account approval failed.");
  }

  async getAddress(): Promise<string> {
    const accounts = await this.provider.request<string[]>({
      method: "getAccounts",
    });
    if (accounts.length !== 1) throw new Error("Kaspire is not connected.");
    return accounts[0];
  }

  getNetwork(): Promise<KaspaComNetwork> {
    return this.provider.request({ method: "getNetwork" });
  }

  switchNetwork(network: KaspaComNetwork): Promise<KaspaComNetwork> {
    return this.provider.request({ method: "switchNetwork", params: { network } });
  }

  async signAuthMessage(message: string): Promise<{
    publicKey: string;
    signedMessage: string;
  }> {
    const result = await this.provider.request<{
      publicKey: string;
      signedMessage: string;
    }>({ method: "signMessage", params: { message } });
    if (!/^[0-9a-f]{64}$/i.test(result.publicKey) ||
        !/^[0-9a-f]{128}$/i.test(result.signedMessage)) {
      throw new Error("Kaspire returned an invalid authentication result.");
    }
    return result;
  }

  async getBalance(): Promise<{
    current: number;
    pending: number;
    outgoing: number;
  }> {
    const raw = await this.provider.request<Record<string, unknown>>({
      method: "getBalance",
    });
    return {
      current: Number(raw.current ?? raw.balanceKas ?? 0),
      pending: Number(raw.pending ?? 0),
      outgoing: Number(raw.outgoing ?? 0),
    };
  }

  async sendKas(request: {
    to: string;
    amountSompi: string;
    priorityFeeSompi?: string;
  }): Promise<{ transactionId: string }> {
    const result = await this.provider.request<string | { transactionId: string }>({
      method: "sendKaspa",
      params: request,
    });
    return typeof result === "string" ? { transactionId: result } : result;
  }

  async signPskt(
    request: KaspaComPsktRequest,
  ): Promise<{ transactionId?: string; psktTransactionJson: string }> {
    return this.provider.request({ method: "signPskt", params: request });
  }

  async disconnect(): Promise<void> {
    await this.provider.request({ method: "disconnect" });
  }

  on(
    event: "accountsChanged" | "networkChanged" | "balanceChanged" | "disconnect",
    listener: Listener,
  ): () => void {
    this.provider.on(event, listener);
    return () => this.provider.removeListener(event, listener);
  }
}
