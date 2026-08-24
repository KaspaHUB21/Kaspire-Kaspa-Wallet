import {
  PROVIDER_CHANNEL,
  type KaspaNetwork,
  type ProviderEvent,
  type ProviderMethod,
  type ProviderResponse,
} from "../shared/protocol";

type Listener = (...args: unknown[]) => void;

class KaspireProvider {
  readonly isKaspire = true;
  readonly version = "1.2.0";
  private listeners = new Map<string, Set<Listener>>();
  private balanceTimer: number | null = null;
  private lastBalance = "";

  constructor() {
    addEventListener("message", (event) => {
      const message = event.data as ProviderEvent;
      if (event.source !== window || message?.channel !== PROVIDER_CHANNEL || message.direction !== "event") return;
      this.emit(message.event, message.data);
    });
  }

  private emit(event: string, data: unknown) {
    for (const listener of this.listeners.get(event) ?? []) {
      try { listener(data); } catch {}
    }
  }

  private updateBalanceMonitor() {
    const needed = (this.listeners.get("balanceChanged")?.size ?? 0) > 0;
    if (!needed && this.balanceTimer !== null) {
      clearInterval(this.balanceTimer);
      this.balanceTimer = null;
      this.lastBalance = "";
      return;
    }
    if (!needed || this.balanceTimer !== null) return;
    const poll = async () => {
      try {
        const raw = (await this.getBalance()) as Record<string, unknown>;
        const balance = {
          current: Number(raw.current ?? raw.balanceKas ?? 0),
          pending: Number(raw.pending ?? 0),
          outgoing: Number(raw.outgoing ?? 0),
        };
        const encoded = JSON.stringify(balance);
        if (this.lastBalance && encoded !== this.lastBalance) this.emit("balanceChanged", balance);
        this.lastBalance = encoded;
      } catch {}
    };
    void poll();
    this.balanceTimer = window.setInterval(poll, 15_000);
  }

  request<T = unknown>({ method, params }: { method: ProviderMethod; params?: unknown }): Promise<T> {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        removeEventListener("message", receive);
        reject(new Error("Kaspire request timed out."));
      }, 360_000);
      const receive = (event: MessageEvent<ProviderResponse>) => {
        const response = event.data;
        if (event.source !== window || response?.channel !== PROVIDER_CHANNEL || response.direction !== "response" || response.id !== id) return;
        clearTimeout(timeout);
        removeEventListener("message", receive);
        response.error ? reject(Object.assign(new Error(response.error.message), response.error)) : resolve(response.result as T);
      };
      addEventListener("message", receive);
      postMessage({ channel: PROVIDER_CHANNEL, direction: "request", id, method, params }, location.origin);
    });
  }

  on(event: string, listener: Listener) {
    const listeners = this.listeners.get(event) ?? new Set<Listener>();
    listeners.add(listener);
    this.listeners.set(event, listeners);
    this.updateBalanceMonitor();
    return this;
  }

  removeListener(event: string, listener: Listener) {
    this.listeners.get(event)?.delete(listener);
    this.updateBalanceMonitor();
    return this;
  }

  async requestAccounts() {
    const accounts = await this.request<string[]>({ method: "requestAccounts" });
    this.emit("accountsChanged", accounts);
    return accounts;
  }
  connect() { return this.requestAccounts(); }
  requestNetworkAccounts(networks: ("mainnet" | "testnet-10" | "kasplex" | "igra")[]) { return this.request<Record<string, string>>({ method: "requestNetworkAccounts", params: { networks } }); }
  getAccounts() { return this.request<string[]>({ method: "getAccounts" }); }
  getNetworkAccounts() { return this.request<Record<string, string>>({ method: "getNetworkAccounts" }); }
  getNetwork() { return this.request<KaspaNetwork>({ method: "getNetwork" }); }
  async switchNetwork(network: KaspaNetwork) { const selected = await this.request<KaspaNetwork>({ method: "switchNetwork", params: { network } }); this.emit("networkChanged", selected); return selected; }
  getPublicKey() { return this.request<string>({ method: "getPublicKey" }); }
  getBalance() { return this.request({ method: "getBalance" }); }
  getUtxoEntries() { return this.request({ method: "getUtxoEntries" }); }
  async disconnect() { const result = await this.request({ method: "disconnect" }); this.emit("accountsChanged", []); this.emit("disconnect", { code: 4900, message: "Kaspire disconnected this site." }); return result; }
  signMessage(message: string, address?: string) { return this.request({ method: "signMessage", params: { message, address } }); }
  sendKaspa(params: unknown) { return this.request({ method: "sendKaspa", params }); }
  sendKRC20(params: unknown) { return this.request({ method: "sendKRC20", params }); }
  sendKCC20(params: unknown) { return this.request({ method: "sendKCC20", params }); }
  signPskt(first: unknown, options?: unknown) { return this.request({ method: "signPskt", params: typeof first === "string" ? { txJsonString: first, options } : first }); }
  pushTx(transaction: string) { return this.request({ method: "pushTx", params: transaction }); }
  signPolicyTransaction(params: unknown) { return this.request({ method: "signPolicyTransaction", params }); }
  transferKRC721(params: unknown) { return this.request({ method: "transferKRC721", params }); }
  transferKNS(params: unknown) { return this.request({ method: "transferKNS", params }); }
}

const provider = new KaspireProvider();
Object.defineProperty(window, "kaspire", { value: provider, configurable: false, writable: false });
dispatchEvent(new CustomEvent("kaspire#initialized"));
declare global { interface Window { kaspire: KaspireProvider } }
