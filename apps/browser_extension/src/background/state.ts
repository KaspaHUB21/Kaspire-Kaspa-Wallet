import type { KaspaNetwork } from "../shared/protocol";
export interface WalletAddress {
  address: string;
  name: string;
  path: string;
  watchOnly: boolean;
  walletId: string;
  coinType: number;
  account: number;
  change: number;
  index: number;
  receiveRotation?: boolean;
}
export interface Contact {
  id: string;
  name: string;
  address: string;
}
export interface DappPermission {
  accounts: boolean;
  connectedAt: number;
  networks?: KaspaNetwork[];
  evmChainId?: number;
}
export interface WalletState {
  version: 2;
  network: KaspaNetwork;
  selectedAddress: string | null;
  addresses: WalletAddress[];
  permissions: Record<string, DappPermission>;
  contacts: Contact[];
  settings: {
    autoLockMinutes: number;
    hideBalances: boolean;
    currency: string;
    uppercase: boolean;
    theme: string;
    showSubwallets: boolean;
    recipientAllowlist: boolean;
  };
  locked: boolean;
  recoveryVerified: boolean;
}

const defaults: WalletState = {
  version: 2,
  network: "mainnet",
  selectedAddress: null,
  addresses: [],
  permissions: {},
  contacts: [],
  settings: {
    autoLockMinutes: 15,
    hideBalances: false,
    currency: "USD",
    uppercase: true,
    theme: "midnight",
    showSubwallets: true,
    recipientAllowlist: false,
  },
  locked: true,
  recoveryVerified: true,
};

function sanitized(raw: any): WalletState {
  return {
    version: 2,
    network: ["mainnet", "testnet-10", "kasplex", "igra"].includes(raw?.network)
      ? raw.network
      : defaults.network,
    selectedAddress:
      typeof raw?.selectedAddress === "string" ? raw.selectedAddress : null,
    addresses: Array.isArray(raw?.addresses)
      ? raw.addresses.map((item: any) => ({
          ...item,
          receiveRotation: item?.receiveRotation === true,
        }))
      : [],
    permissions:
      raw?.permissions && typeof raw.permissions === "object"
        ? raw.permissions
        : {},
    contacts: Array.isArray(raw?.contacts) ? raw.contacts : [],
    settings: {
      ...defaults.settings,
      ...(raw?.settings && typeof raw.settings === "object"
        ? raw.settings
        : {}),
    },
    locked: true,
    recoveryVerified: raw?.recoveryVerified !== false,
  };
}

export async function loadState(): Promise<WalletState> {
  const { walletState } = await chrome.storage.local.get("walletState");
  if (walletState?.version !== 2) return { ...defaults };
  const clean = sanitized(walletState);
  // Old builds could carry deprecated secret-bearing fields forward through
  // object spreading. Persist only the explicit public allow-list.
  if ("wallets" in walletState || "secret" in walletState) {
    await chrome.storage.local.set({ walletState: clean });
  }
  return clean;
}

export async function saveState(state: WalletState) {
  const { walletState: previous } =
    await chrome.storage.local.get("walletState");
  const current = sanitized(state);
  await chrome.storage.local.set({ walletState: current });
  void chrome.tabs.query({}).then((tabs) =>
    Promise.all(
      tabs.flatMap((tab) =>
        tab.id === undefined
          ? []
          : [
              chrome.tabs
                .sendMessage(tab.id, {
                  kind: "providerStateChanged",
                  previous: previous ?? null,
                  current,
                })
                .catch(() => undefined),
            ],
      ),
    ),
  );
}
