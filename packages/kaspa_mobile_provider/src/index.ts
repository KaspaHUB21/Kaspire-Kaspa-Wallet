export const KASPA_CHAIN = "kaspa:mainnet" as const;

export type KaspaMethod =
  | "kaspa_getAccounts"
  | "kaspa_signPersonal"
  | "kaspa_sendTransaction"
  | "kaspa_sendKrc20"
  | "kaspa_sendKcc20"
  | "kaspa_signVaultTransaction";

export interface WalletTransport {
  request<T>(method: KaspaMethod, params?: unknown): Promise<T>;
}

export interface WalletConnectSignClient {
  request<T>(input: {
    topic: string;
    chainId: typeof KASPA_CHAIN;
    request: { method: KaspaMethod; params: unknown };
  }): Promise<T>;
}

export interface Krc20TransferResult {
  ticker: string;
  amount: string;
  commitTransactionId: string;
  revealTransactionId: string;
  commitFeeSompi: number;
  revealFeeSompi: number;
}

export interface Kcc20TransferResult {
  transactionId: string;
  covenantId: string;
  ticker: string;
  amount: string;
  feeSompi: number;
  mass: number;
  validation: "toccata-node";
}

export interface PolicyTransactionResult {
  signedTxJson: string;
  profile:
    | "vault-create-v2"
    | "vault-dms-create-v2"
    | "vault-dms-heartbeat-v2";
  reviewHash: string;
}

export function kaspirePairingLink(walletConnectUri: string): string {
  if (!/^wc:[0-9a-f]{64}@2\?/i.test(walletConnectUri)) {
    throw new Error("A WalletConnect v2 pairing URI is required");
  }
  return `https://kaspire.kaslab.space/kaspire/wc?uri=${encodeURIComponent(walletConnectUri)}`;
}

export function walletConnectTransport(
  client: WalletConnectSignClient,
  topic: string,
): WalletTransport {
  if (!topic.trim()) throw new Error("A WalletConnect session topic is required");
  return {
    request: <T>(method: KaspaMethod, params: unknown = {}) =>
      client.request<T>({
        topic,
        chainId: KASPA_CHAIN,
        request: { method, params },
      }),
  };
}

export class KaspireProvider {
  constructor(
    private readonly transport: WalletTransport,
    private readonly address?: string,
  ) {}

  requestAccounts(): Promise<string[]> {
    return this.transport.request<string[]>("kaspa_getAccounts");
  }

  getNetwork(): Promise<typeof KASPA_CHAIN> {
    return Promise.resolve(KASPA_CHAIN);
  }

  signMessage(message: string): Promise<string> {
    if (!message || message.length > 4096) {
      return Promise.reject(new Error("Invalid KIP-5 message"));
    }
    return this.transport.request<string>("kaspa_signPersonal", {
      message,
      ...(this.address ? { address: this.address } : {}),
    });
  }

  sendKaspa(to: string, amountSompi: bigint): Promise<string> {
    if (!/^kaspa:[a-z0-9]{61,63}$/.test(to) || amountSompi <= 0n) {
      return Promise.reject(new Error("Invalid Kaspa payment request"));
    }
    return this.transport.request<string>("kaspa_sendTransaction", {
      to,
      amountSompi: amountSompi.toString(),
      ...(this.address ? { from: this.address } : {}),
    });
  }

  sendKrc20(
    to: string,
    ticker: string,
    rawAmount: bigint,
  ): Promise<Krc20TransferResult> {
    if (
      !/^kaspa:[a-z0-9]{61,63}$/.test(to) ||
      !/^[A-Z0-9_-]{1,32}$/.test(ticker.toUpperCase()) ||
      rawAmount <= 0n
    ) {
      return Promise.reject(new Error("Invalid KRC-20 transfer request"));
    }
    return this.transport.request<Krc20TransferResult>("kaspa_sendKrc20", {
      to,
      ticker: ticker.toUpperCase(),
      amount: rawAmount.toString(),
      ...(this.address ? { from: this.address } : {}),
    });
  }

  sendKcc20(
    to: string,
    covenantId: string,
    rawAmount: bigint,
  ): Promise<Kcc20TransferResult> {
    if (
      !/^kaspa:[a-z0-9]{61,63}$/.test(to) ||
      !/^[0-9a-f]{64}$/i.test(covenantId) ||
      rawAmount <= 0n
    ) {
      return Promise.reject(new Error("Invalid KCC20 covenant transfer request"));
    }
    return this.transport.request<Kcc20TransferResult>("kaspa_sendKcc20", {
      to,
      covenantId: covenantId.toLowerCase(),
      amount: rawAmount.toString(),
      ...(this.address ? { from: this.address } : {}),
    });
  }

  signVaultTransaction(
    txJsonString: string,
    signInputIndexes: readonly number[],
    redeemScript = "",
  ): Promise<PolicyTransactionResult> {
    if (
      !txJsonString ||
      txJsonString.length > 256 * 1024 ||
      !(
        (signInputIndexes.length === 1 && signInputIndexes[0] === 0) ||
        (signInputIndexes.length === 2 &&
          signInputIndexes[0] === 0 &&
          signInputIndexes[1] === 1)
      )
    ) {
      return Promise.reject(new Error("Invalid vault policy transaction"));
    }
    return this.transport.request<PolicyTransactionResult>(
      "kaspa_signVaultTransaction",
      { txJsonString, signInputIndexes: [...signInputIndexes], redeemScript },
    );
  }
}

/** @deprecated Use KaspireProvider. */
export const KasVaultProvider = KaspireProvider;
