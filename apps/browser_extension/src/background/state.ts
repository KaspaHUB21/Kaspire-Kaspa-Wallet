import type { KaspaNetwork } from "../shared/protocol";
import {currencies,isDisplayCurrency} from '../shared/displayCurrency';
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
  used?: boolean;
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
export {currencies};
const currencyKey='walletCurrencyPreferenceV1';
const validCurrency=isDisplayCurrency;
// Fiat preference is independent of a slow wallet/network/lock-state save.
// Older snapshots must never replace a newer explicit user selection.
export async function setCurrencyPreference(currency:string){
  if(!validCurrency(currency))throw Error('Unsupported display currency.');
  await chrome.storage.local.set({[currencyKey]:currency});
}

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
          used: item?.used === true,
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
  const stored = await chrome.storage.local.get(['walletState',currencyKey]),walletState=stored.walletState;
  const clean = sanitized(walletState?.version===2?walletState:{});
  if(validCurrency(stored[currencyKey]))clean.settings.currency=stored[currencyKey];
  // Old builds could carry deprecated secret-bearing fields forward through
  // object spreading. Persist only the explicit public allow-list.
  if (walletState && ("wallets" in walletState || "secret" in walletState)) {
    await chrome.storage.local.set({ walletState: clean });
  }
  return clean;
}

export async function saveState(state: WalletState) {
  const stored=await chrome.storage.local.get(['walletState',currencyKey]),previous=stored.walletState;
  const current = sanitized(state);
  if(validCurrency(stored[currencyKey]))current.settings.currency=stored[currencyKey];
  else if(validCurrency(previous?.settings?.currency))current.settings.currency=previous.settings.currency;
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
