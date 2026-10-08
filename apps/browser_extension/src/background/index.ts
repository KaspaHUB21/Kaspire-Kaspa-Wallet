import { loadState, saveState } from "./state";
import { core } from "./core";
import {nftBrowse, nftOwned, nftOwnedCollections, nftMyListings, nftOperation, nftPublishPending} from "./nftMarket";
import {nexusConnected,nexusDisconnect,nexusRequest,nexusSetSession,nexusRestoreSession,validateNexusChallenge} from "./nexus";
import {configureDotkDeriver, resolveDotkName} from "./dotk";
import {
  marketNames,
  marketOffer,
  marketOffers,
  marketStatus,
  prepareMarketRequest,
  publishOffer,
  saveOffer,
  savedOffers,
  verifiedMarketCells,
  verifyPreparedMarket,
} from "./dotkMarket";
import {
  formatRocketTokenRaw,
  mergeRocketTransaction,
  rawRocketAmount,
  rocketActivity,
  rocketHolding,
  rocketHoldingRaw,
  rocketPlan,
  rocketPool,
  rocketQuote,
  rocketSigningRequest,
  rocketTokens,
  rocketWalletAssets,
  submitRocket,
  validateRocketFunds,
  type RocketToken,
} from "./kasparocket";
configureDotkDeriver(async request => JSON.parse((await core()).deriveDotkDeed(JSON.stringify(request))));
import {
  createPortableBackup,
  createVault,
  decryptPortableBackup,
  decryptVault,
  unlockVault,
  type EncryptedVault,
  type PortableBackup,
} from "./vault";
import {
  broadcast,
  broadcastKcc20,
  inscriptionAssets,
  kcc20History,
  kcc20TransferData,
  kronTransferData,
  marketPrice,
  networkDiagnostics,
  nftCollection,
  nftRarity,
  resolveWalletInput,
  spendingData,
  spendingDataForAddresses,
  tokenMarket,
  verifyKrc721Ownership,
  verifyWyrmCell,
  waitForUtxo,
  walletAssets,
  walletAssetCategory,
  walletBalance,
  walletBalanceForAddresses,
  walletCoreSnapshot,
  walletCoreSnapshotForAddresses,
  walletHistory,
  walletHistoryForAddresses,
  walletSnapshot,
} from "./api";
import {
  isProviderRequest,
  type KaspaNetwork,
  type ProviderMethod,
} from "../shared/protocol";
import { formatRawTokenAmount } from "../shared/tokenAmount";
import { kcc20 as kronKcc20, spend as kronSpend } from "@kronsdk/kron-sdk";
import { loadKaspa as loadKronKaspa } from "@kronsdk/kron-sdk/wasm";
import {
  erc20Data,
  evmConfig,
  evmHistory,
  evmRpc,
  evmSnapshot,
  evmTransactionFields,
  formatUnits,
  parseUnits,
  waitReceipt,
} from "./evm";

const safe = new Set<ProviderMethod>([
  "getAccounts",
  "getNetworkAccounts",
  "getNetwork",
  "eth_accounts",
  "eth_chainId",
  "disconnect",
]);
const l1ProviderMethods = new Set<ProviderMethod>([
  "getPublicKey",
  "signMessage",
  "sendKaspa",
  "sendKRC20",
  "sendKCC20",
  "mintCovenantWyrm",
  "actCovenantWyrm",
  "signPskt",
  "pushTx",
  "signPolicyTransaction",
  "transferKRC721",
  "transferKNS",
]);
const extensionVersion = chrome.runtime.getManifest().version;
const unlockProviderMethods = new Set<ProviderMethod>([
  "getPublicKey",
  "signMessage",
  "sendKaspa",
  "sendKRC20",
  "sendKCC20",
  "mintCovenantWyrm",
  "actCovenantWyrm",
  "signPskt",
  "signPolicyTransaction",
  "transferKRC721",
  "transferKNS",
  "eth_sendTransaction",
]);
let walletUiConnections = 0;
interface VaultWallet {
  id: string;
  name: string;
  type: "mnemonic" | "private";
  secret: string;
}
interface VaultPayload {
  version: 2;
  wallets: VaultWallet[];
  createdAt: number;
}
let sessionVault: VaultPayload | null = null;
let sessionPassword: string | null = null;
let lastActivity = 0;
let sessionGeneration = 0;
let nftContextRevision = 0;

function kasAccountEntries(state: Awaited<ReturnType<typeof loadState>>, requested?: string | null) {
  const selected = state.addresses.find((item) => item.address === (requested ?? state.selectedAddress));
  if (!selected) return [];
  if (selected.watchOnly || selected.path === "private-key" || selected.change !== 0 ||
      (selected.index !== 0 && selected.receiveRotation !== true)) return [selected];
  const members = state.addresses
    .filter((item) => !item.watchOnly && item.walletId === selected.walletId &&
      item.coinType === selected.coinType && item.account === selected.account &&
      item.change === 0 && (item.index === 0 || item.receiveRotation === true))
    .sort((left, right) => left.index - right.index);
  return members.some((item) => item.index === 0) ? members : [selected];
}

function kasAccountPrimary(state: Awaited<ReturnType<typeof loadState>>, requested?: string | null) {
  const entries = kasAccountEntries(state, requested);
  return entries.find((item) => item.index === 0) ?? entries[0];
}

function isProviderNetwork(network: KaspaNetwork) { return network === "kasplex" || network === "igra"; }

function kasAccountSigners(state: Awaited<ReturnType<typeof loadState>>, requested?: string | null) {
  const entries = kasAccountEntries(state, requested);
  return entries.length < 2 ? [] : entries.map((item) => ({
    address: item.address,
    derivationPath: item.path,
  }));
}
let offscreenCreation: Promise<void> | null = null;
// Secrets exist only in volatile extension memory while unlocked. Chrome
// session storage contains only the activity timestamp and an unguessable
// channel capability; the vault itself is encrypted by a non-exportable key
// owned by the offscreen document.
// Remove plaintext session data written by older builds and sanitize legacy state.
void chrome.storage.session.setAccessLevel({
  accessLevel: chrome.storage.AccessLevel.TRUSTED_CONTEXTS,
});
void chrome.storage.session.remove("unlockedVault");
void loadState();
const preparedEvmTransfers = new Map<string, { request: any; review: any; address: string; walletId: string; network: "kasplex" | "igra"; createdAt: number }>();
interface PreparedRocketSwap {
  address: string;
  walletId: string;
  token: RocketToken;
  side: "buy" | "sell";
  poolId: string;
  plan: any;
  requests: any[];
  reviews: any[];
  createdAt: number;
}
const preparedRocketSwaps = new Map<string, PreparedRocketSwap>();
interface ApprovalView {
  id: string;
  origin: string;
  title: string;
  description: string;
  details: string[];
  rawJson?: unknown;
  recoveryCode?: string;
  unlockOnly?: boolean;
}
const approvals = new Map<
  string,
  {
    view: ApprovalView;
    resolve: (approved: boolean) => void;
    timer: number;
    generation: number | null;
  }
>();
let inscriptionOperationInFlight = false;
async function runExclusiveInscription<T>(operation: () => Promise<T>): Promise<T> {
  if (inscriptionOperationInFlight)
    throw new Error("Another inscription transfer is already in progress.");
  const pending = (await chrome.storage.local.get("pendingInscription"))
    .pendingInscription;
  if (pending)
    throw new Error(
      "Complete or resume the pending asset reveal before starting another transfer.",
    );
  inscriptionOperationInFlight = true;
  try {
    return await operation();
  } finally {
    inscriptionOperationInFlight = false;
  }
}
interface PreparedAssetTransfer {
  type: "inscription" | "kcc20" | "kron";
  sender: string;
  operation: any;
  plan?: any;
  request: any;
  review: any;
  createdAt: number;
}

chrome.runtime.onInstalled.addListener(() =>
  chrome.alarms.create("auto-lock", { periodInMinutes: 1 }),
);
chrome.alarms.onAlarm.addListener(async ({ name }) => {
  if (name !== "auto-lock") return;
  await hydrateSession();
  const state = await loadState();
  await expireSessionIfNeeded(state);
});

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.kind === "approval") {
    const pending = approvals.get(String(message.id ?? ""));
    if (message.command === "get") {
      respond(
        pending
          ? { result: pending.view }
          : { error: { code: 4001, message: "Approval request expired." } },
      );
      return false;
    }
    if (message.command === "resolve" && pending) {
      void resolveApproval(pending.view.id, message.approved === true)
        .then(() => respond({ result: true }))
        .catch((error) => respond({ error: normalize(error) }));
      return true;
    }
  }
  if (message?.channel === "wallet") {
    void walletCommand(message)
      .then((result) => respond({ result }))
      .catch((error) => respond({ error: normalize(error) }));
    return true;
  }
  if (message?.kind !== "provider" || !isProviderRequest(message.request))
    return false;
  void handle(
    message.origin,
    message.request.method,
    message.request.params,
    sender,
  )
    .then((result) => respond({ result }))
    .catch((error) => respond({ error: normalize(error) }))
    .finally(() => {
      if (unlockProviderMethods.has(message.request.method))
        void lockImmediateSessionWithoutWalletUi();
    });
  return true;
});
chrome.runtime.onConnect.addListener((port) => {
  if (port.name === "wallet-ui-lifetime") {
    walletUiConnections += 1;
    port.onDisconnect.addListener(() => {
      walletUiConnections = Math.max(0, walletUiConnections - 1);
      void lockImmediateSessionWithoutWalletUi();
    });
    return;
  }
  if (port.name !== "wallet-operation") return;
  port.onMessage.addListener((message) => {
    if (message?.channel !== "wallet") return;
    const progress = (stage: string) => {
      try {
        port.postMessage({ progress: stage });
      } catch {}
    };
    void walletCommand(message, progress)
      .then((result) => port.postMessage({ result }))
      .catch((error) => port.postMessage({ error: normalize(error) }));
  });
});
async function walletCommand(
  message: { command: string; [key: string]: unknown },
  progress: (stage: string) => void = () => {},
) {
  await hydrateSession();
  const state = await loadState();
  await expireSessionIfNeeded(state);
  if (sessionVault && message.command !== 'nexusPoll') await touchSession();
  if (message.command === "storeUpdateStatus") {
    return new Promise<{
      installedVersion: string;
      status: "update_available" | "no_update" | "throttled" | "unavailable";
      availableVersion?: string;
    }>((resolve) => {
      chrome.runtime.requestUpdateCheck((result, details) => {
        const runtimeError = chrome.runtime.lastError;
        if (runtimeError) {
          resolve({ installedVersion: extensionVersion, status: "unavailable" });
          return;
        }
        resolve({
          installedVersion: extensionVersion,
          status: result,
          ...(details?.version ? { availableVersion: details.version } : {}),
        });
      });
    });
  }
  if (message.command === "status") {
    const stored = await chrome.storage.local.get([
      "encryptedVault",
      "pendingInscription",
    ]);
    return {
      ...state,
      locked: sessionVault === null,
      hasVault: Boolean(stored.encryptedVault),
      pendingInscription: stored.pendingInscription ?? null,
    };
  }
  if (message.command === "pendingApproval") {
    const pending = [...approvals.values()].find(
      (item) => item.view.origin === "Kaspire Wallet",
    );
    return pending?.view ?? null;
  }
  if (message.command === "resolveWalletApproval") {
    const id = String(message.id ?? "");
    const pending = approvals.get(id);
    if (!pending || pending.view.origin !== "Kaspire Wallet")
      throw new Error("Approval request expired.");
    await resolveApproval(id, message.approved === true);
    return true;
  }
  if (message.command === "mnemonicWordStatus")
    return JSON.parse(
      (await core()).mnemonicWordStatus(String(message.phrase ?? "")),
    );
  if (message.command === "receiveAccount") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    const entries = kasAccountEntries(state);
    const primary = kasAccountPrimary(state);
    if (!primary) throw new Error("No wallet is selected.");
    const wallet = sessionVault?.wallets.find((item) => item.id === primary.walletId);
    const activity = await Promise.all(entries.map(async (item) => {
      if (item.used === true) return { used: true, known: true };
      try {
        return {
          used: (await walletHistory(item.address, state.network)).length > 0,
          known: true,
        };
      } catch {
        return { used: false, known: false };
      }
    }));
    let changed = false;
    entries.forEach((item, index) => {
      if (activity[index]?.used && item.used !== true) {
        item.used = true;
        changed = true;
      }
    });
    if (changed) await saveState(state);
    return {
      primaryAddress: primary.address,
      addresses: entries.map((item, index) => ({
        address: item.address,
        name: item.name,
        path: item.path,
        index: item.index,
        used: item.used === true,
        usageKnown: activity[index]?.known === true,
        receiveRotation: item.receiveRotation === true,
      })),
      canRotate: !primary.watchOnly && wallet?.type === "mnemonic" && !isProviderNetwork(state.network),
    };
  }
  if (message.command === "rotateReceiveAddress") {
    if (!sessionVault || !state.selectedAddress) throw new Error("Unlock a signing wallet first.");
    if (state.network === "kasplex" || state.network === "igra")
      throw new Error("Receive-address rotation is available for Kaspa Layer 1 and TN10 only.");
    const primary = kasAccountPrimary(state);
    const wallet = sessionVault.wallets.find((item) => item.id === primary?.walletId);
    if (!primary || primary.watchOnly || wallet?.type !== "mnemonic" || primary.index !== 0 || primary.change !== 0)
      throw new Error("Select an HD wallet primary address to rotate receive addresses.");
    const accountRows = state.addresses
      .filter((item) => item.walletId === primary.walletId && item.coinType === primary.coinType &&
        item.account === primary.account && item.change === 0)
      .sort((left, right) => right.index - left.index);
    let trailingUnused = 0;
    for (const item of accountRows.slice(0, 20)) {
      const history = await walletHistory(item.address, state.network);
      if (history.length) break;
      trailingUnused += 1;
    }
    if (trailingUnused >= 20)
      throw new Error("The safe unused-address limit has been reached. Receive funds on an existing address before rotating again.");
    const nextIndex = Math.max(-1, ...accountRows.map((item) => item.index)) + 1;
    if (!Number.isSafeInteger(nextIndex) || nextIndex < 1 || nextIndex > 0x7fffffff)
      throw new Error("The next receive-address index is invalid.");
    if (!(await approve({
      origin: "Kaspire Wallet",
      title: "Generate a new receive address?",
      description: "The new address remains part of this KAS account. Balances, activity and spendable UTXOs stay combined.",
      details: [primary.name, `Address index: ${nextIndex}`, "KRC20, KRC721, KNS and KCC20 ownership remains address-specific."],
    }))) throw rpc(4001, "Receive-address rotation rejected.");
    const wasm = await core();
    const derived = JSON.parse(wasm.deriveAddressRange(
      wallet.secret, primary.coinType, primary.account, 0, nextIndex, 1,
    ))[0];
    if (!derived || typeof derived.address !== "string" || typeof derived.derivationPath !== "string")
      throw new Error("Address derivation returned no receive address.");
    const address = wasm.addressWithPrefix(derived.address, state.network === "testnet-10");
    if (state.addresses.some((item) => item.address.toLowerCase() === address.toLowerCase()))
      throw new Error("The derived receive address already exists.");
    state.addresses.push({
      address, name: primary.name, path: derived.derivationPath, watchOnly: false,
      walletId: primary.walletId, coinType: primary.coinType, account: primary.account,
      change: 0, index: nextIndex, receiveRotation: true, used: false,
    });
    await saveState(state);
    return { address, path: derived.derivationPath, index: nextIndex };
  }
  if (message.command === "snapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") return evmWalletSnapshot(state);
    const entries = kasAccountEntries(state);
    const primary = kasAccountPrimary(state);
    if (!primary) throw new Error("No wallet is selected.");
    const [coreSnapshot, assets] = await Promise.all([
      walletCoreSnapshotForAddresses(entries.map((item) => item.address), state.network),
      walletAssets(primary.address, state.network),
    ]);
    return { ...coreSnapshot, assets, transactions: assets.transactions };
  }
  if (message.command === "coreSnapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    const entries = kasAccountEntries(state);
    return walletCoreSnapshotForAddresses(entries.map((item) => item.address), state.network);
  }
  if (message.command === "balanceSnapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") return evmWalletSnapshot(state);
    const entries = kasAccountEntries(state);
    return walletBalanceForAddresses(entries.map((item) => item.address), state.network);
  }
  if (message.command === "assetCategory") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "testnet-10" && String(message.category) === "kcc20")
      return rocketWalletAssets(state.selectedAddress);
    return walletAssetCategory(state.selectedAddress, state.network, String(message.category));
  }
  if (message.command === "resolveDotkName") {
    if (state.network !== "mainnet") throw new Error("dot.k is available on Layer 1 only.");
    const result = await resolveDotkName(String(message.name ?? ""));
    const fresh = await loadState();
    if (fresh.network !== state.network || fresh.selectedAddress !== state.selectedAddress) throw new Error("Account or network changed. Please retry.");
    return result;
  }
  if (String(message.command).startsWith('nexus')) {
    if(state.network!=='mainnet'||!state.selectedAddress||!sessionVault){nexusDisconnect();if(message.command==='nexusPoll')return {connected:false,notifications:[]};throw Error('Unlock a Kaspa mainnet wallet to use Nexus Offers.');}
    const address=state.selectedAddress,generation=sessionGeneration,revision=nftContextRevision;
    const context={address,generation,revision};
    const guard=async()=>{const fresh=await loadState();await expireSessionIfNeeded(fresh);if(!sessionVault||generation!==sessionGeneration||revision!==nftContextRevision||fresh.selectedAddress!==address||fresh.network!=='mainnet'){nexusDisconnect();throw Error('Wallet locked or account/network changed. Unlock and reconnect to Nexus.');}};
    await guard();await nexusRestoreSession(context);await guard();
    if(message.command==='nexusConnect'||message.command==='nexusPoll') {
      if(message.command==='nexusPoll'&&!nexusConnected(context)) {
        const entry=state.addresses.find(item=>item.address===address);
        if(!entry||entry.watchOnly)return {connected:false,notifications:[]};
      }
      if(!nexusConnected(context)) {
      const challenge=await nexusRequest(context,'auth/internal-challenge',{}, {walletAddress:address});
      const text=validateNexusChallenge(address,challenge);
      // Internal wallet feature, not a dApp connection. Only the exact,
      // purpose-separated internal challenge can reach this signing path.
      await guard();
      const wasm=await core();await guard();
      const entry=state.addresses.find(item=>item.address===address)!;
      const wallet=sessionVault!.wallets.find(item=>item.id===entry.walletId);
      if(entry.watchOnly||!wallet)throw Error('Selected wallet cannot sign a Nexus login message.');
      const signature=wasm.signPersonalMessage(signingSecret(wallet,entry),address,text);
      const publicKey=wasm.publicKey(signingSecret(wallet,entry));
      const result=await nexusRequest(context,'auth/internal-verify',{}, {walletAddress:address,nonce:challenge.nonce,signature,publicKey});
      await guard();nexusSetSession(context,result);
      }
      if(message.command==='nexusConnect')return {connected:true};
    }
    if(message.command==='nexusPoll') {
      if(!nexusConnected(context))return {connected:false,notifications:[]};
      const notifications=await nexusRequest(context,'dashboard/notifications');await guard();return {connected:true,notifications};
    }
    if(message.command==='nexusStatus')return {connected:nexusConnected(context)};
    if(message.command!=='nexusRequest')throw Error('Unknown Nexus command.');
    await guard();
    const result=await nexusRequest(context,String(message.path),message.query as Record<string,string>??{},message.body as Record<string,unknown>|undefined);
    await guard();return result;
  }
  if (String(message.command).startsWith("nftMarket")) {
    if (state.network !== "mainnet" || !state.selectedAddress) throw new Error("NFT Market is available on Kaspa Layer 1 only.");
    const address = state.selectedAddress;
    if (message.command === "nftMarketBrowse") return nftBrowse(message.params as Record<string, any>);
    if (message.command === "nftMarketOwned") return nftOwned(address, String(message.cursor ?? ""), String(message.collection ?? ""));
    if (message.command === "nftMarketCollections") return nftOwnedCollections(address);
    if (message.command === "nftMarketListings") return nftMyListings(address);
    if (message.command === "nftMarketPublishPending") { await nftPublishPending(address); return true; }
    if (message.command !== "nftMarketOperation") throw new Error("Unknown NFT marketplace command.");
    const generation = sessionGeneration;
    const contextRevision = nftContextRevision;
    const guard = async () => {
      await hydrateSession();
      const fresh = await loadState();
      if (!sessionVault || generation !== sessionGeneration) throw new Error("Wallet locked. Unlock and review again.");
      if (fresh.network !== "mainnet" || fresh.selectedAddress !== address || contextRevision !== nftContextRevision) throw new Error("Account or network changed. Reopen NFT Market and review again.");
      const entry = fresh.addresses.find(item => item.address === address);
      if (!entry || entry.watchOnly || !sessionVault.wallets.some(item => item.id === entry.walletId)) throw new Error("Select an unlocked signing wallet.");
    };
    await guard();
    return nftOperation({address, guard,
      approve: (title, details, rawJson) => approve({origin:"Kaspire Wallet",title,description:"Verify the NFT transaction reconstructed by the Rust security core.",details,rawJson}),
      sign: async (kind, request, hash) => {
        const wasm = await core(); await guard();
        if (!sessionVault || generation !== sessionGeneration || contextRevision !== nftContextRevision) throw new Error("Signing context changed. Unlock and review again.");
        const entry = state.addresses.find(item => item.address === address)!;
        const wallet = sessionVault!.wallets.find(item => item.id === entry.walletId)!;
        return JSON.parse(wasm[`sign${kind}`](signingSecret(wallet,entry),JSON.stringify(request),hash));
      },
    },message);
  }
  if (message.command === "dotkMarketOffers") {
    if (state.network !== "mainnet") throw new Error("K-Agora is available on Layer 1 only.");
    return marketOffers(String(message.query ?? ""));
  }
  if (message.command === "dotkMarketNames") {
    if (state.network !== "mainnet" || !state.selectedAddress) throw new Error("K-Agora is available on Layer 1 only.");
    return marketNames(state.selectedAddress);
  }
  if (message.command === "dotkMarketSaved") {
    if (!state.selectedAddress) throw new Error("Select a wallet first.");
    return savedOffers(state.selectedAddress);
  }
  if (message.command === "dotkMarketStatus") {
    if (state.network !== "mainnet") throw new Error("K-Agora is available on Layer 1 only.");
    return marketStatus(marketOffer(message.offer));
  }
  if (message.command === "dotkMarketSave") {
    if (!state.selectedAddress) throw new Error("Select a wallet first.");
    const offer = marketOffer(message.offer);
    if (offer.terms.seller !== state.selectedAddress) throw new Error("Select the selling wallet before restoring this listing.");
    await verifiedMarketCells(offer);
    await verifiedMarketCells(offer);
    return saveOffer(offer);
  }
  if (message.command === "dotkMarketPublish") {
    const offer = marketOffer(message.offer);
    if (offer.terms.seller !== state.selectedAddress) throw new Error("Select the selling wallet first.");
    await publishOffer(offer);
    return true;
  }
  if (message.command === "dotkMarketRemember") {
    if (!state.selectedAddress) throw new Error("Select a wallet first.");
    const offer = marketOffer(message.offer);
    if (offer.terms.seller !== state.selectedAddress) throw new Error("Listing belongs to another wallet.");
    await saveOffer(offer);
    return true;
  }
  if (message.command === "prepareDotkMarket") {
    if (!sessionVault || !state.selectedAddress || state.network !== "mainnet") throw new Error("Unlock a Layer 1 signing wallet first.");
    const entry = state.addresses.find((item) => item.address === state.selectedAddress);
    const wallet = sessionVault.wallets.find((item) => item.id === entry?.walletId);
    if (!entry || entry.watchOnly || !wallet) throw new Error("A signing wallet is required. Watch wallets cannot list or buy.");
    const action = String(message.action ?? "") as "list" | "buy" | "cancel";
    if (!["list", "buy", "cancel"].includes(action)) throw new Error("Invalid marketplace action.");
    const spending = await spendingData(entry.address, "mainnet");
    let input: any;
    if (action === "list") {
      const priceSompi = Number(message.priceSompi);
      if (!Number.isSafeInteger(priceSompi) || priceSompi < 1_000_000_000 || priceSompi > 9_000_000_000_000_000)
        throw new Error("Marketplace price must be between 10 and 90,000,000 KAS.");
      input = { name: String(message.name ?? ""), priceSompi,
        feeAddress: await resolveWalletInput("hub21.kas", "mainnet") };
    } else input = { offer: marketOffer(message.offer) };
    const prepared = await prepareMarketRequest(action, entry.address, input, spending.feeRate, spending.utxosJson);
    const fresh = await loadState();
    if (fresh.network !== "mainnet" || fresh.selectedAddress !== entry.address) throw new Error("Account or network changed. Please retry.");
    return prepared;
  }
  if (message.command === "submitDotkMarket") {
    if (!sessionVault || !state.selectedAddress || state.network !== "mainnet") throw new Error("Unlock a Layer 1 signing wallet first.");
    const entry = state.addresses.find((item) => item.address === state.selectedAddress);
    const wallet = sessionVault.wallets.find((item) => item.id === entry?.walletId);
    if (!entry || entry.watchOnly || !wallet) throw new Error("Selected wallet cannot sign.");
    const request = message.request as any, review = message.review as any;
    if (request?.sender !== entry.address || !["list", "buy", "cancel"].includes(request?.action) ||
        typeof review?.reviewHash !== "string") throw new Error("Invalid marketplace approval request.");
    await verifyPreparedMarket(review);
    const details = [
      `Name: ${review.name}.k`,
      ...(request.action === "list" || request.action === "buy" ? [`Gross price: ${formatSompi(review.priceSompi)} KAS`] : []),
      ...(request.action === "buy" ? [`Seller proceeds: ${formatSompi(review.sellerNetSompi)} KAS`, `Marketplace fee: ${formatSompi(review.marketplaceFeeSompi)} KAS`] : []),
      `Network fee: ${formatSompi(review.feeSompi)} KAS`,
      `Covenant ID: ${review.covenantId}`,
    ];
    if (!(await approve({ origin: "Kaspire Wallet", title: `Approve dot.k ${request.action}?`,
      description: "Verify the covenant transaction reconstructed by the Rust security core.", details,
      rawJson: { request, review } }))) throw rpc(4001, "Marketplace transaction rejected.");
    const fresh = await loadState();
    if (fresh.network !== "mainnet" || fresh.selectedAddress !== entry.address) throw new Error("Account or network changed. Please retry.");
    const wasm = await core();
    const signed = JSON.parse(wasm.signDotkMarket(signingSecret(wallet, entry), JSON.stringify(request), review.reviewHash));
    let offer: any = null;
    if (request.action === "list") {
      offer = marketOffer({ terms: request.terms, listingTxId: signed.transactionId, saleId: review.covenantId });
      await saveOffer(offer);
      if (!(await approve({ origin: "Kaspire Wallet", title: "Save listing recovery code",
        description: "Keep this public code with your wallet backup. It contains no private key. The name is not locked until you approve submission.",
        details: ["Copy the complete recovery code before continuing."], rawJson: offer,
        recoveryCode: JSON.stringify(offer) })))
        throw rpc(4001, "Listing submission cancelled. The signed transaction was not broadcast.");
    }
    await broadcastKcc20(signed.wrpcJson, signed.transactionId);
    let published = request.action !== "list";
    if (offer) {
      for (let attempt = 0; attempt < 3; attempt++) {
        try { await publishOffer(offer); published = true; break; }
        catch { if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 2000)); }
      }
    }
    return { transactionId: signed.transactionId, action: request.action, published, offer, review };
  }
  if (message.command === "assetsSnapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") return evmWalletSnapshot(state);
    const assets = await walletAssets(state.selectedAddress, state.network);
    await chrome.storage.session.set({
      assetReviewSnapshot: {
        address: state.selectedAddress,
        network: state.network,
        assets,
        loadedAt: Date.now(),
      },
    });
    return assets;
  }
  if (message.command === "networkDiagnostics") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") {
      const config = evmConfig(state.network), started = Date.now();
      try { await evmRpc(state.network, "eth_chainId"); return [{ name: config.name, url: config.rpc, ok: true, detail: `Chain ${config.chainId}`, elapsedMs: Date.now() - started }]; }
      catch (error) { return [{ name: config.name, url: config.rpc, ok: false, detail: (error as Error).message, elapsedMs: Date.now() - started }]; }
    }
    return networkDiagnostics(state.selectedAddress, state.network);
  }
  if (message.command === "history") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") {
      const { address } = await evmContext(state);
      return evmHistory(state.network, address);
    }
    const primary = kasAccountPrimary(state);
    const entries = kasAccountEntries(state);
    if (!primary) throw new Error("No wallet is selected.");
    return activityHistory(primary.address, state.network, entries.map((item) => item.address));
  }
  if (message.command === "market") {
    return state.network === "mainnet"
      ? marketPrice(state.settings.currency)
      : null;
  }
  if (message.command === "evmAddress") return (await evmContext(state)).address;
  if (message.command === "prepareEvmTransfer") {
    if (state.network !== "kasplex" && state.network !== "igra") throw new Error("Select Kasplex or Igra first.");
    const { address } = await evmContext(state);
    const recipient = String(message.recipient ?? "").trim();
    if (!/^0x[0-9a-fA-F]{40}$/.test(recipient)) throw new Error("Enter a valid EVM address.");
    const token = message.token as any;
    const decimals = token ? Number(token.decimals ?? 18) : 18;
    const requestedAmountText = String(message.amount ?? "").trim();
    let amountText = requestedAmountText;
    let amount = parseUnits(amountText, decimals);
    if (amount <= 0n) throw new Error("Enter an amount greater than zero.");
    const config = evmConfig(state.network);
    const to = token ? String(token.contract) : recipient;
    if (token && !/^0x[0-9a-fA-F]{40}$/.test(to)) throw new Error("Invalid token contract.");
    let data = token ? erc20Data(recipient, amount) : "";
    let value = token ? 0n : amount;
    let fields = await evmTransactionFields(state.network, address, to, value, data);
    const balance = BigInt(String(await evmRpc(state.network, "eth_getBalance", [address, "latest"])).replace(/^0x/, "0x"));
    let fee = fields.gas * fields.gasPrice;
    if (!token && message.sendAll === true) {
      if (balance <= fee) throw new Error(`Insufficient ${config.nativeSymbol} for the network fee.`);
      amount = balance - fee;
      amountText = formatUnits(amount, 18, 18);
      value = amount;
      fields = await evmTransactionFields(state.network, address, to, value, data);
      fee = fields.gas * fields.gasPrice;
      if (balance <= fee) throw new Error(`Insufficient ${config.nativeSymbol} for the network fee.`);
      amount = balance - fee;
      amountText = formatUnits(amount, 18, 18);
      value = amount;
    }
    if (balance < value + fee) throw new Error(`Insufficient ${config.nativeSymbol} for amount and network fee.`);
    if (token) {
      const balanceCall = `0x70a08231${address.slice(2).padStart(64, "0")}`;
      const tokenBalance = BigInt(String(await evmRpc(state.network, "eth_call", [{ to, data: balanceCall }, "latest"])).replace(/^0x/, "0x"));
      if (tokenBalance < amount) throw new Error(`Insufficient ${String(token.symbol).toUpperCase()} balance.`);
    }
    const request = { walletAddress: state.selectedAddress, from: address, to, recipient, valueWei: value.toString(), nonce: Number(fields.nonce), gasLimit: Number(fields.gas), gasPriceWei: fields.gasPrice.toString(), chainId: config.chainId, data, tokenSymbol: token ? String(token.symbol).toUpperCase() : config.nativeSymbol, displayAmount: amountText };
    const wasm = await core();
    const review = JSON.parse(wasm.prepareEvmTransaction(JSON.stringify(request)));
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    if (!entry || entry.watchOnly)
      throw new Error("Select a signing wallet for Layer 2.");
    const id = crypto.randomUUID();
    preparedEvmTransfers.set(id, {
      request,
      review,
      address,
      walletId: entry.walletId,
      network: state.network,
      createdAt: Date.now(),
    });
    return { id, review, fee: formatUnits(fee, 18, 18), nativeSymbol: config.nativeSymbol, rawJson: request };
  }
  if (message.command === "submitEvmTransfer") {
    const id = String(message.id ?? ""), prepared = preparedEvmTransfers.get(id);
    if (!prepared || Date.now() - prepared.createdAt > 10 * 60_000) throw new Error("Secure EVM review expired. Review the transfer again.");
    preparedEvmTransfers.delete(id);
    const config = evmConfig(state.network);
    if (!(await approve({ origin: "Kaspire Wallet", title: `Send ${prepared.review.tokenSymbol}`, description: "Review this L2 transaction before signing.", details: [`Network: ${prepared.review.network}`, `Recipient: ${prepared.review.recipient}`, `Amount: ${prepared.review.displayAmount} ${prepared.review.tokenSymbol}`, `Network fee: ${formatUnits(BigInt(prepared.request.gasPriceWei) * BigInt(prepared.request.gasLimit), 18, 18)} ${config.nativeSymbol}`], rawJson: prepared.request }))) throw rpc(4001, "User rejected the transaction.");
    await hydrateSession();
    const fresh = await loadState();
    const entry = fresh.addresses.find(
      (item) => item.address === fresh.selectedAddress,
    );
    if (
      !sessionVault ||
      fresh.network !== prepared.network ||
      fresh.selectedAddress !== prepared.request.walletAddress ||
      !entry ||
      entry.watchOnly ||
      entry.walletId !== prepared.walletId
    )
      throw new Error("Account or network changed. Review the transfer again.");
    const context = await evmContext(fresh);
    if (context.address.toLowerCase() !== prepared.address.toLowerCase())
      throw new Error("Signing account changed. Review the transfer again.");
    const signed = JSON.parse((await core()).signEvmTransaction(context.secret, JSON.stringify(prepared.request), prepared.review.reviewHash));
    const result = String(await evmRpc(state.network, "eth_sendRawTransaction", [signed.rawTransaction]));
    if (result.toLowerCase() !== String(signed.transactionHash).toLowerCase()) throw new Error("L2 broadcaster returned a mismatching transaction ID.");
    const receipt = await waitReceipt(state.network, result);
    return { transactionId: result, receipt, review: prepared.review, rawJson: prepared.request };
  }
  if (message.command === "tokenMarket")
    return tokenMarket(
      String(message.tokenId ?? ""),
      String(message.symbol ?? ""),
    );
  if (message.command === "rocketTokens") {
    if (state.network !== "testnet-10")
      throw new Error("KaspaRocket swaps are available on TN10 only.");
    return rocketTokens();
  }
  if (message.command === "rocketActivity") {
    if (state.network !== "testnet-10" || !state.selectedAddress)
      throw new Error("Select a TN10 wallet first.");
    return rocketActivity(state.selectedAddress);
  }
  if (message.command === "rocketTokenContext") {
    if (state.network !== "testnet-10" || !state.selectedAddress)
      throw new Error("Select a TN10 wallet first.");
    const tokenId = String(message.tokenId ?? "");
    const [poolId, holding, balance] = await Promise.all([
      rocketPool(tokenId),
      rocketHolding(state.selectedAddress, tokenId),
      walletBalance(state.selectedAddress, state.network),
    ]);
    const holdingRaw = rocketHoldingRaw(holding);
    return {
      poolId,
      holding,
      holdingRaw: holdingRaw.toString(),
      holdingDisplay: formatRocketTokenRaw(holdingRaw),
      balanceSompi: String(balance.balanceSompi),
      balanceKas: balance.balanceKas,
    };
  }
  if (message.command === "rocketQuote") {
    if (state.network !== "testnet-10")
      throw new Error("KaspaRocket swaps are available on TN10 only.");
    const side = String(message.side) as "buy" | "sell";
    if (!["buy", "sell"].includes(side))
      throw new Error("Invalid swap direction.");
    const rawAmount = rawRocketAmount(
      String(message.amount ?? ""),
      side === "buy" ? 8 : 3,
    );
    if (!state.selectedAddress)
      throw new Error("Select a TN10 wallet first.");
    const tokenId = String(message.tokenId ?? "");
    const [holding, balance] = await Promise.all([
      rocketHolding(state.selectedAddress, tokenId),
      walletBalance(state.selectedAddress, state.network),
    ]);
    validateRocketFunds(
      side,
      rawAmount,
      holding,
      balance.balanceSompi,
      undefined,
      String(message.ticker ?? "token"),
    );
    const quote = await rocketQuote(
      tokenId,
      String(message.poolId ?? ""),
      side,
      rawAmount,
    );
    validateRocketFunds(
      side,
      rawAmount,
      holding,
      balance.balanceSompi,
      quote,
      String(message.ticker ?? "token"),
    );
    return quote;
  }
  if (message.command === "prepareRocketSwap") {
    if (
      !sessionVault ||
      state.network !== "testnet-10" ||
      !state.selectedAddress
    )
      throw new Error("Unlock a TN10 signing wallet first.");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw new Error("A signing wallet is required.");
    const token = message.token as RocketToken;
    if (
      !token ||
      !/^[0-9a-f]{64}$/i.test(String(token.tokenId)) ||
      !String(token.ticker)
    )
      throw new Error("Invalid KaspaRocket token.");
    const side = String(message.side) as "buy" | "sell";
    if (!["buy", "sell"].includes(side))
      throw new Error("Invalid swap direction.");
    const rawAmount = rawRocketAmount(
      String(message.amount ?? ""),
      side === "buy" ? 8 : 3,
    );
    const [poolId, holding, balance] = await Promise.all([
      rocketPool(token.tokenId),
      rocketHolding(entry.address, token.tokenId),
      walletBalance(entry.address, state.network),
    ]);
    validateRocketFunds(
      side,
      rawAmount,
      holding,
      balance.balanceSompi,
      undefined,
      token.ticker,
    );
    const quote = await rocketQuote(
      token.tokenId,
      poolId,
      side,
      rawAmount,
    );
    validateRocketFunds(
      side,
      rawAmount,
      holding,
      balance.balanceSompi,
      quote,
      token.ticker,
    );
    if (quote?.uneconomic === true)
      throw new Error("This trade is uneconomic after fees.");
    const plan = await rocketPlan(
      entry.address,
      token.tokenId,
      poolId,
      side,
      rawAmount,
    );
    const transactions = Array.isArray(plan?.transactions)
      ? plan.transactions
      : [];
    if (transactions.length < 1 || transactions.length > 8)
      throw new Error("KaspaRocket returned an invalid transaction plan.");
    const wasm = await core();
    const requests = transactions.map((planned: any) =>
      rocketSigningRequest(
        entry.address,
        token,
        poolId,
        side,
        plan.summary,
        planned,
      ),
    );
    const reviews = requests.map((request: any) =>
      JSON.parse(wasm.preparePskt(JSON.stringify(request))),
    );
    const id = crypto.randomUUID();
    preparedRocketSwaps.set(id, {
      address: entry.address,
      walletId: wallet.id,
      token,
      side,
      poolId,
      plan,
      requests,
      reviews,
      createdAt: Date.now(),
    });
    return {
      id,
      token,
      side,
      poolId,
      summary: plan.summary,
      reviews,
      transactionCount: transactions.length,
      rawPlan: plan,
    };
  }
  if (message.command === "submitRocketSwap") {
    const id = String(message.id ?? "");
    const prepared = preparedRocketSwaps.get(id);
    if (!prepared || Date.now() - prepared.createdAt > 10 * 60_000)
      throw new Error("Secure swap review expired. Review the swap again.");
    preparedRocketSwaps.delete(id);
    if (
      !sessionVault ||
      state.network !== "testnet-10" ||
      state.selectedAddress !== prepared.address
    )
      throw new Error("Account or network changed. Review the swap again.");
    const entry = state.addresses.find(
      (item) => item.address === prepared.address,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === prepared.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw new Error("The reviewed signing wallet is unavailable.");
    const summary = prepared.plan.summary ?? {};
    const fees = prepared.reviews.reduce(
      (total: bigint, review: any) =>
        total + BigInt(String(review.feeSompi ?? 0)),
      0n,
    );
    if (
      !(await approve({
        origin: "Kaspire Wallet",
        title: `${prepared.side.toUpperCase()} ${prepared.token.ticker}`,
        description:
          "Verify both covenant IDs before signing this TN10 DEX swap.",
        details: [
          `Token covenant: ${prepared.token.tokenId}`,
          `Pool covenant: ${prepared.poolId}`,
          ...prepared.reviews.flatMap((review: any, index: number) => [
            `Transaction ${index + 1}: ${review.transactionId}`,
            `Wallet input: ${formatSompi(review.walletInputSompi ?? 0)} KAS`,
            `Wallet output: ${formatSompi(review.walletOutputSompi ?? 0)} KAS`,
            `Wallet net: ${formatSignedSompi(review.walletNetSompi ?? 0)} KAS`,
            `Network fee: ${formatSompi(review.feeSompi ?? 0)} KAS`,
          ]),
        ],
        rawJson: prepared.plan,
      })))
      throw rpc(4001, "Swap rejected.");
    const fresh = await loadState();
    if (
      fresh.network !== "testnet-10" ||
      fresh.selectedAddress !== prepared.address
    )
      throw new Error("Account or network changed. Review the swap again.");
    const wasm = await core();
    const secret = signingSecret(wallet, entry);
    const signed = prepared.requests.map((request: any, index: number) => {
      const result = JSON.parse(
        wasm.signPskt(
          secret,
          JSON.stringify(request),
          prepared.reviews[index].reviewHash,
        ),
      );
      return mergeRocketTransaction(
        prepared.plan.transactions[index].tx,
        result.signedTxJson,
      );
    });
    const receipts = [];
    for (let index = 0; index < signed.length; index++)
      receipts.push(
        await submitRocket(
          signed[index],
          index === signed.length - 1 ? prepared.plan.order_row : undefined,
        ),
      );
    return { receipts, reviews: prepared.reviews, plan: prepared.plan };
  }

  if (message.command === "nftCollection") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    return nftCollection(
      state.selectedAddress,
      String(message.ticker ?? "").toUpperCase(),
      String(message.offset ?? ""),
    );
  }
  if (message.command === "nftRarity")
    return nftRarity(
      String(message.ticker ?? "").toUpperCase(),
      String(message.tokenId ?? ""),
    );
  if (message.command === "createPrivateKey") {
    const password = String(message.password ?? "");
    const wasm = await core();
    const material = JSON.parse(
      wasm.importPrivateKey(String(message.privateKey ?? "")),
    );
    const id = crypto.randomUUID();
    const name =
      String(message.name ?? "Imported key").trim() || "Imported key";
    sessionVault = {
      version: 2,
      wallets: [
        { id, name, type: "private", secret: `private:${material.privateKey}` },
      ],
      createdAt: Date.now(),
    };
    sessionPassword = password;
    await createVault(password, sessionVault);
    await rememberSession(sessionVault);
    state.selectedAddress = material.address;
    state.addresses = [
      {
        address: material.address,
        name,
        path: "private-key",
        watchOnly: false,
        walletId: id,
        coinType: 111111,
        account: 0,
        change: 0,
        index: 0,
      },
    ];
    state.locked = false;
    state.recoveryVerified = true;
    await saveState(state);
    return { state: { ...state, locked: false } };
  }
  if (message.command === "createWatch") {
    const password = String(message.password ?? "");
    if (password.length < 12)
      throw new Error("Use at least 12 characters for the wallet password.");
    const address = await resolveWalletInput(
      String(message.address ?? ""),
      state.network,
    );
    const name =
      String(message.name ?? "Watch wallet").trim() || "Watch wallet";
    sessionVault = { version: 2, wallets: [], createdAt: Date.now() };
    sessionPassword = password;
    await createVault(password, sessionVault);
    await rememberSession(sessionVault);
    const entry = {
      address,
      name,
      path: "watch-only",
      watchOnly: true,
      walletId: `watch:${address}`,
      coinType: 111111,
      account: 0,
      change: 0,
      index: 0,
    };
    state.selectedAddress = address;
    state.addresses = [entry];
    state.locked = false;
    state.recoveryVerified = true;
    await saveState(state);
    return entry;
  }
  if (message.command === "pendingRecovery") {
    if (state.recoveryVerified || !sessionVault)
      throw new Error("No recovery verification is pending.");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!wallet || wallet.type !== "mnemonic")
      throw new Error("Recovery wallet is unavailable.");
    return wallet.secret.startsWith("mnemonic-passphrase:")
      ? wallet.secret.split(":").slice(2).join(":")
      : wallet.secret.slice("mnemonic:".length);
  }
  if (message.command === "verifyRecovery") {
    if (state.recoveryVerified || !sessionVault)
      throw new Error("No recovery verification is pending.");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!wallet || wallet.type !== "mnemonic")
      throw new Error("Recovery wallet is unavailable.");
    const phrase = wallet.secret.startsWith("mnemonic-passphrase:")
      ? wallet.secret.split(":").slice(2).join(":")
      : wallet.secret.slice("mnemonic:".length);
    const words = phrase.split(" ");
    const checks = Array.isArray(message.checks) ? message.checks : [];
    if (
      checks.length !== 3 ||
      checks.some(
        (check: any) =>
          !Number.isInteger(check?.index) ||
          check.index < 0 ||
          check.index >= words.length ||
          String(check.word ?? "")
            .trim()
            .toLowerCase() !== words[check.index],
      )
    )
      throw new Error("One or more recovery words are incorrect.");
    state.recoveryVerified = true;
    await saveState(state);
    return true;
  }
  if (message.command === "cancelPendingRecovery") {
    if (state.recoveryVerified || !sessionVault)
      throw new Error("No wallet creation is pending.");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || !wallet || wallet.type !== "mnemonic")
      throw new Error("Pending recovery wallet is unavailable.");
    sessionVault.wallets = sessionVault.wallets.filter(
      (item) => item.id !== wallet.id,
    );
    state.addresses = state.addresses.filter(
      (item) => item.walletId !== wallet.id,
    );
    state.selectedAddress = state.addresses[0]?.address ?? null;
    state.recoveryVerified = true;
    if (state.addresses.length === 0) {
      sessionGeneration += 1;
      rejectApprovals();
      sessionVault = null;
      sessionPassword = null;
      await clearVolatileSession();
      await chrome.storage.local.remove("encryptedVault");
      await chrome.storage.session.remove(["unlockedVault", "lastActivity"]);
    } else {
      await persistVault();
    }
    await saveState(state);
    return true;
  }
  if (message.command === "create" || message.command === "import") {
    const password = String(message.password ?? "");
    const passphrase = String(message.passphrase ?? "");
    const wasm = await core();
    const material = JSON.parse(
      message.command === "create"
        ? wasm.generateWallet(passphrase)
        : wasm.importWallet(String(message.words ?? ""), passphrase),
    );
    const id = crypto.randomUUID();
    const passphraseHex = [...new TextEncoder().encode(passphrase)]
      .map((value) => value.toString(16).padStart(2, "0"))
      .join("");
    const secret = passphrase
      ? `mnemonic-passphrase:${passphraseHex}:${material.mnemonic}`
      : `mnemonic:${material.mnemonic}`;
    sessionVault = {
      version: 2,
      wallets: [{ id, name: "Wallet 1", type: "mnemonic", secret }],
      createdAt: Date.now(),
    };
    sessionPassword = password;
    await createVault(password, sessionVault);
    await rememberSession(sessionVault);
    state.selectedAddress = material.address;
    state.addresses = [
      {
        address: material.address,
        name: "Wallet 1",
        path: material.derivationPath,
        watchOnly: false,
        walletId: id,
        coinType: 111111,
        account: 0,
        change: 0,
        index: 0,
      },
    ];
    state.locked = false;
    state.recoveryVerified = message.command !== "create";
    await saveState(state);
    return {
      state: { ...state, locked: false },
      ...(message.command === "create"
        ? { recoveryPhrase: material.mnemonic }
        : {}),
    };
  }
  if (message.command === "unlock") {
    const password = String(message.password ?? "");
    const payload = (await unlockVault(password)) as unknown as VaultPayload;
    if (payload.version !== 2 || !Array.isArray(payload.wallets))
      throw new Error("Unsupported vault format.");
    sessionVault = payload;
    sessionPassword = password;
    await rememberSession(payload);
    return { ...state, locked: false };
  }
  if (message.command === "addAccount" || message.command === "addSubwallet") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    const current = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    if (!current || current.watchOnly)
      throw new Error("Select a signing wallet.");
    const wallet = sessionVault.wallets.find(
      (item) => item.id === current.walletId,
    );
    if (!wallet) throw new Error("Wallet key is unavailable.");
    const account =
      message.command === "addAccount"
        ? Math.max(
            -1,
            ...state.addresses
              .filter((item) => item.walletId === wallet.id)
              .map((item) => item.account),
          ) + 1
        : current.account;
    const index =
      message.command === "addSubwallet"
        ? Math.max(
            -1,
            ...state.addresses
              .filter(
                (item) =>
                  item.walletId === wallet.id && item.account === account,
              )
              .map((item) => item.index),
          ) + 1
        : 0;
    const wasm = await core();
    const derived = JSON.parse(
      wasm.deriveAddressRange(
        wallet.secret,
        current.coinType,
        account,
        0,
        index,
        1,
      ),
    )[0];
    const address = wasm.addressWithPrefix(
      derived.address,
      state.network === "testnet-10",
    );
    const entry = {
      address,
      name:
        message.command === "addAccount"
          ? `Account ${account}`
          : `Subwallet ${index}`,
      path: derived.derivationPath,
      watchOnly: false,
      walletId: wallet.id,
      coinType: current.coinType,
      account,
      change: 0,
      index,
    };
    state.addresses.push(entry);
    state.selectedAddress = entry.address;
    await saveState(state);
    return entry;
  }
  if (message.command === "addWatch") {
    let address = await resolveWalletInput(
      String(message.address ?? ""),
      state.network,
    );
    address = (await core()).addressWithPrefix(
      address,
      state.network === "testnet-10",
    );
    if (state.addresses.some((item) => item.address === address))
      throw new Error("This wallet is already in Kaspire.");
    const entry = {
      address,
      name: String(message.name ?? "Watch wallet").trim() || "Watch wallet",
      path: "watch-only",
      watchOnly: true,
      walletId: `watch:${address}`,
      coinType: 111111,
      account: 0,
      change: 0,
      index: 0,
    };
    state.addresses.push(entry);
    state.selectedAddress = address;
    await saveState(state);
    return entry;
  }
  if (message.command === "addPrivateKey") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    const password = String(message.password ?? "");
    if (!sessionPassword) {
      await unlockVault(password);
      sessionPassword = password;
    }
    const material = JSON.parse(
      (await core()).importPrivateKey(String(message.privateKey ?? "")),
    );
    const id = crypto.randomUUID();
    const wallet: VaultWallet = {
      id,
      name: String(message.name ?? "Imported key").trim() || "Imported key",
      type: "private",
      secret: `private:${material.privateKey}`,
    };
    sessionVault.wallets.push(wallet);
    const address =
      state.network === "testnet-10"
        ? (await core()).addressWithPrefix(material.address, true)
        : material.address;
    const entry = {
      address,
      name: wallet.name,
      path: "private-key",
      watchOnly: false,
      walletId: id,
      coinType: 111111,
      account: 0,
      change: 0,
      index: 0,
    };
    state.addresses.push(entry);
    state.selectedAddress = address;
    await persistVault();
    await saveState(state);
    return entry;
  }
  if (message.command === "addMnemonic") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    const password = String(message.password ?? "");
    if (!sessionPassword) {
      await unlockVault(password);
      sessionPassword = password;
    }
    const passphrase = String(message.passphrase ?? "");
    const wasm = await core();
    const material = JSON.parse(
      wasm.importWallet(String(message.words ?? ""), passphrase),
    );
    const address = wasm.addressWithPrefix(
      material.address,
      state.network === "testnet-10",
    );
    if (state.addresses.some((item) => item.address === address))
      throw new Error("This recovery wallet is already in Kaspire.");
    const id = crypto.randomUUID();
    const passphraseHex = [...new TextEncoder().encode(passphrase)]
      .map((value) => value.toString(16).padStart(2, "0"))
      .join("");
    const wallet: VaultWallet = {
      id,
      name:
        String(message.name ?? "Imported wallet").trim() || "Imported wallet",
      type: "mnemonic",
      secret: passphrase
        ? `mnemonic-passphrase:${passphraseHex}:${material.mnemonic}`
        : `mnemonic:${material.mnemonic}`,
    };
    sessionVault.wallets.push(wallet);
    const entry = {
      address,
      name: wallet.name,
      path: material.derivationPath,
      watchOnly: false,
      walletId: id,
      coinType: 111111,
      account: 0,
      change: 0,
      index: 0,
    };
    state.addresses.push(entry);
    state.selectedAddress = address;
    await persistVault();
    await saveState(state);
    return entry;
  }
  if (message.command === "addGeneratedMnemonic") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    const password = String(message.password ?? "");
    if (!password) throw new Error("Enter the wallet password.");
    await unlockVault(password);
    sessionPassword = password;
    const wordCount = Number(message.wordCount ?? 24);
    if (wordCount !== 12 && wordCount !== 24)
      throw new Error("Choose either 12 or 24 recovery words.");
    const passphrase = String(message.passphrase ?? "");
    const wasm = await core();
    const material = JSON.parse(
      wasm.generateWalletWithWordCount(passphrase, wordCount),
    );
    const address = wasm.addressWithPrefix(
      material.address,
      state.network === "testnet-10",
    );
    if (state.addresses.some((item) => item.address === address))
      throw new Error("This recovery wallet is already in Kaspire.");
    const id = crypto.randomUUID();
    const passphraseHex = [...new TextEncoder().encode(passphrase)]
      .map((value) => value.toString(16).padStart(2, "0"))
      .join("");
    const name =
      String(message.name ?? "").trim() ||
      `Wallet ${sessionVault.wallets.length + 1}`;
    sessionVault.wallets.push({
      id,
      name,
      type: "mnemonic",
      secret: passphrase
        ? `mnemonic-passphrase:${passphraseHex}:${material.mnemonic}`
        : `mnemonic:${material.mnemonic}`,
    });
    state.addresses.push({
      address,
      name,
      path: material.derivationPath,
      watchOnly: false,
      walletId: id,
      coinType: 111111,
      account: 0,
      change: 0,
      index: 0,
    });
    state.selectedAddress = address;
    state.recoveryVerified = false;
    await persistVault();
    await saveState(state);
    return { address, recoveryPhrase: material.mnemonic };
  }
  if (message.command === "select") {
    const address = String(message.address ?? "");
    if (!state.addresses.some((item) => item.address === address))
      throw new Error("Unknown wallet address.");
    if (state.selectedAddress !== address) nftContextRevision += 1;
    state.selectedAddress = address;
    await saveState(state);
    return true;
  }
  if (message.command === "rename") {
    const entry = state.addresses.find(
      (item) =>
        item.address === String(message.address ?? state.selectedAddress ?? ""),
    );
    const name = String(message.name ?? "").trim();
    if (!entry || !name || name.length > 64)
      throw new Error("Invalid wallet name.");
    entry.name = name;
    await saveState(state);
    return true;
  }
  if (message.command === "renameReceiveAddress") {
    const entry = state.addresses.find(
      (item) => item.receiveRotation === true &&
        item.address === String(message.address ?? ""),
    );
    const name = String(message.name ?? "").trim();
    if (!entry || !name || name.length > 40 || /[\u0000-\u001f\u007f]/.test(name))
      throw new Error("Address name must contain 1 to 40 visible characters.");
    entry.name = name;
    await saveState(state);
    return true;
  }
  if (message.command === "removeAddress") {
    const address = String(message.address ?? state.selectedAddress ?? "");
    const entry = state.addresses.find((item) => item.address === address);
    if (!entry) throw new Error("Unknown wallet.");
    const removesSigningWallet =
      !entry.watchOnly &&
      (entry.path === "private-key" ||
        (entry.account === 0 && entry.change === 0 && entry.index === 0));
    state.addresses = removesSigningWallet
      ? state.addresses.filter((item) => item.walletId !== entry.walletId)
      : state.addresses.filter((item) => item.address !== address);
    state.selectedAddress = state.addresses[0]?.address ?? null;
    if (removesSigningWallet && sessionVault) {
      sessionVault.wallets = sessionVault.wallets.filter(
        (item) => item.id !== entry.walletId,
      );
    }
    if (state.addresses.length === 0) {
      sessionGeneration += 1;
      rejectApprovals();
      sessionVault = null;
      sessionPassword = null;
      await clearVolatileSession();
      await chrome.storage.local.remove("encryptedVault");
      await chrome.storage.session.remove(["unlockedVault", "lastActivity"]);
    } else if (removesSigningWallet) {
      await persistVault();
    }
    state.recoveryVerified = true;
    await saveState(state);
    return true;
  }
  if (message.command === "setNetwork") {
    const network = String(message.network ?? "");
    if (!["mainnet", "testnet-10", "kasplex", "igra"].includes(network))
      throw new Error("Unsupported network.");
    return convertNetwork(state, network as KaspaNetwork);
  }
  if (message.command === "setSettings") {
    const next = message.settings as any;
    if (next?.autoLockMinutes !== undefined) {
      const value = Number(next.autoLockMinutes);
      if (![-1, 0, 1, 5, 15, 30, 60].includes(value))
        throw new Error("Unsupported auto-lock duration.");
      state.settings.autoLockMinutes = value;
    }
    if (typeof next?.hideBalances === "boolean")
      state.settings.hideBalances = next.hideBalances;
    if (typeof next?.uppercase === "boolean")
      state.settings.uppercase = next.uppercase;
    if (typeof next?.showSubwallets === "boolean")
      state.settings.showSubwallets = next.showSubwallets;
    if (typeof next?.recipientAllowlist === "boolean")
      state.settings.recipientAllowlist = next.recipientAllowlist;
    if (
      [
        "USD",
        "EUR",
        "GBP",
        "AUD",
        "CAD",
        "JPY",
        "CNY",
        "CHF",
        "INR",
        "BRL",
        "KRW",
      ].includes(next?.currency)
    )
      state.settings.currency = next.currency;
    if (
      [
        "midnight",
        "emerald",
        "amethyst",
        "sakura",
        "crimson",
        "phoenix",
        "cypherpunk",
        "hub21",
        "glacier",
        "neptune",
      ].includes(next?.theme)
    )
      state.settings.theme = next.theme;
    await saveState(state);
    return state.settings;
  }
  if (message.command === "addContact") {
    const name = String(message.name ?? "").trim();
    let address = await resolveWalletInput(
      String(message.address ?? ""),
      state.network,
    );
    if (!name || name.length > 80) throw new Error("Invalid contact.");
    address = (await core()).addressWithPrefix(
      address,
      state.network === "testnet-10",
    );
    state.contacts.push({ id: crypto.randomUUID(), name, address });
    await saveState(state);
    return true;
  }
  if (message.command === "removeContact") {
    state.contacts = state.contacts.filter(
      (item) => item.id !== String(message.id ?? ""),
    );
    await saveState(state);
    return true;
  }
  if (message.command === "editContact") {
    const contact = state.contacts.find(
      (item) => item.id === String(message.id ?? ""),
    );
    const name = String(message.name ?? "").trim();
    let address = await resolveWalletInput(
      String(message.address ?? ""),
      state.network,
    );
    if (!contact || !name || name.length > 80)
      throw new Error("Invalid contact.");
    address = (await core()).addressWithPrefix(
      address,
      state.network === "testnet-10",
    );
    contact.name = name;
    contact.address = address;
    await saveState(state);
    return true;
  }
  if (message.command === "disconnectOrigin") {
    delete state.permissions[String(message.origin ?? "")];
    await saveState(state);
    return true;
  }
  if (message.command === "exportSecret") {
    if (!sessionVault || !state.selectedAddress)
      throw new Error("Unlock Kaspire first.");
    const password = String(message.password ?? "");
    await unlockVault(password);
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw new Error("Selected wallet has no exportable key.");
    if (
      !(await approve({
        origin: "Kaspire Wallet",
        title:
          message.type === "recovery"
            ? "Reveal recovery phrase?"
            : "Reveal private key?",
        description:
          "Anyone who sees this secret can take every asset controlled by it.",
        details: [entry.name, entry.path],
      }))
    )
      throw rpc(4001, "Secret export rejected.");
    if (message.type === "recovery") {
      if (wallet.type !== "mnemonic")
        throw new Error("This wallet was imported from a private key.");
      return wallet.secret.startsWith("mnemonic-passphrase:")
        ? wallet.secret.split(":").slice(2).join(":")
        : wallet.secret.slice("mnemonic:".length);
    }
    const wasm = await core();
    const secret = signingSecret(wallet, entry);
    return {
      walletName: entry.name,
      path: entry.path,
      kaspaPrivateKey: wasm.exportPrivateKey(secret),
      evmPrivateKey: wasm.exportEvmPrivateKey(secret),
    };
  }
  if (message.command === "sendKas") {
    if (!sessionVault || !state.selectedAddress)
      throw new Error("Unlock a signing wallet first.");
    const recipient = await resolveWalletInput(
      String(message.recipient ?? ""),
      state.network,
    );
    if (
      state.settings.recipientAllowlist &&
      !state.contacts.some((item) => item.address === recipient) &&
      !state.addresses.some((item) => item.address === recipient)
    )
      throw new Error("Recipient is not in your address book.");
    const sendAll = message.sendAll === true;
    const amount = sendAll ? 0 : Number(message.amountSompi);
    if ((!sendAll && (!Number.isSafeInteger(amount) || amount <= 0)))
      throw new Error("Invalid recipient or amount.");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw new Error("Selected wallet cannot sign.");
    const account = kasAccountEntries(state, entry.address);
    const primary = kasAccountPrimary(state, entry.address) ?? entry;
    const signers = kasAccountSigners(state, entry.address);
    const spend = await spendingDataForAddresses(account.map((item) => item.address), state.network);
    const request = {
      sender: primary.address,
      recipient,
      amountSompi: amount,
      feeRate: spend.feeRate,
      utxosJson: spend.utxosJson,
      signers,
      sendAll,
    };
    const wasm = await core();
    const review = JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
    if (
      !(await approve({
        origin: "Kaspire Wallet",
        title: "Approve KAS payment?",
        description:
          "Verify the payment reconstructed by the Rust security core.",
        details: [
          `Send: ${review.amountSompi / 100_000_000} KAS`,
          `To: ${review.recipient}`,
          `Fee: ${formatSompi(review.feeSompi)} KAS`,
          `Change: ${review.changeSompi / 100_000_000} KAS`,
        ],
        rawJson: { request, review },
      }))
    )
      throw rpc(4001, "Payment rejected.");
    const signed = JSON.parse(
      wasm.signTransaction(
        kasTransactionSecret(wallet, primary, signers),
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    const id = await broadcast(signed.submitJson, state.network);
    if (id && id !== signed.transactionId)
      throw new Error("Node returned a mismatching transaction ID.");
    return { transactionId: signed.transactionId, amountSompi: review.amountSompi, feeSompi: review.feeSompi };
  }
  if (message.command === "compound") {
    if (!sessionVault || !state.selectedAddress)
      throw new Error("Unlock a signing wallet first.");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw new Error("Selected wallet cannot sign.");
    const account = kasAccountEntries(state, entry.address);
    const primary = kasAccountPrimary(state, entry.address) ?? entry;
    const signers = kasAccountSigners(state, entry.address);
    const spend = await spendingDataForAddresses(account.map((item) => item.address), state.network);
    const allUtxos = JSON.parse(spend.utxosJson) as Array<{
      utxoEntry?: { amount?: string | number };
    }>;
    const count = allUtxos.length;
    if (count < 2) throw new Error("This wallet has fewer than two UTXOs.");
    // The native transaction policy intentionally permits at most 80 inputs.
    // Select the largest spendable cells so wallets above that limit can still
    // reduce their UTXO count over one or more compound transactions.
    const selectedUtxos = allUtxos
      .slice()
      .sort((left, right) => {
        const leftAmount = BigInt(left.utxoEntry?.amount ?? 0);
        const rightAmount = BigInt(right.utxoEntry?.amount ?? 0);
        return leftAmount === rightAmount ? 0 : leftAmount > rightAmount ? -1 : 1;
      })
      .slice(0, 80);
    const request = {
      sender: primary.address,
      recipient: primary.address,
      amountSompi: 0,
      feeRate: spend.feeRate,
      utxosJson: JSON.stringify(selectedUtxos),
      signers,
      sendAll: true,
    };
    const wasm = await core();
    const review = JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
    if (
      !(await approve({
        origin: "Kaspire Wallet",
        title: "Compound wallet UTXOs?",
        description:
          "All spendable KAS will return to the same wallet as one output minus the network fee.",
        details: [
          `${review.inputCount} of ${count} UTXOs → ${review.outputCount} output`,
          `Returned: ${review.amountSompi / 100_000_000} KAS`,
          `Network fee: ${formatSompi(review.feeSompi)} KAS`,
        ],
      }))
    )
      throw rpc(4001, "UTXO compound rejected.");
    const signed = JSON.parse(
      wasm.signTransaction(
        kasTransactionSecret(wallet, primary, signers),
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    const id = await broadcast(signed.submitJson, state.network);
    if (id && id !== signed.transactionId)
      throw new Error("Node returned a mismatching transaction ID.");
    return signed.transactionId;
  }
  if (message.command === "resumeInscription") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    const pending = (await chrome.storage.local.get("pendingInscription"))
      .pendingInscription;
    if (!pending) throw new Error("No pending reveal exists.");
    if (inscriptionOperationInFlight)
      throw new Error("Another inscription transfer is already in progress.");
    inscriptionOperationInFlight = true;
    try {
      return await finishPendingInscription(
        "Kaspire Wallet",
        pending,
        state,
        sessionVault,
        progress,
      );
    } finally {
      inscriptionOperationInFlight = false;
    }
  }
  if (message.command === "prepareAsset") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    return prepareWalletAsset(message, state, progress);
  }
  if (message.command === "confirmPreparedAsset") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    return runExclusiveInscription(() =>
      confirmPreparedAsset(
        String(message.preparedId ?? ""),
        state,
        sessionVault!,
      ),
    );
  }
  if (message.command === "sendAsset") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    const kind = String(message.kind ?? "");
    const method: ProviderMethod =
      kind === "krc20"
        ? "sendKRC20"
        : kind === "krc721"
          ? "transferKRC721"
          : kind === "kns"
            ? "transferKNS"
            : kind === "kcc20"
              ? "sendKCC20"
              : (() => {
                  throw new Error("Unsupported asset kind.");
                })();
    const resolvedRecipient = await resolveWalletInput(
      String(message.to ?? ""),
      state.network,
    );
    if (
      state.settings.recipientAllowlist &&
      !state.contacts.some((item) => item.address === resolvedRecipient) &&
      !state.addresses.some((item) => item.address === resolvedRecipient)
    )
      throw new Error("Recipient is not in your address book.");
    const params = {
      to: resolvedRecipient,
      from: state.selectedAddress,
      ticker: message.ticker,
      amount: message.amount,
      tokenId: message.tokenId,
      assetId: message.assetId,
      covenantId: message.covenantId,
    };
    return method === "sendKCC20"
      ? kcc20Transfer("Kaspire Wallet", params, state, sessionVault)
      : inscriptionTransfer(
          "Kaspire Wallet",
          method,
          params,
          state,
          sessionVault,
        );
  }
  if (message.command === "exportBackup") {
    if (!sessionVault || !state.selectedAddress)
      throw new Error("Unlock a signing wallet first.");
    const password = String(message.password ?? "");
    const entry = state.addresses.find(
      (item) => item.address === state.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw new Error("Select a signing wallet to back up.");
    const wasm = await core(),
      primary =
        state.addresses.find(
          (item) =>
            item.walletId === wallet.id &&
            !item.watchOnly &&
            item.account === 0 &&
            item.change === 0 &&
            item.index === 0,
        ) ?? entry,
      mainAddress = wasm.addressWithPrefix(primary.address, false);
    const addresses = state.addresses
      .filter((item) => item.walletId === wallet.id && !item.watchOnly)
      .map((item) => ({
        address: wasm.addressWithPrefix(item.address, false),
        derivationPath: item.path,
        coinType: item.coinType,
        account: item.account,
        change: item.change,
        index: item.index,
        used: true,
        explicit: true,
        receiveRotation: item.receiveRotation === true,
      }));
    const backup = await createPortableBackup(password, {
      secret: wallet.secret,
      address: mainAddress,
      addresses,
      createdAt: Date.now(),
    });
    return JSON.stringify(backup);
  }
  if (message.command === "importBackup") {
    const password = String(message.password ?? "");
    const backupText = String(message.backup ?? "");
    if (new TextEncoder().encode(backupText).byteLength > 2 * 1024 * 1024)
      throw new Error("Backup is too large.");
    let backup: any;
    try {
      backup = JSON.parse(backupText);
    } catch {
      throw new Error("Backup is not valid JSON.");
    }
    if (backup?.format === "kaspire-extension-backup-v2") {
      if (
        backup?.vault?.version !== 2 ||
        !Array.isArray(backup?.state?.addresses)
      )
        throw new Error("Unsupported legacy Kaspire extension backup.");
      const payload = (await decryptVault(
        backup.vault as EncryptedVault,
        password,
      )) as unknown as VaultPayload;
      if (payload.version !== 2 || !Array.isArray(payload.wallets))
        throw new Error("Damaged Kaspire vault payload.");
      const wasm = await core();
      const addresses = [] as any[];
      for (const item of backup.state.addresses) {
        if (item?.watchOnly === true) continue;
        const wallet = payload.wallets.find(
          (candidate) => candidate.id === item?.walletId,
        );
        if (!wallet || typeof item?.address !== "string") continue;
        let verifiedAddress = "";
        let verifiedPath = String(item?.path ?? "");
        if (wallet.type === "private" && wallet.secret.startsWith("private:")) {
          const material = JSON.parse(
            wasm.importPrivateKey(wallet.secret.slice("private:".length)),
          );
          verifiedAddress = String(material.address ?? "");
          verifiedPath = String(material.derivationPath ?? verifiedPath);
        } else if (wallet.type === "mnemonic") {
          const coinType = Number(item?.coinType);
          const account = Number(item?.account);
          const change = Number(item?.change);
          const index = Number(item?.index);
          if (![coinType, account, change, index].every(Number.isInteger))
            throw new Error("Invalid legacy backup derivation metadata.");
          const derived = JSON.parse(
            wasm.deriveAddressRange(
              wallet.secret,
              coinType,
              account,
              change,
              index,
              1,
            ),
          )[0];
          verifiedAddress = String(derived?.address ?? "");
          verifiedPath = String(derived?.derivationPath ?? "");
        }
        const expected = wasm.addressWithPrefix(item.address, false).toLowerCase();
        const actual = wasm.addressWithPrefix(verifiedAddress, false).toLowerCase();
        if (!actual || actual !== expected ||
            (item?.path && verifiedPath !== String(item.path)))
          throw new Error("Legacy backup address verification failed.");
        addresses.push({
          ...item,
          address: actual,
          path: verifiedPath,
          walletId: wallet.id,
          watchOnly: false,
        });
      }
      if (!addresses.length)
        throw new Error("Backup contains no verified signing wallets.");
      sessionVault = payload;
      sessionPassword = password;
      await rememberSession(payload);
      await chrome.storage.local.set({ encryptedVault: backup.vault });
      state.addresses = addresses;
      state.selectedAddress = addresses.some(
        (item: any) => item.address === backup.state.selectedAddress,
      )
        ? backup.state.selectedAddress
        : addresses[0].address;
      state.locked = false;
      await saveState(state);
      return true;
    }
    const decoded = await decryptPortableBackup(
      backup as PortableBackup,
      password,
    );
    const secret = String(decoded?.secret ?? ""),
      expected = String(decoded?.address ?? "").toLowerCase();
    if (
      !secret.startsWith("mnemonic:") &&
      !secret.startsWith("mnemonic-passphrase:") &&
      !secret.startsWith("private:")
    )
      throw new Error("Damaged Kaspire backup secret.");
    const wasm = await core();
    const material = secret.startsWith("private:")
      ? JSON.parse(wasm.importPrivateKey(secret.slice(8)))
      : (() => {
          const raw = secret.startsWith("mnemonic:")
            ? { phrase: secret.slice(9), passphrase: "" }
            : (() => {
                const value = secret.slice("mnemonic-passphrase:".length),
                  separator = value.indexOf(":");
                if (separator < 0 || value.slice(0, separator).length % 2)
                  throw new Error("Damaged passphrase wallet backup.");
                const hex = value.slice(0, separator),
                  bytes = new Uint8Array(hex.length / 2);
                for (let i = 0; i < bytes.length; i++)
                  bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
                return {
                  phrase: value.slice(separator + 1),
                  passphrase: new TextDecoder().decode(bytes),
                };
              })();
          return JSON.parse(wasm.importWallet(raw.phrase, raw.passphrase));
        })();
    if (material.address.toLowerCase() !== expected)
      throw new Error("Backup address verification failed.");
    const id = crypto.randomUUID(),
      name = "Restored wallet",
      wallet: VaultWallet = {
        id,
        name,
        type: secret.startsWith("private:") ? "private" : "mnemonic",
        secret,
      };
    const source = Array.isArray(decoded?.addresses) ? decoded.addresses : [],
      addresses = [] as any[];
    if (wallet.type === "mnemonic")
      for (const item of source) {
        const path = String(item?.derivationPath ?? ""),
          coinType = Number(item?.coinType),
          account = Number(item?.account),
          change = Number(item?.change),
          index = Number(item?.index);
        if (
          !path.startsWith("m/") ||
          ![coinType, account, change, index].every(Number.isInteger)
        )
          throw new Error("Invalid HD address list in backup.");
        const derived = JSON.parse(
          wasm.deriveAddressRange(secret, coinType, account, change, index, 1),
        )[0];
        if (
          !derived ||
          String(derived.address).toLowerCase() !==
            String(item?.address ?? "").toLowerCase() ||
          derived.derivationPath !== path
        )
          throw new Error("HD address verification failed.");
        addresses.push({
          address: wasm.addressWithPrefix(
            derived.address,
            state.network === "testnet-10",
          ),
          name:
            index === 0 && account === 0
              ? name
              : `${account === 0 ? "Subwallet" : "Account"} ${index}`,
          path,
          watchOnly: false,
          walletId: id,
          coinType,
          account,
          change,
          index,
          receiveRotation: item?.receiveRotation === true,
        });
      }
    if (!addresses.length)
      addresses.push({
        address: wasm.addressWithPrefix(
          material.address,
          state.network === "testnet-10",
        ),
        name,
        path: material.derivationPath ?? "private-key",
        watchOnly: false,
        walletId: id,
        coinType: 111111,
        account: 0,
        change: 0,
        index: 0,
      });
    sessionVault = { version: 2, wallets: [wallet], createdAt: Date.now() };
    sessionPassword = password;
    await createVault(password, sessionVault);
    await rememberSession(sessionVault);
    state.addresses = addresses;
    state.selectedAddress = addresses[0]!.address;
    state.locked = false;
    state.recoveryVerified = true;
    await saveState(state);
    return true;
  }
  if (message.command === "lock") {
    await lockSession(state);
    return true;
  }
  throw rpc(-32601, "Unknown wallet command.");
}

async function evmContext(state: Awaited<ReturnType<typeof loadState>>) {
  if (!sessionVault) throw new Error("Unlock Kaspire first.");
  const entry = state.addresses.find((item) => item.address === state.selectedAddress);
  if (!entry || entry.watchOnly) throw new Error("Select a signing wallet for Layer 2.");
  const wallet = sessionVault.wallets.find((item) => item.id === entry.walletId);
  if (!wallet) throw new Error("Wallet key is unavailable.");
  const secret = signingSecret(wallet, entry);
  return { address: (await core()).deriveEvmAddress(secret), secret };
}

async function evmWalletSnapshot(state: Awaited<ReturnType<typeof loadState>>) {
  if (state.network !== "kasplex" && state.network !== "igra") throw new Error("Select an L2 network.");
  const { address } = await evmContext(state);
  return evmSnapshot(state.network, address);
}

async function persistVault() {
  if (!sessionVault) throw new Error("Unlock Kaspire first.");
  if (!sessionPassword) {
    sessionVault = null;
    await hydrateSession();
    throw new Error(
      "Lock and unlock Kaspire again before changing encrypted wallet keys.",
    );
  }
  await createVault(sessionPassword, sessionVault);
  await rememberSession();
}
async function ensureOffscreenSessionDocument() {
  if (await chrome.offscreen.hasDocument()) return;
  if (!offscreenCreation) {
    offscreenCreation = chrome.offscreen
      .createDocument({
        url: "session.html",
        reasons: [chrome.offscreen.Reason.WORKERS],
        justification:
          "Keep the timed wallet unlock key in volatile browser memory without persisting decrypted wallet secrets.",
      })
      .finally(() => {
        offscreenCreation = null;
      });
  }
  await offscreenCreation;
}

function newSessionChannelToken() {
  return [...crypto.getRandomValues(new Uint8Array(32))]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

async function storeVolatileSession() {
  if (!sessionVault || !sessionPassword || sessionGeneration <= 0)
    throw new Error("Cannot preserve a locked wallet session.");
  const stored = await chrome.storage.session.get("sessionChannelToken");
  const token =
    typeof stored.sessionChannelToken === "string" &&
    /^[0-9a-f]{64}$/.test(stored.sessionChannelToken)
      ? stored.sessionChannelToken
      : newSessionChannelToken();
  await chrome.storage.session.set({ sessionChannelToken: token });
  await ensureOffscreenSessionDocument();
  const response = await chrome.runtime.sendMessage({
    kind: "volatile-session",
    command: "store",
    token,
    generation: sessionGeneration,
    vault: sessionVault,
    password: sessionPassword,
  });
  if (!response?.ok)
    throw new Error(response?.error || "Unable to preserve the unlock session.");
}

async function restoreVolatileSession() {
  const stored = await chrome.storage.session.get([
    "sessionChannelToken",
    "lastActivity",
  ]);
  lastActivity = Number(stored.lastActivity) || 0;
  const token = stored.sessionChannelToken;
  if (
    typeof token !== "string" ||
    !/^[0-9a-f]{64}$/.test(token) ||
    !(await chrome.offscreen.hasDocument())
  )
    return null;
  const response = await chrome.runtime.sendMessage({
    kind: "volatile-session",
    command: "get",
    token,
  });
  const restored = response?.session;
  if (
    restored?.vault?.version !== 2 ||
    !Array.isArray(restored?.vault?.wallets) ||
    typeof restored?.password !== "string" ||
    !Number.isSafeInteger(restored?.generation) ||
    restored.generation <= 0
  )
    return null;
  return restored as {
    vault: VaultPayload;
    password: string;
    generation: number;
  };
}

async function clearVolatileSession() {
  const stored = await chrome.storage.session.get("sessionChannelToken");
  const token = stored.sessionChannelToken;
  if (await chrome.offscreen.hasDocument()) {
    if (typeof token === "string") {
      await chrome.runtime
        .sendMessage({
          kind: "volatile-session",
          command: "clear",
          token,
        })
        .catch(() => undefined);
    }
    await chrome.offscreen.closeDocument().catch(() => undefined);
  }
  await chrome.storage.session.remove("sessionChannelToken");
}

function rejectApprovals(boundOnly = false) {
  for (const [id, pending] of approvals) {
    if (boundOnly && pending.generation === null) continue;
    clearTimeout(pending.timer);
    approvals.delete(id);
    pending.resolve(false);
  }
}

async function resolveApproval(id: string, approved: boolean) {
  await hydrateSession();
  const pending = approvals.get(id);
  if (!pending) throw new Error("Approval request expired.");
  clearTimeout(pending.timer);
  approvals.delete(id);
  const validSession =
    pending.generation === null ||
    (sessionVault !== null && pending.generation === sessionGeneration);
  pending.resolve(approved && validSession);
}

async function lockSession(state: Awaited<ReturnType<typeof loadState>>) {
  nexusDisconnect();
  sessionGeneration += 1;
  rejectApprovals();
  preparedEvmTransfers.clear();
  preparedRocketSwaps.clear();
  sessionVault = null;
  sessionPassword = null;
  lastActivity = 0;
  await clearVolatileSession();
  await chrome.storage.session.remove([
    "unlockedVault",
    "lastActivity",
    "preparedAsset",
  ]);
  await saveState({ ...state, locked: true });
}

async function lockImmediateSessionWithoutWalletUi() {
  if (walletUiConnections > 0) return;
  await hydrateSession();
  if (!sessionVault) return;
  const state = await loadState();
  if (state.settings.autoLockMinutes === 0) await lockSession(state);
}

async function expireSessionIfNeeded(
  state: Awaited<ReturnType<typeof loadState>>,
) {
  if (
    !sessionVault ||
    state.settings.autoLockMinutes < 0 ||
    state.settings.autoLockMinutes === 0
  )
    return;
  const timeout = state.settings.autoLockMinutes * 60_000;
  if (!lastActivity || Date.now() - lastActivity >= timeout)
    await lockSession(state);
}

async function hydrateSession() {
  if (sessionVault) return;
  await chrome.storage.session.remove("unlockedVault");
  const restored = await restoreVolatileSession().catch(() => null);
  if (!restored) return;
  sessionVault = restored.vault;
  sessionPassword = restored.password;
  sessionGeneration = restored.generation;
}
async function rememberSession(payload?: VaultPayload) {
  if (payload) {
    sessionGeneration += 1;
    rejectApprovals(true);
  } else if (sessionGeneration <= 0) {
    sessionGeneration = 1;
  }
  lastActivity = Date.now();
  await chrome.storage.session.remove("unlockedVault");
  await chrome.storage.session.set({ lastActivity });
  await storeVolatileSession();
}
async function touchSession() {
  lastActivity = Date.now();
  await chrome.storage.session.set({ lastActivity });
}
function signingSecret(wallet: VaultWallet, entry: { path: string }) {
  return wallet.type === "mnemonic"
    ? `hd-path:${entry.path}:${wallet.secret}`
    : wallet.secret;
}
function kasTransactionSecret(
  wallet: VaultWallet,
  entry: { path: string },
  signers: Array<{ address: string; derivationPath: string }>,
) {
  return signers.length ? wallet.secret : signingSecret(wallet, entry);
}
async function convertNetwork(
  state: Awaited<ReturnType<typeof loadState>>,
  network: KaspaNetwork,
  preservePermissionOrigin?: string,
) {
  const previousNetwork = state.network;
  if (previousNetwork !== network) nftContextRevision += 1;
  const wasm = await core();
  const selectedIndex = state.addresses.findIndex(
    (item) => item.address === state.selectedAddress,
  );
  state.addresses = state.addresses.map((item) => ({
    ...item,
    address: wasm.addressWithPrefix(item.address, network === "testnet-10"),
  }));
  state.selectedAddress =
    (selectedIndex >= 0
      ? state.addresses[selectedIndex]?.address
      : state.addresses[0]?.address) ?? null;
  state.network = network;
  if (previousNetwork === "testnet-10" || network === "testnet-10") {
    const permission = preservePermissionOrigin
      ? state.permissions[preservePermissionOrigin]
      : undefined;
    state.permissions = permission
      ? {
          [preservePermissionOrigin!]: {
            ...permission,
            networks: [
              ...permissionNetworks(permission, previousNetwork).filter(
                (item) => item !== "mainnet" && item !== "testnet-10",
              ),
              network,
            ],
          },
        }
      : {};
  } else if (preservePermissionOrigin) {
    const permission = state.permissions[preservePermissionOrigin];
    if (permission) {
      state.permissions[preservePermissionOrigin] = {
        ...permission,
        networks: [...new Set([...permissionNetworks(permission, previousNetwork), network])],
      };
    }
  }
  await saveState(state);
  return { network, selectedAddress: state.selectedAddress };
}
async function activityHistory(
  address: string,
  network: KaspaNetwork,
  accountAddresses: string[] = [address],
) {
  const [node, assets, kcc, stored] = await Promise.all([
    walletHistoryForAddresses(accountAddresses, network),
    network === "mainnet"
      ? inscriptionAssets(address).catch(() => ({ transactions: [] }))
      : Promise.resolve({ transactions: [] }),
    network === "mainnet"
      ? kcc20History(address).catch(() => [])
      : Promise.resolve([]),
    chrome.storage.local.get("walletActivity"),
  ]);
  const token = (assets.transactions ?? []).map((item: any) => {
    const from = String(item?.from_wallet ?? item?.from ?? ""),
      to = String(item?.to_wallet ?? item?.to ?? ""),
      id = String(item?.token_id ?? item?.asset_id ?? ""),
      protocol = String(
        item?.asset_kind ?? item?.protocol ?? item?.standard ?? "",
      ).toLowerCase(),
      assetKind =
        protocol.includes("721") || id.startsWith("krc721-")
          ? "KRC-721"
          : protocol === "kns" || id.endsWith(".kas")
            ? "KNS"
            : "KRC-20";
    return {
      transactionId: String(
        item?.transaction_id ??
          item?.tx_id ??
          item?.reveal_tx_id ??
          item?.id ??
          "",
      ),
      blockTime:
        Date.parse(String(item?.timestamp ?? item?.created_at ?? "")) || 0,
      isAccepted: true,
      incoming: to === address,
      assetKind,
      assetSymbol: String(
        item?.token_symbol ?? item?.ticker ?? item?.domain_name ?? "ASSET",
      ).toUpperCase(),
      displayAmount: String(
        item?.amount ?? (assetKind === "KRC-721" ? "1" : ""),
      ),
      tokenId: String(
        item?.nft_token_id ?? item?.tokenId ?? item?.asset_id ?? "",
      ),
      counterparty: to === address ? from : to,
      from: from ? [{ address: from }] : [],
      to: to ? [{ address: to }] : [],
      feeSompi: null,
      totalInputSompi: null,
      totalOutputSompi: null,
      inputCount: null,
      outputCount: null,
      mass: null,
      payload: "",
      type: String(item?.type ?? "transfer"),
    };
  });
  const ownedAddresses = new Set(accountAddresses.map((item) => item.toLowerCase()));
  const local = (
    Array.isArray(stored.walletActivity) ? stored.walletActivity : []
  )
    .filter((item: any) => ownedAddresses.has(String(item?.wallet ?? "").toLowerCase()))
    .map((item: any) => item.transaction);
  const merged = new Map<string, any>();
  for (const item of [...local, ...node, ...token, ...kcc]) {
    const assetIdentity =
      item.assetKind === "KRC-20"
        ? item.assetSymbol
        : item.tokenId ?? item.assetSymbol ?? "";
    const key = `${item.transactionId}:${item.assetKind}:${assetIdentity}`;
    const previous = merged.get(key);
    merged.set(
      key,
      previous
        ? {
            ...item,
            ...previous,
            ...Object.fromEntries(
              Object.entries(item).filter(
                ([, value]) =>
                  value !== null &&
                  value !== "" &&
                  !(Array.isArray(value) && !value.length),
              ),
            ),
          }
        : item,
    );
  }
  return [...merged.values()]
    .sort((a: any, b: any) => b.blockTime - a.blockTime)
    .slice(0, 150);
}

async function recordWalletActivity(wallet: string, transaction: any) {
  const stored = await chrome.storage.local.get("walletActivity"),
    rows = Array.isArray(stored.walletActivity) ? stored.walletActivity : [];
  rows.unshift({ wallet, transaction });
  await chrome.storage.local.set({ walletActivity: rows.slice(0, 500) });
}

const connectableNetworks = ["mainnet", "testnet-10", "kasplex", "igra"] as const;
type ConnectableNetwork = (typeof connectableNetworks)[number];

function requestedConnectionNetworks(params: unknown): ConnectableNetwork[] {
  const raw = (params as { networks?: unknown } | null)?.networks;
  if (!Array.isArray(raw) || raw.length === 0)
    throw rpc(-32602, "Choose at least one supported network.");
  const networks = [...new Set(raw.map(String))];
  if (
    networks.length > connectableNetworks.length ||
    networks.some(
      (network) =>
        !connectableNetworks.includes(network as ConnectableNetwork),
    )
  )
    throw rpc(
      -32602,
      "Only Kaspa Mainnet, Testnet 10, Kasplex and Igra can be connected.",
    );
  return networks as ConnectableNetwork[];
}

function evmNetworkForChainId(value: unknown): "kasplex" | "igra" {
  const raw =
    typeof value === "object" && value !== null
      ? (value as { chainId?: unknown }).chainId
      : value;
  const normalized = String(raw ?? "").toLowerCase();
  if (normalized === "0x3173b" || normalized === "202555") return "kasplex";
  if (normalized === "0x97b1" || normalized === "38833") return "igra";
  throw rpc(4902, "Only Kasplex and Igra are supported Layer 2 networks.");
}

function permissionNetworks(
  permission: { networks?: KaspaNetwork[] } | undefined,
  fallback: KaspaNetwork,
): KaspaNetwork[] {
  return permission?.networks?.length ? permission.networks : [fallback];
}

async function accountsForNetworks(
  state: Awaited<ReturnType<typeof loadState>>,
  networks: readonly ConnectableNetwork[],
) {
  if (!state.selectedAddress) throw rpc(4100, "Create or import a wallet first.");
  const result: Partial<Record<ConnectableNetwork, string>> = {};
  if (networks.includes("mainnet"))
    result.mainnet = (await core()).addressWithPrefix(
      state.selectedAddress,
      false,
    );
  if (networks.includes("testnet-10"))
    result["testnet-10"] = (await core()).addressWithPrefix(
      state.selectedAddress,
      true,
    );
  if (networks.includes("kasplex") || networks.includes("igra")) {
    if (!sessionVault) throw rpc(4100, "Unlock Kaspire before connecting Layer 2.");
    const { address } = await evmContext(state);
    if (networks.includes("kasplex")) result.kasplex = address;
    if (networks.includes("igra")) result.igra = address;
  }
  return result;
}

async function kaspaProviderState(
  state: Awaited<ReturnType<typeof loadState>>,
  network: "mainnet" | "testnet-10",
) {
  const wasm = await core();
  const addresses = state.addresses.map((entry) => ({
    ...entry,
    address: wasm.addressWithPrefix(entry.address, network === "testnet-10"),
  }));
  const selectedIndex = state.addresses.findIndex(
    (entry) => entry.address === state.selectedAddress,
  );
  return {
    ...state,
    network,
    addresses,
    selectedAddress:
      (selectedIndex >= 0 ? addresses[selectedIndex]?.address : undefined) ??
      addresses[0]?.address ??
      null,
  };
}

async function assertFreshKaspaSigningContext(
  originalState: Awaited<ReturnType<typeof loadState>>,
  origin: string,
  expectedAddress: string,
  expectedNetwork: "mainnet" | "testnet-10",
) {
  const current = await loadState();
  const currentPermission = current.permissions[origin];
  const currentProvider = await kaspaProviderState(current, expectedNetwork);
  if (
    current.network !== originalState.network ||
    current.selectedAddress !== originalState.selectedAddress ||
    currentProvider.selectedAddress !== expectedAddress ||
    currentPermission?.accounts !== true ||
    !permissionNetworks(currentPermission, current.network).includes(expectedNetwork)
  )
    throw rpc(
      4100,
      "Wallet account or network changed during approval. Build a fresh request.",
    );
}

function connectionDetails(
  accounts: Partial<Record<ConnectableNetwork, string>>,
) {
  return connectableNetworks.flatMap((network) =>
    accounts[network]
      ? [
          `${network === "mainnet" ? "Kaspa Mainnet" : network === "testnet-10" ? "Kaspa Testnet 10" : network === "kasplex" ? "Kasplex L2" : "Igra L2"}: ${accounts[network]}`,
        ]
      : [],
  );
}

async function handle(
  origin: string,
  method: ProviderMethod,
  params: unknown,
  sender: chrome.runtime.MessageSender,
) {
  await hydrateSession();
  const senderOrigin = sender.url ? new URL(sender.url).origin : "";
  if (!/^https?:\/\//.test(origin) || senderOrigin !== origin)
    throw rpc(4100, "Untrusted request origin.");
  const state = await loadState();
  await expireSessionIfNeeded(state);
  let permission = state.permissions[origin];
  let permitted = permission?.accounts === true;
  if (method === "requestNetworkAccounts") {
    await hydrateSession();
    const networks = requestedConnectionNetworks(params);
    const accounts = await accountsForNetworks(state, networks);
    if (
      !(await approve({
        origin,
        title: "Connect dApp to multiple networks?",
        description:
          "Allow this site to view the selected Kaspa account on each listed network. Signing still requires a separate review.",
        details: connectionDetails(accounts),
      }))
    )
      throw rpc(4001, "Connection rejected.");
    permission = {
      accounts: true,
      connectedAt: Date.now(),
      networks,
      evmChainId: networks.includes("kasplex")
        ? evmConfig("kasplex").chainId
        : networks.includes("igra")
          ? evmConfig("igra").chainId
          : undefined,
    };
    state.permissions[origin] = permission;
    await saveState(state);
    return accounts;
  }
  if (method === "requestAccounts") {
    if (!state.selectedAddress)
      throw rpc(4100, "Create or import a wallet first.");
    if (
      !(await approve({
        origin,
        title: "Connect dApp?",
        description: "Allow this site to view your selected wallet address.",
        details: [state.network === "kasplex" || state.network === "igra" ? (sessionVault ? (await evmContext(state)).address : "Unlock to reveal the selected Layer 2 account") : state.selectedAddress],
      }))
    )
      throw rpc(4001, "Connection rejected.");
    await hydrateSession();
    if (!sessionVault)
      throw rpc(4100, "Unlock Kaspire before connecting.");
    state.permissions[origin] = {
      accounts: true,
      connectedAt: Date.now(),
      networks: [state.network],
      evmChainId:
        state.network === "kasplex" || state.network === "igra"
          ? evmConfig(state.network).chainId
          : undefined,
    };
    await saveState(state);
    return [state.network === "kasplex" || state.network === "igra" ? (await evmContext(state)).address : state.selectedAddress];
  }
  if (method === "eth_requestAccounts") {
    await hydrateSession();
    const first = Array.isArray(params) ? params[0] : params;
    const network = evmNetworkForChainId(
      (first as { chainId?: unknown } | null)?.chainId ??
        permission?.evmChainId ??
        (state.network === "igra" ? evmConfig("igra").chainId : evmConfig("kasplex").chainId),
    );
    const existing = permissionNetworks(permission, state.network);
    const networks = [...new Set([...existing.filter((item) => item !== "testnet-10"), network])] as KaspaNetwork[];
    const accounts = await accountsForNetworks(state, [network]);
    if (!permitted || !existing.includes(network)) {
      if (
        !(await approve({
          origin,
          title: `Connect ${network === "kasplex" ? "Kasplex" : "Igra"} dApp?`,
          description:
            "Allow this site to view the selected Layer 2 account. Signing still requires a separate review.",
          details: connectionDetails(accounts),
        }))
      )
        throw rpc(4001, "Connection rejected.");
    }
    permission = {
      accounts: true,
      connectedAt: permission?.connectedAt ?? Date.now(),
      networks,
      evmChainId: evmConfig(network).chainId,
    };
    state.permissions[origin] = permission;
    await saveState(state);
    return [accounts[network]];
  }
  if (!safe.has(method) && !permitted)
    throw rpc(4100, "Connect this site to Kaspire first.");
  if (method === "getAccounts") {
    if (!permitted || !state.selectedAddress) return [];
    const networks = permissionNetworks(permission, state.network);
    const requested = String((params as any)?.network ?? "");
    const network = networks.includes(requested as KaspaNetwork)
      ? (requested as KaspaNetwork)
      : networks.includes(state.network)
        ? state.network
        : networks[0];
    if (network === "kasplex" || network === "igra")
      return sessionVault ? [(await evmContext(state)).address] : [];
    const kaspaNetwork = network === "testnet-10" ? "testnet-10" : "mainnet";
    const kaspaState = await kaspaProviderState(state, kaspaNetwork);
    return kaspaState.selectedAddress ? [kaspaState.selectedAddress] : [];
  }
  if (method === "getNetworkAccounts") {
    if (!permitted) return {};
    const networks = permissionNetworks(permission, state.network).filter(
      (network): network is ConnectableNetwork =>
        network !== "testnet-10",
    );
    return accountsForNetworks(state, networks);
  }
  if (method === "getNetwork") return state.network;
  if (method === "eth_chainId") {
    const configured = permission?.evmChainId;
    const network = configured
      ? evmNetworkForChainId(configured)
      : state.network === "igra"
        ? "igra"
        : "kasplex";
    return `0x${evmConfig(network).chainId.toString(16)}`;
  }
  if (method === "eth_accounts") {
    if (!permitted || !sessionVault) return [];
    const network = evmNetworkForChainId(
      permission?.evmChainId ??
        (state.network === "igra"
          ? evmConfig("igra").chainId
          : evmConfig("kasplex").chainId),
    );
    if (!permissionNetworks(permission, state.network).includes(network))
      return [];
    return [(await evmContext(state)).address];
  }
  if (method === "wallet_switchEthereumChain") {
    const first = Array.isArray(params) ? params[0] : params;
    const network = evmNetworkForChainId(first);
    const networks = permissionNetworks(permission, state.network);
    if (!networks.includes(network)) {
      const accounts = await accountsForNetworks(state, [network]);
      if (
        !(await approve({
          origin,
          title: `Add ${network === "kasplex" ? "Kasplex" : "Igra"} to this connection?`,
          description:
            "The existing Kaspa connection remains active. This adds the selected Layer 2 network.",
          details: connectionDetails(accounts),
        }))
      )
        throw rpc(4001, "Network connection rejected.");
      permission!.networks = [...new Set([...networks, network])];
    }
    permission!.evmChainId = evmConfig(network).chainId;
    state.permissions[origin] = permission!;
    await saveState(state);
    return null;
  }
  if (method === "getBalance") {
    if (!state.selectedAddress) throw rpc(4100, "No wallet selected.");
    const requested = String((params as any)?.network ?? state.network);
    if (requested === "kasplex" || requested === "igra") {
      if (!permissionNetworks(permission, state.network).includes(requested))
        throw rpc(4100, "This Layer 2 network is not connected.");
      return evmWalletSnapshot({ ...state, network: requested });
    }
    const kaspaNetwork = requested === "testnet-10" ? "testnet-10" : "mainnet";
    if (!permissionNetworks(permission, state.network).includes(kaspaNetwork))
      throw rpc(4100, `${kaspaNetwork === "mainnet" ? "Kaspa Mainnet" : "Kaspa TN10"} is not connected.`);
    const kaspaState = await kaspaProviderState(state, kaspaNetwork);
    const snapshot = await walletBalance(kaspaState.selectedAddress!, kaspaNetwork);
    return {
      ...snapshot,
      current: snapshot.balanceKas,
      pending: 0,
      outgoing: 0,
    };
  }
  if (method === "getUtxoEntries") {
    if (!state.selectedAddress) throw rpc(4100, "No wallet selected.");
    if ((params as any)?.network === "kasplex" || (params as any)?.network === "igra")
      throw rpc(-32601, "UTXOs are not used on Layer 2 networks.");
    const requested = String((params as any)?.network ?? state.network);
    const kaspaNetwork = requested === "testnet-10" ? "testnet-10" : "mainnet";
    if (!permissionNetworks(permission, state.network).includes(kaspaNetwork))
      throw rpc(4100, `${kaspaNetwork === "mainnet" ? "Kaspa Mainnet" : "Kaspa TN10"} is not connected.`);
    const kaspaState = await kaspaProviderState(state, kaspaNetwork);
    return (await walletCoreSnapshot(kaspaState.selectedAddress!, kaspaNetwork)).utxos;
  }
  if (method === "disconnect") {
    delete state.permissions[origin];
    await saveState(state);
    return true;
  }
  if (method === "switchNetwork") {
    const network = (params as { network?: KaspaNetwork })?.network;
    if (!["mainnet", "testnet-10", "kasplex", "igra"].includes(String(network)))
      throw rpc(-32602, "Unsupported Kaspa network.");
    if (network === state.network) return network;
    if (
      !(await approve({
        origin,
        title: `Switch to ${network === "mainnet" ? "Layer 1" : network === "testnet-10" ? "TN10" : network === "kasplex" ? "Kasplex" : "Igra"}?`,
        description:
          "All Kaspire wallet addresses and subsequent requests will use this network.",
        details: ["Existing keys and derivation paths do not change."],
      }))
    )
      throw rpc(4001, "Network switch rejected.");
    const fresh = await loadState();
    if (fresh.permissions[origin]?.accounts !== true)
      throw rpc(4100, "This dApp was disconnected while approval was pending.");
    await convertNetwork(fresh, network as KaspaNetwork, origin);
    return network;
  }
  const connectedNetworks = permissionNetworks(permission, state.network);
  const kaspaNetwork: "mainnet" | "testnet-10" =
    connectedNetworks.includes(state.network) && state.network === "testnet-10"
      ? "testnet-10"
      : "mainnet";
  if (l1ProviderMethods.has(method) && !connectedNetworks.includes(kaspaNetwork))
    throw rpc(4100, "The active Kaspa network is not connected for this site.");
  if (
    kaspaNetwork === "testnet-10" &&
    ["sendKRC20", "sendKCC20", "mintCovenantWyrm", "actCovenantWyrm", "transferKRC721", "transferKNS", "signPolicyTransaction"].includes(method)
  )
    throw rpc(4200, "This asset method is available on Kaspa Mainnet only.");
  const providerState = l1ProviderMethods.has(method)
    ? await kaspaProviderState(state, kaspaNetwork)
    : state;
  if (method === "pushTx") {
    const transaction =
      typeof params === "string"
        ? params
        : String((params as any)?.txJsonString ?? "");
    if (!transaction || transaction.length > 1_048_576)
      throw rpc(-32602, "Invalid signed transaction.");
    try {
      JSON.parse(transaction);
    } catch {
      throw rpc(-32602, "Signed transaction is not valid JSON.");
    }
    return broadcast(transaction, kaspaNetwork);
  }
  if (!sessionVault) {
    if (
      !(await approve({
        origin,
        title: "Unlock Kaspire",
        description:
          "This dApp is requesting a wallet operation. Unlock Kaspire before the transaction is prepared and reviewed.",
        details: [`Requested method: ${method}`],
        unlockOnly: true,
      }))
    )
      throw rpc(4001, "Wallet unlock cancelled.");
    await hydrateSession();
    if (!sessionVault) throw rpc(4100, "Unlock Kaspire before signing.");
  }
  if (method === "eth_sendTransaction") {
    const rows = Array.isArray(params) ? params : [];
    const raw = rows.length === 1 ? rows[0] : null;
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
      throw rpc(-32602, "Provide exactly one Layer 2 transaction.");
    const tx = raw as Record<string, unknown>;
    const allowed = new Set([
      "from",
      "to",
      "value",
      "data",
      "input",
      "nonce",
      "gas",
      "gasPrice",
    ]);
    if (Object.keys(tx).some((key) => !allowed.has(key)))
      throw rpc(-32602, "The Layer 2 transaction contains unsupported fields.");
    const network = evmNetworkForChainId(
      permission?.evmChainId ??
        (state.network === "igra"
          ? evmConfig("igra").chainId
          : evmConfig("kasplex").chainId),
    );
    if (!permissionNetworks(permission, state.network).includes(network))
      throw rpc(4100, "This Layer 2 network is not connected.");
    const { address } = await evmContext(state);
    const from = String(tx.from ?? "");
    const to = String(tx.to ?? "");
    if (
      from.toLowerCase() !== address.toLowerCase() ||
      !/^0x[0-9a-fA-F]{40}$/.test(to)
    )
      throw rpc(-32602, "Invalid Layer 2 sender or recipient.");
    const parseHex = (value: unknown, field: string) => {
      const text = String(value ?? "0x0");
      if (!/^0x[0-9a-fA-F]*$/.test(text))
        throw rpc(-32602, `${field} must be a hexadecimal quantity.`);
      return BigInt(`0x${text.slice(2) || "0"}`);
    };
    const value = parseHex(tx.value, "value");
    const data = String(tx.data ?? tx.input ?? "");
    if (data && (!/^0x(?:[0-9a-fA-F]{2})*$/.test(data) || data.length > 524_290))
      throw rpc(-32602, "Invalid or oversized Layer 2 transaction data.");
    const fields = await evmTransactionFields(network, address, to, value, data);
    const nonce = tx.nonce == null ? fields.nonce : parseHex(tx.nonce, "nonce");
    const gasPrice =
      tx.gasPrice == null ? fields.gasPrice : parseHex(tx.gasPrice, "gasPrice");
    const gas = tx.gas == null ? fields.gas : parseHex(tx.gas, "gas");
    if (
      nonce > BigInt(Number.MAX_SAFE_INTEGER) ||
      gas > BigInt(Number.MAX_SAFE_INTEGER) ||
      gasPrice <= 0n ||
      gas <= 0n
    )
      throw rpc(-32602, "Invalid Layer 2 nonce, gas or gas price.");
    const config = evmConfig(network);
    const request = {
      walletAddress: state.selectedAddress,
      from: address,
      to,
      recipient: to,
      valueWei: value.toString(),
      nonce: Number(nonce),
      gasLimit: Number(gas),
      gasPriceWei: gasPrice.toString(),
      chainId: config.chainId,
      data,
      tokenSymbol: config.nativeSymbol,
      displayAmount: formatUnits(value, 18, 18),
    };
    const wasm = await core();
    const review = JSON.parse(
      wasm.prepareEvmTransaction(JSON.stringify(request)),
    );
    if (
      !(await approve({
        origin,
        title: `${config.name} transaction`,
        description:
          "Review the complete Layer 2 transaction before Kaspire signs it.",
        details: [
          `From: ${address}`,
          `To / contract: ${to}`,
          `Value: ${formatUnits(value, 18, 18)} ${config.nativeSymbol}`,
          `Maximum network fee: ${formatUnits(gas * gasPrice, 18, 18)} ${config.nativeSymbol}`,
          `Gas: ${gas.toString()}`,
          `Data: ${data || "None"}`,
        ],
        rawJson: { request, review },
      }))
    )
      throw rpc(4001, "Layer 2 transaction rejected.");
    await hydrateSession();
    const freshState = await loadState();
    const freshPermission = freshState.permissions[origin];
    if (
      !sessionVault ||
      freshState.selectedAddress !== state.selectedAddress ||
      freshPermission?.accounts !== true ||
      !permissionNetworks(freshPermission, freshState.network).includes(network)
    )
      throw rpc(
        4100,
        "Wallet account, network or permission changed during approval. Build a fresh request.",
      );
    const freshContext = await evmContext(freshState);
    if (freshContext.address.toLowerCase() !== address.toLowerCase())
      throw rpc(4100, "Signing account changed during approval. Build a fresh request.");
    const signed = JSON.parse(
      wasm.signEvmTransaction(
        freshContext.secret,
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    const result = String(
      await evmRpc(network, "eth_sendRawTransaction", [signed.rawTransaction]),
    );
    if (result.toLowerCase() !== String(signed.transactionHash).toLowerCase())
      throw rpc(-32000, "Layer 2 broadcaster returned a mismatching transaction ID.");
    lastActivity = Date.now();
    return result;
  }
  if (method === "getPublicKey") {
    if (!providerState.selectedAddress) throw rpc(4100, "No wallet selected.");
    const entry = providerState.addresses.find(
      (item) => item.address === providerState.selectedAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw rpc(4100, "Selected wallet has no public key.");
    return (await core()).publicKey(signingSecret(wallet, entry));
  }
  if (method === "signMessage") {
    const message = String((params as any)?.message ?? "");
    const address = String(
      (params as any)?.address ?? providerState.selectedAddress ?? "",
    );
    if (
      !message ||
      message.length > 10_000 ||
      address !== providerState.selectedAddress
    )
      throw rpc(-32602, "Invalid personal-message request.");
    const entry = providerState.addresses.find((item) => item.address === address);
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw rpc(4100, "Selected wallet cannot sign.");
    if (
      !(await approve({
        origin,
        title: "Sign personal message?",
        description:
          "This does not send funds, but a signature can prove wallet ownership.",
        details: [`Address: ${address}`, `Message: ${message}`],
      }))
    )
      throw rpc(4001, "Signature rejected.");
    await assertFreshKaspaSigningContext(
      state,
      origin,
      address,
      kaspaNetwork,
    );
    const wasm = await core();
    const signature = wasm.signPersonalMessage(
      signingSecret(wallet, entry),
      address,
      message,
    );
    lastActivity = Date.now();
    return {
      address,
      publicKey: wasm.publicKey(signingSecret(wallet, entry)),
      signedMessage: signature,
      signature,
    };
  }
  if (method === "sendKaspa") {
    const input = params as Record<string, unknown> | null;
    const allowed = new Set([
      "to",
      "amountSompi",
      "from",
      "priorityFeeSompi",
    ]);
    if (
      !input ||
      typeof input !== "object" ||
      Object.keys(input).some((key) => !allowed.has(key))
    )
      throw rpc(-32602, "Invalid KAS payment request.");
    const recipient = String(input.to ?? "");
    const senderAddress = String(input.from ?? providerState.selectedAddress ?? "");
    const amount =
      typeof input.amountSompi === "number"
        ? input.amountSompi
        : Number(String(input.amountSompi ?? ""));
    const priorityFeeSompi = Number(String(input.priorityFeeSompi ?? 0));
    if (
      senderAddress !== providerState.selectedAddress ||
      !/^kaspa(test)?:[a-z0-9]{61,63}$/.test(recipient) ||
      !Number.isSafeInteger(amount) ||
      amount <= 0 ||
      amount > 2_100_000_000_000_000 ||
      !Number.isSafeInteger(priorityFeeSompi) ||
      priorityFeeSompi < 0 ||
      priorityFeeSompi > 100_000_000
    )
      throw rpc(-32602, "Invalid KAS payment request.");
    const entry = providerState.addresses.find(
      (item) => item.address === senderAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw rpc(4100, "Selected wallet cannot sign.");
    const account = kasAccountEntries(providerState, senderAddress);
    const primary = kasAccountPrimary(providerState, senderAddress) ?? entry;
    const signers = kasAccountSigners(providerState, senderAddress);
    const spend = await spendingDataForAddresses(account.map((item) => item.address), providerState.network);
    let request = {
      sender: primary.address,
      recipient,
      amountSompi: amount,
      feeRate: spend.feeRate,
      utxosJson: spend.utxosJson,
      signers,
      sendAll: false,
    };
    const wasm = await core();
    let review = JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
    if (priorityFeeSompi > 0) {
      request = {
        ...request,
        feeRate: Math.min(
          1000,
          spend.feeRate + priorityFeeSompi / Math.max(1, Number(review.mass)),
        ),
      };
      review = JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
    }
    if (
      !(await approve({
        origin,
        title: "Approve KAS payment?",
        description:
          "Kaspire rebuilt and reviewed this transaction in its Rust security core.",
        details: [
          `Send: ${(review.amountSompi / 100_000_000).toLocaleString("en-US")} KAS`,
          `To: ${review.recipient}`,
          `Fee: ${(review.feeSompi / 100_000_000).toLocaleString("en-US")} KAS`,
          `Change: ${(review.changeSompi / 100_000_000).toLocaleString("en-US")} KAS`,
          `${review.inputCount.toLocaleString("en-US")} inputs · ${review.outputCount.toLocaleString("en-US")} outputs`,
        ],
        rawJson: { request, review },
      }))
    )
      throw rpc(4001, "Payment rejected.");
    await assertFreshKaspaSigningContext(
      state,
      origin,
      senderAddress,
      kaspaNetwork,
    );
    const signed = JSON.parse(
      wasm.signTransaction(
        kasTransactionSecret(wallet, primary, signers),
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    const broadcastId = await broadcast(
      signed.submitJson,
      kaspaNetwork,
    );
    if (broadcastId && broadcastId !== signed.transactionId)
      throw rpc(-32000, "Node returned a mismatching transaction ID.");
    lastActivity = Date.now();
    return input.priorityFeeSompi === undefined
      ? signed.transactionId
      : { transactionId: signed.transactionId };
  }
  if (method === "signPskt") {
    const input = params as any;
    const senderAddress = String(input?.sender ?? providerState.selectedAddress ?? "");
    const signInputs = input?.options?.signInputs ?? input?.signInputs;
    const scripts = input?.scripts ?? input?.options?.scripts ?? [];
    const txJsonString = input?.psktTransactionJson ?? input?.txJsonString;
    const normalizedRequest = Object.prototype.hasOwnProperty.call(
      input ?? {},
      "psktTransactionJson",
    );
    if (
      !input ||
      senderAddress !== providerState.selectedAddress ||
      typeof txJsonString !== "string" ||
      !Array.isArray(signInputs ?? []) ||
      !Array.isArray(scripts) ||
      ((signInputs?.length ?? 0) === 0 && scripts.length === 0) ||
      (input.submitTransaction !== undefined &&
        typeof input.submitTransaction !== "boolean")
    )
      throw rpc(-32602, "Invalid PSKT request.");
    if (input.submitTransaction === true)
      throw rpc(
        4200,
        "Wallet-side PSKT broadcast is not enabled. Request sign-only and broadcast the returned PSKT through the dApp backend.",
      );
    const entry = providerState.addresses.find(
      (item) => item.address === senderAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw rpc(4100, "Selected wallet cannot sign.");
    const request = {
      sender: senderAddress,
      txJsonString,
      signInputs: signInputs ?? [],
      scripts,
    };
    const wasm = await core();
    const review = JSON.parse(wasm.preparePskt(JSON.stringify(request)));
    const warningDetails = (review.warnings as string[]).map(
      (item) => `Warning: ${item}`,
    );
    if (
      !(await approve({
        origin,
        title: "Approve reviewed PSKT?",
        description:
          "Kaspire will sign only the selected inputs shown by the Rust security core.",
        details: [
          `Transaction: ${review.transactionId}`,
          review.finalFeeKnown && review.feeSompi != null
            ? `Network fee: ${formatSompi(review.feeSompi)} KAS`
            : "Final network fee: unknown until buyer completes the transaction",
          `Buyer funding still required: ${formatSompi(review.fundingDeficitSompi)} KAS${review.fundingDeficitSompi > 0 ? " plus network fee · sign only" : ""}`,
          `Draft wallet balance change: ${(review.walletNetSompi / 100_000_000).toLocaleString("en-US")} KAS`,
          ...review.outputs.map((output: any) =>
            `Output ${output.index} · ${output.signatureBound ? "SIGNATURE-BOUND" : "UNBOUND"}: ${formatSompi(output.amountSompi)} KAS → ${output.address ?? output.scriptPublicKey}`),
          `${review.selectedInputCount.toLocaleString("en-US")} of ${review.inputCount.toLocaleString("en-US")} inputs selected`,
          ...warningDetails,
        ],
        rawJson: { request, review },
      }))
    )
      throw rpc(4001, "PSKT signature rejected.");
    await assertFreshKaspaSigningContext(
      state,
      origin,
      senderAddress,
      kaspaNetwork,
    );
    lastActivity = Date.now();
    const signed = JSON.parse(
      wasm.signPskt(
        signingSecret(wallet, entry),
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    return normalizedRequest || input.submitTransaction !== undefined
      ? { psktTransactionJson: signed.signedTxJson }
      : signed.signedTxJson;
  }
  if (method === "signPolicyTransaction") {
    const input = params as any;
    const senderAddress = String(input?.sender ?? providerState.selectedAddress ?? "");
    if (
      !input ||
      senderAddress !== providerState.selectedAddress ||
      typeof input.txJsonString !== "string" ||
      !Array.isArray(input.signInputIndexes) ||
      typeof (input.redeemScript ?? "") !== "string"
    )
      throw rpc(-32602, "Invalid policy transaction request.");
    const entry = providerState.addresses.find(
      (item) => item.address === senderAddress,
    );
    const wallet = sessionVault.wallets.find(
      (item) => item.id === entry?.walletId,
    );
    if (!entry || entry.watchOnly || !wallet)
      throw rpc(4100, "Selected wallet cannot sign.");
    const request = {
      sender: senderAddress,
      txJsonString: input.txJsonString,
      signInputIndexes: input.signInputIndexes,
      redeemScript: input.redeemScript ?? "",
    };
    const wasm = await core();
    const review = JSON.parse(
      wasm.preparePolicyTransaction(JSON.stringify(request)),
    );
    if (
      !(await approve({
        origin,
        title: "Approve vault transaction?",
        description:
          "Kaspire recognized and reconstructed a supported KasCoven vault policy.",
        details: [
          `Action: ${review.action}`,
          `Profile: ${review.profile}`,
          `Vault amount: ${review.vaultAmountSompi / 100_000_000} KAS`,
          `Fee: ${formatSompi(review.feeSompi)} KAS`,
          `${review.inputCount} inputs · ${review.outputCount} outputs`,
        ],
      }))
    )
      throw rpc(4001, "Policy transaction rejected.");
    lastActivity = Date.now();
    const signed = JSON.parse(
      wasm.signPolicyTransaction(
        signingSecret(wallet, entry),
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    return {
      signedTxJson: signed.signedTxJson,
      profile: review.profile,
      reviewHash: review.reviewHash,
    };
  }
  if (method === "mintCovenantWyrm")
    return mintCovenantWyrm(origin, params, providerState, sessionVault);
  if (method === "actCovenantWyrm")
    return actCovenantWyrm(origin, params, providerState, sessionVault);
  if (method === "sendKCC20")
    return kcc20Transfer(origin, params, providerState, sessionVault);
  if (
    method === "sendKRC20" ||
    method === "transferKRC721" ||
    method === "transferKNS"
  )
    return inscriptionTransfer(origin, method, params, providerState, sessionVault);
  throw rpc(4200, `${method} awaits the transaction approval window.`);
}

async function prepareWalletAsset(
  input: Record<string, unknown>,
  state: Awaited<ReturnType<typeof loadState>>,
  progress: (stage: string) => void,
) {
  if (state.network !== "mainnet" || !state.selectedAddress)
    throw new Error("Kaspa assets are available on Mainnet only.");
  const sender = state.selectedAddress;
  progress("Resolving recipient…");
  const recipient = await resolveWalletInput(
    String(input.to ?? ""),
    state.network,
  );
  if (
    state.settings.recipientAllowlist &&
    !state.contacts.some((item) => item.address === recipient) &&
    !state.addresses.some((item) => item.address === recipient)
  )
    throw new Error("Recipient is not in your address book.");
  const kind = String(input.kind ?? "");
  progress("Reading loaded wallet assets…");
  const savedSnapshot = (
    await chrome.storage.session.get("assetReviewSnapshot")
  ).assetReviewSnapshot as any;
  const assets =
    savedSnapshot?.address === sender &&
    savedSnapshot?.network === state.network
      ? savedSnapshot.assets
      : await inscriptionAssets(sender);
  const ticker = String(input.ticker ?? "")
    .trim()
    .toUpperCase();
  const amount = String(input.amount ?? "");
  let prepared: PreparedAssetTransfer;
  if (kind === "kcc20") {
    const covenantId = String(input.covenantId ?? "").toLowerCase();
    const numericAmount = Number(amount);
    if (
      !/^[0-9a-f]{64}$/.test(covenantId) ||
      !Number.isSafeInteger(numericAmount) ||
      numericAmount <= 0
    )
      throw new Error("Invalid KCC20 request.");
    const covenantAsset = (
      await walletAssets(sender, state.network)
    ).kcc20.find(
      (item: any) => String(item.covenantId).toLowerCase() === covenantId,
    );
    if (covenantAsset?.standard === "kron-native") {
      prepared = await prepareKronTransfer(
        sender,
        recipient,
        covenantId,
        numericAmount,
        String(input.displayAmount ?? ""),
        progress,
      );
    } else {
      progress("Verifying KCC20 cells…");
      const verified = await kcc20TransferData(
        sender,
        covenantId,
        numericAmount,
      );
      progress("Loading wallet UTXOs and fee…");
      const funding = await spendingData(sender, state.network);
      const request = {
        sender,
        recipient,
        covenantId,
        ticker: verified.ticker,
        amount: numericAmount,
        decimals: verified.decimals,
        feeRate: funding.feeRate,
        templateHash: verified.templateHash,
        cells: verified.cells,
        fundingUtxosJson: funding.utxosJson,
      };
      progress("Preparing native KCC20 review…");
      const review = JSON.parse(
        (await core()).prepareKcc20Transfer(JSON.stringify(request)),
      );
      prepared = {
        type: "kcc20",
        sender,
        operation: {
          kind,
          sender,
          recipient,
          ticker: verified.ticker,
          amount,
          displayAmount: String(input.displayAmount ?? ""),
        },
        request,
        review,
        createdAt: Date.now(),
      };
    }
  } else {
    let operation: any = {
      kind,
      sender,
      recipient,
      ticker: "",
      amount: "",
      tokenId: "",
      assetId: "",
    };
    if (kind === "krc20") {
      if (
        !/^[A-Z0-9_-]{1,32}$/.test(ticker) ||
        !/^[0-9]+$/.test(amount) ||
        BigInt(amount) <= 0n
      )
        throw new Error("Invalid KRC-20 amount or ticker.");
      const holding = assets.tokens.find(
        (item: any) => String(item.symbol).toUpperCase() === ticker,
      );
      if (
        !holding ||
        BigInt(amount) > BigInt(String(holding.raw_balance ?? "0"))
      )
        throw new Error(
          "Invalid amount, too many decimals, or insufficient token balance.",
        );
      operation = {
        ...operation,
        ticker,
        amount,
        displayAmount: String(input.displayAmount ?? ""),
      };
    } else if (kind === "kns") {
      const assetId = String(input.assetId ?? "").toLowerCase();
      const domain = assets.domains.find(
        (item: any) => String(item.asset_id).toLowerCase() === assetId,
      );
      if (!/^[0-9a-f]{64}i0$/.test(assetId) || !domain)
        throw new Error(
          "The KNS indexer did not provide this domain asset ID. Refresh and try again.",
        );
      operation = {
        ...operation,
        assetId,
        domainName: String(domain.name ?? ""),
      };
    } else if (kind === "krc721") {
      const tokenId = String(input.tokenId ?? "").trim();
      if (
        !/^[A-Z0-9_-]{1,32}$/.test(ticker) ||
        !tokenId ||
        tokenId.length > 128
      )
        throw new Error("Select a held KRC-721 NFT.");
      operation = { ...operation, ticker, tokenId };
      await verifyKrc721Ownership(sender, ticker, tokenId);
    } else throw new Error("Unsupported asset kind.");
    progress("Preparing native inscription plan…");
    const wasm = await core();
    const plan = JSON.parse(wasm.prepareInscription(JSON.stringify(operation)));
    progress("Loading wallet UTXOs and fee…");
    const spend = await spendingData(sender, state.network);
    const request = {
      sender,
      walletAddress: sender,
      recipient: plan.commitAddress,
      amountSompi: plan.commitAmountSompi,
      feeRate: spend.feeRate,
      utxosJson: spend.utxosJson,
      sendAll: false,
    };
    progress("Preparing native commit review…");
    const review = JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
    prepared = {
      type: "inscription",
      sender,
      operation,
      plan,
      request,
      review,
      createdAt: Date.now(),
    };
  }
  const preparedId = crypto.randomUUID();
  progress("Opening secure review…");
  await chrome.storage.session.set({
    preparedAsset: { id: preparedId, ...prepared },
  });
  return {
    preparedId,
    type: prepared.type,
    operation: prepared.operation,
    review: prepared.review,
    plan: prepared.plan,
  };
}

function hexBytes(value: string) {
  if (!/^[0-9a-f]+$/i.test(value) || value.length % 2)
    throw new Error("Invalid hexadecimal covenant data.");
  return Uint8Array.from(
    value.match(/../g)!.map((byte) => Number.parseInt(byte, 16)),
  );
}
function kronSafeScript(value: any) {
  const json =
      typeof value?.toJSON === "function" ? value.toJSON() : (value ?? {}),
    version = Number(json.version ?? 0),
    script = String(json.script ?? json.scriptPublicKey ?? value ?? "");
  if (
    !Number.isInteger(version) ||
    version < 0 ||
    version > 65535 ||
    !/^[0-9a-f]+$/i.test(script)
  )
    throw new Error("Invalid KRON script public key.");
  const versionHex = version
    .toString(16)
    .padStart(4, "0")
    .match(/../g)!
    .reverse()
    .join("");
  return `${versionHex}${script.toLowerCase()}`;
}
function assembleKronSafeTransaction(
  kaspa: any,
  covenantSpend: any,
  fundingEntries: any[],
  changeAddress: string,
  networkFee: bigint,
) {
  const covenantInputs = covenantSpend.inputs.map((input: any) => ({
    transactionId: input.transactionId,
    index: input.index,
    sequence: "0",
    sigOpCount: 0,
    computeBudget: input.computeBudget ?? kronSpend.TOKEN_COMPUTE,
    signatureScript: input.signatureScript,
    utxo: {
      address: null,
      amount: String(input.value),
      scriptPublicKey: kronSafeScript(input.scriptPublicKey),
      blockDaaScore: "0",
      isCoinbase: false,
      covenantId: null,
    },
  }));
  const fundingInputs = fundingEntries.map((entry: any) => ({
    transactionId: entry.outpoint.transactionId,
    index: entry.outpoint.index,
    sequence: "0",
    sigOpCount: 0,
    computeBudget: kronSpend.FUNDING_COMPUTE,
    signatureScript: "",
    utxo: {
      address: null,
      amount: String(entry.amount),
      scriptPublicKey: kronSafeScript(entry.scriptPublicKey),
      blockDaaScore: String(entry.blockDaaScore ?? 0),
      isCoinbase: entry.isCoinbase === true,
      covenantId: null,
    },
  }));
  const covenantInputValue = Array.from<any>(
      covenantSpend.inputs,
    ).reduce<bigint>((sum, input) => sum + BigInt(input.value), 0n),
    fundingTotal = fundingEntries.reduce<bigint>(
      (sum, entry) => sum + BigInt(entry.amount),
      0n,
    ),
    covenantOutputValue = Array.from<any>(covenantSpend.outputs).reduce<bigint>(
      (sum, output) => sum + BigInt(output.value),
      0n,
    ),
    change =
      covenantInputValue + fundingTotal - covenantOutputValue - networkFee;
  if (change < 0n)
    throw new Error("Insufficient KAS funding for KRON transaction.");
  const outputs = covenantSpend.outputs.map((output: any) => ({
    value: String(output.value),
    scriptPublicKey: kronSafeScript(output.scriptPublicKey),
    covenant: {
      authorizingInput: Number(output.binding.authorizingInput),
      covenantId: String(output.binding.covid),
    },
  }));
  outputs.push({
    value: String(change),
    scriptPublicKey: kronSafeScript(kaspa.payToAddressScript(changeAddress)),
  });
  const transaction = kaspa.Transaction.deserializeFromSafeJSON(
    JSON.stringify({
      id: "00".repeat(32),
      version: kronSpend.TX_VERSION,
      inputs: [...covenantInputs, ...fundingInputs],
      outputs,
      subnetworkId: "00".repeat(20),
      lockTime: "0",
      gas: "0",
      storageMass: "0",
      payload: "",
    }),
  );
  transaction.finalize();
  return {
    transaction,
    fundingInputIndexes: fundingInputs.map(
      (_: any, index: number) => index + covenantInputs.length,
    ),
    totalIn: covenantInputValue + fundingTotal,
    covenantOut: covenantOutputValue,
    change,
  };
}
function estimateKronFeeWithoutMutation(
  assembled: any,
  feeRateSompiPerGram: number,
) {
  const transaction = assembled.transaction,
    placeholderBytes = 66n * BigInt(assembled.fundingInputIndexes.length),
    serializedBytes =
      BigInt(kronSpend.estimatedSerializedSize(transaction)) + placeholderBytes,
    normalizedTransient =
      (serializedBytes * 4n * 500_000n + 1_000_000n - 1n) / 1_000_000n,
    computeGrams = Array.from<any>(transaction.inputs ?? []).reduce<bigint>(
      (sum, input) => sum + BigInt(input.computeBudget ?? 0) * 100n,
      0n,
    ),
    computeMass = 2_000n + computeGrams,
    billableMass =
      computeMass > normalizedTransient ? computeMass : normalizedTransient,
    rate = BigInt(
      Math.max(Math.ceil(feeRateSompiPerGram), kronSpend.MIN_RELAY_FEERATE),
    ),
    fee = (billableMass * rate * 6n) / 5n;
  return fee > 10_000n ? fee : 10_000n;
}
async function prepareKronTransfer(
  sender: string,
  recipient: string,
  covenantId: string,
  amount: number,
  displayAmount: string,
  progress: (stage: string) => void,
): Promise<PreparedAssetTransfer> {
  let stage = "cell discovery";
  try {
    progress("Verifying KRON token cells…");
    const verified = await kronTransferData(sender, covenantId, amount);
    stage = "WASM loading";
    progress("Loading KRON covenant engine…");
    const kaspa = await (loadKronKaspa as any)(
      chrome.runtime.getURL("wasm/kron_kaspa_bg.wasm"),
    );
    stage = "cell decoding";
    const decoded = verified.cells.map((cell: any) => ({
      cell,
      decoded: kronKcc20.decodeKcc20Redeem(hexBytes(cell.redeemScript), {
        maxIns: 4,
        maxOuts: 4,
      }),
    }));
    const first = decoded[0];
    if (!first) throw new Error("No spendable KRON token cells were found.");
    const template = first.decoded.template;
    for (const item of decoded) {
      if (
        item.decoded.state.identifierType !== kronKcc20.IDENTIFIER.ADDRESS ||
        item.decoded.state.amount !== BigInt(item.cell.tokenAmount)
      )
        throw new Error(
          "KRON cell ownership or amount did not match its verified state.",
        );
    }
    stage = "recipient script";
    const recipientScript = String(
        kaspa.payToAddressScript(recipient).script ?? "",
      ),
      recipientMatch = /^20([0-9a-f]{64})ac$/i.exec(recipientScript);
    if (!recipientMatch?.[1])
      throw new Error("KRON transfers require a standard P2PK recipient.");
    stage = "covenant transition";
    const senderTokens = decoded.map((item) => ({
      transactionId: item.cell.transactionId,
      index: item.cell.index,
      value: BigInt(item.cell.value),
      state: item.decoded.state,
    }));
    const covenantSpend = kronKcc20.buildKcc20Send(
      kaspa,
      template,
      senderTokens,
      hexBytes(recipientMatch[1]),
      BigInt(amount),
      senderTokens.length,
      covenantId,
    );
    for (const output of covenantSpend.outputs) {
      if (
        output.binding?.covid !== covenantId ||
        !/^[0-9a-f]{64}$/.test(output.binding.covid)
      )
        throw new Error("Generated output has an invalid covenant binding.");
    }
    stage = "KAS funding";
    progress("Loading KAS funding and fee estimate…");
    const funding = await spendingData(sender, "mainnet"),
      rows = JSON.parse(funding.utxosJson)
        .map((row: any) => {
          const entry = row.utxoEntry ?? {},
            nested = entry.scriptPublicKey ?? {},
            script = String(
              typeof nested === "string"
                ? nested
                : (nested.script ?? nested.scriptPublicKey ?? ""),
            );
          if (!/^[0-9a-f]+$/i.test(script))
            throw new Error("Kaspa node returned an invalid funding script.");
          return {
            outpoint: row.outpoint,
            amount: BigInt(entry.amount),
            scriptPublicKey: { version: Number(nested.version ?? 0), script },
            blockDaaScore: BigInt(entry.blockDaaScore ?? 0),
            isCoinbase: entry.isCoinbase === true,
          };
        })
        .sort((a: any, b: any) =>
          a.amount > b.amount ? -1 : a.amount < b.amount ? 1 : 0,
        );
    const selected: any[] = [];
    let total = 0n;
    for (const row of rows) {
      selected.push(row);
      total += row.amount;
      if (total >= 100_000_000n) break;
    }
    if (total < 50_100_000n)
      throw new Error(
        "At least about 0.51 KAS is required for the KRON token carrier and network fee.",
      );
    stage = "initial transaction assembly";
    let assembled = assembleKronSafeTransaction(
      kaspa,
      covenantSpend,
      selected,
      sender,
      10_000n,
    );
    stage = "fee calculation";
    const fee = estimateKronFeeWithoutMutation(assembled, funding.feeRate);
    stage = "final transaction assembly";
    assembled = assembleKronSafeTransaction(
      kaspa,
      covenantSpend,
      selected,
      sender,
      fee,
    );
    stage = "SafeJSON serialization";
    const pskt = kronSpend.toPsktJson(assembled),
      request = {
        sender,
        txJsonString: pskt.txJsonString,
        signInputs: pskt.signInputs,
      };
    stage = "Rust security review";
    progress("Preparing secure KRON review…");
    const review = JSON.parse(
        (await core()).preparePskt(JSON.stringify(request)),
      ),
      rawTransaction = JSON.parse(pskt.txJsonString),
      inputTotalSompi = rawTransaction.inputs.reduce(
        (sum: bigint, input: any) => sum + BigInt(input.utxo?.amount ?? 0),
        0n,
      ),
      outputTotalSompi = rawTransaction.outputs.reduce(
        (sum: bigint, output: any) => sum + BigInt(output.value ?? 0),
        0n,
      ),
      lockedKasSompi = senderTokens.reduce(
        (sum: bigint, input: any) => sum + BigInt(input.value),
        0n,
      ),
      lockedKasOutputSompi = covenantSpend.outputs.reduce(
        (sum: bigint, output: any) => sum + BigInt(output.value),
        0n,
      ),
      lockedKasTopUpSompi =
        lockedKasOutputSompi > lockedKasSompi
          ? lockedKasOutputSompi - lockedKasSompi
          : 0n,
      lockedKasReleasedSompi =
        lockedKasSompi > lockedKasOutputSompi
          ? lockedKasSompi - lockedKasOutputSompi
          : 0n,
      computeBudget = rawTransaction.inputs.reduce(
        (sum: number, input: any) => sum + Number(input.computeBudget ?? 0),
        0,
      ),
      computeMass = 2_000 + computeBudget * 100,
      transientMass = Number(
        (BigInt(kronSpend.estimatedSerializedSize(assembled)) * 4n * 500_000n +
          999_999n) /
          1_000_000n,
      ),
      feeMass = Math.max(computeMass, transientMass);
    return {
      type: "kron",
      sender,
      operation: {
        kind: "kcc20",
        sender,
        recipient,
        ticker: verified.ticker,
        amount: String(amount),
        displayAmount: displayAmount || String(amount),
        covenantId,
      },
      request,
      review: {
        ...review,
        rawJson: rawTransaction,
        templateHash: /^[0-9a-f]{64}$/.test(verified.templateHash)
          ? verified.templateHash
          : "",
        networkFeeSompi: Number(inputTotalSompi - outputTotalSompi),
        feeSompi: Number(inputTotalSompi - outputTotalSompi),
        inputTotalSompi: Number(inputTotalSompi),
        outputTotalSompi: Number(outputTotalSompi),
        covenantInputCount: senderTokens.length,
        covenantOutputCount: covenantSpend.outputs.length,
        lockedKasSompi: Number(lockedKasSompi),
        lockedKasTopUpSompi: Number(lockedKasTopUpSompi),
        lockedKasReleasedSompi: Number(lockedKasReleasedSompi),
        lockedKasOutputSompi: Number(lockedKasOutputSompi),
        computeBudget,
        computeMass,
        transientMass,
        feeMass,
        mass: feeMass,
      },
      createdAt: Date.now(),
    };
  } catch (error) {
    throw new Error(
      `[Kaspire Extension ${extensionVersion} · KRON ${stage}] ${(error as Error)?.message ?? error}`,
    );
  }
}

async function broadcastKron(
  signedTxJson: string,
  expectedTransactionId: string,
) {
  const kaspa = await (loadKronKaspa as any)(
    chrome.runtime.getURL("wasm/kron_kaspa_bg.wasm"),
  );
  let transaction: any;
  try {
    transaction = kaspa.Transaction.deserializeFromSafeJSON(signedTxJson);
  } catch (error) {
    throw new Error(
      `[Kaspire Extension ${extensionVersion} · KRON signed SafeJSON] ${(error as Error)?.message ?? error}`,
    );
  }
  const localId = String(
    transaction.id ?? transaction.getId?.() ?? "",
  ).toLowerCase();
  if (localId && localId !== expectedTransactionId.toLowerCase())
    throw new Error("KRON signed transaction ID changed after approval.");
  const safe = JSON.parse(signedTxJson),
    rpcTransaction = {
      id: String(safe.id),
      version: Number(safe.version),
      inputs: (safe.inputs ?? []).map((input: any) => ({
        previousOutpoint: {
          transactionId: String(input.transactionId),
          index: Number(input.index),
        },
        signatureScript: String(input.signatureScript ?? ""),
        sequence: BigInt(input.sequence),
        sigOpCount: Number(input.sigOpCount),
        computeBudget: Number(input.computeBudget ?? 0),
      })),
      outputs: (safe.outputs ?? []).map((output: any) => {
        const covenant =
          output.covenant == null
            ? undefined
            : {
                authorizingInput: Number(output.covenant.authorizingInput),
                covenantId: String(output.covenant.covenantId).toLowerCase(),
              };
        if (covenant && !/^[0-9a-f]{64}$/.test(covenant.covenantId))
          throw new Error("Signed KRON output has an invalid covenant ID.");
        return {
          value: BigInt(output.value),
          scriptPublicKey: String(output.scriptPublicKey),
          ...(covenant ? { covenant } : {}),
        };
      }),
      subnetworkId: String(safe.subnetworkId),
      lockTime: BigInt(safe.lockTime),
      gas: BigInt(safe.gas),
      storageMass: BigInt(safe.storageMass ?? 0),
      payload: String(safe.payload ?? ""),
    };
  let rpc: any;
  try {
    const resolver = new kaspa.Resolver(),
      url = await resolver.getUrl("borsh", "mainnet");
    rpc = new kaspa.RpcClient({ url, encoding: "borsh" });
    await rpc.connect();
    const result = await rpc.submitTransaction({
      transaction: rpcTransaction,
      allowOrphan: false,
    });
    const transactionId = String(
      result?.transactionId ?? result ?? "",
    ).toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(transactionId))
      throw new Error("Kaspa node returned no valid KRON transaction ID.");
    if (transactionId !== expectedTransactionId.toLowerCase())
      throw new Error("Kaspa node returned a mismatching KRON transaction ID.");
    return transactionId;
  } catch (error) {
    throw new Error(
      `[Kaspire Extension ${extensionVersion} · KRON wRPC broadcast] ${(error as Error)?.message ?? error}`,
    );
  } finally {
    try {
      await rpc?.disconnect();
    } catch {}
  }
}

async function confirmPreparedAsset(
  preparedId: string,
  state: Awaited<ReturnType<typeof loadState>>,
  vault: VaultPayload,
) {
  const stored = (await chrome.storage.session.get("preparedAsset"))
    .preparedAsset as (PreparedAssetTransfer & { id: string }) | undefined;
  if (
    !stored ||
    stored.id !== preparedId ||
    Date.now() - stored.createdAt > 15 * 60_000
  )
    throw new Error("Prepared asset review expired. Prepare it again.");
  if (stored.sender !== state.selectedAddress)
    throw new Error("The selected wallet changed after review.");
  const entry = state.addresses.find((item) => item.address === stored.sender);
  const wallet = vault.wallets.find((item) => item.id === entry?.walletId);
  if (!entry || entry.watchOnly || !wallet)
    throw new Error("Selected wallet cannot sign.");
  const wasm = await core();
  if (stored.type === "kcc20") {
    if (
      !(await approve({
        origin: "Kaspire Wallet",
        title: "Authorize KCC20 covenant transfer?",
        description: "Verify the native Rust review before signing.",
        details: kcc20ReviewDetails(stored.operation, stored.review),
        rawJson: stored.review.rawJson ?? stored.request,
      }))
    )
      throw rpc(4001, "KCC20 transfer rejected.");
    const signed = JSON.parse(
      wasm.signKcc20Transfer(
        signingSecret(wallet, entry),
        JSON.stringify(stored.request),
        stored.review.reviewHash,
      ),
    );
    await broadcastKcc20(signed.wrpcJson, signed.transactionId);
    await recordWalletActivity(stored.sender, {
      transactionId: signed.transactionId,
      blockTime: Date.now(),
      isAccepted: true,
      incoming: false,
      assetKind: "KCC20",
      assetSymbol: stored.operation.ticker,
      displayAmount: stored.operation.displayAmount || stored.operation.amount,
      tokenId: stored.request.covenantId,
      covenantId: stored.review.covenantId,
      templateHash: stored.review.templateHash,
      counterparty: stored.operation.recipient,
      from: [{ address: stored.sender, ownerId: "" }],
      to: [{ address: stored.operation.recipient, ownerId: "" }],
      feeSompi: stored.review.feeSompi,
      inputCount: stored.review.covenantInputCount,
      outputCount: stored.review.covenantOutputCount,
      mass: stored.review.mass,
      computeMass: stored.review.computeMass,
      storageMass: stored.review.storageMass,
      storageMassTarget: stored.review.storageMassTarget,
      transientMass: stored.review.transientMass,
      feeMass: stored.review.feeMass,
      computeBudget: stored.review.computeBudget,
      lockedKasSompi: stored.review.lockedKasSompi,
      lockedKasTopUpSompi: stored.review.lockedKasTopUpSompi,
      lockedKasReleasedSompi: stored.review.lockedKasReleasedSompi,
      lockedKasOutputSompi: stored.review.lockedKasOutputSompi,
      type: "transfer",
    });
    await chrome.storage.session.remove("preparedAsset");
    return {
      kind: "kcc20",
      transactionId: signed.transactionId,
      revealTransactionId: signed.transactionId,
      revealFeeSompi: stored.review.feeSompi,
    };
  }
  if (stored.type === "kron") {
    const warnings = ((stored.review.warnings as string[]) ?? []).map(
      (item) => `Warning: ${item}`,
    );
    if (
      !(await approve({
        origin: "Kaspire Wallet",
        title: `Authorize ${stored.operation.ticker} transfer?`,
        description:
          "Kaspire independently reviewed the KRON covenant PSKT and will sign only the selected P2PK funding inputs.",
        details: [
          `Send: ${stored.operation.displayAmount} ${stored.operation.ticker}`,
          `To: ${stored.operation.recipient}`,
          `Covenant ID: ${stored.operation.covenantId}`,
          `Network fee: ${formatSompi(stored.review.networkFeeSompi)} KAS`,
          `${stored.review.covenantInputCount} covenant input(s) · ${stored.review.covenantOutputCount} covenant output(s)`,
          `${stored.review.selectedInputCount} of ${stored.review.inputCount} inputs selected for signing`,
          ...warnings,
        ],
        rawJson: stored.review.rawJson ?? {
          request: stored.request,
          review: stored.review,
        },
      }))
    )
      throw rpc(4001, "KRON transfer rejected.");
    const signed = JSON.parse(
      wasm.signPskt(
        signingSecret(wallet, entry),
        JSON.stringify(stored.request),
        stored.review.reviewHash,
      ),
    ).signedTxJson;
    await broadcastKron(signed, stored.review.transactionId);
    await recordWalletActivity(stored.sender, {
      transactionId: stored.review.transactionId,
      blockTime: Date.now(),
      isAccepted: true,
      incoming: false,
      assetKind: "KCC20",
      assetSymbol: stored.operation.ticker,
      displayAmount: stored.operation.displayAmount,
      tokenId: stored.operation.covenantId,
      covenantId: stored.operation.covenantId,
      templateHash: stored.review.templateHash,
      counterparty: stored.operation.recipient,
      from: [{ address: stored.sender }],
      to: [{ address: stored.operation.recipient }],
      feeSompi: stored.review.feeSompi,
      totalInputSompi: stored.review.inputTotalSompi,
      totalOutputSompi: stored.review.outputTotalSompi,
      inputCount: stored.review.covenantInputCount,
      outputCount: stored.review.covenantOutputCount,
      mass: stored.review.mass,
      computeMass: stored.review.computeMass,
      transientMass: stored.review.transientMass,
      feeMass: stored.review.feeMass,
      computeBudget: stored.review.computeBudget,
      lockedKasSompi: stored.review.lockedKasSompi,
      lockedKasTopUpSompi: stored.review.lockedKasTopUpSompi,
      lockedKasReleasedSompi: stored.review.lockedKasReleasedSompi,
      lockedKasOutputSompi: stored.review.lockedKasOutputSompi,
      rawJson: JSON.parse(signed),
      type: "kron-transfer",
      standard: "kron-native",
    });
    await chrome.storage.session.remove("preparedAsset");
    return {
      kind: "kcc20",
      transactionId: stored.review.transactionId,
      revealTransactionId: stored.review.transactionId,
      revealFeeSompi: stored.review.feeSompi,
    };
  }
  if (
    !(await approve({
      origin: "Kaspire Wallet",
      title: "Authorize asset commit?",
      description:
        "This signs the commit transaction shown in the preceding review.",
      details: [
        `To: ${stored.operation.recipient}`,
        `Temporary commit: ${formatSompi(stored.review.amountSompi)} KAS`,
        `Fee: ${formatSompi(stored.review.feeSompi)} KAS`,
      ],
    }))
  )
    throw rpc(4001, "Asset transfer rejected.");
  const signedCommit = JSON.parse(
    wasm.signTransaction(
      signingSecret(wallet, entry),
      JSON.stringify(stored.request),
      stored.review.reviewHash,
    ),
  );
  const id = await broadcast(signedCommit.submitJson, state.network);
  if (id && id !== signedCommit.transactionId)
    throw new Error("Node returned a mismatching commit ID.");
  const pending = {
    operation: stored.operation,
    plan: stored.plan,
    commitTransactionId: signedCommit.transactionId,
    commitFeeSompi: stored.review.feeSompi,
    createdAt: Date.now(),
    state: "commit-accepted",
  };
  await chrome.storage.local.set({ pendingInscription: pending });
  await chrome.storage.session.remove("preparedAsset");
  return finishPendingInscription("Kaspire Wallet", pending, state, vault);
}

async function inscriptionTransfer(
  ...args: Parameters<typeof inscriptionTransferUnsafe>
) {
  return runExclusiveInscription(() => inscriptionTransferUnsafe(...args));
}

async function inscriptionTransferUnsafe(
  origin: string,
  method: ProviderMethod,
  params: unknown,
  state: Awaited<ReturnType<typeof loadState>>,
  vault: VaultPayload,
) {
  if (state.network !== "mainnet")
    throw rpc(4200, "Kaspa inscription assets are available on Mainnet only.");
  const input = params as Record<string, unknown> | null;
  const sender = String(input?.from ?? state.selectedAddress ?? "");
  const recipient = String(input?.to ?? "");
  if (
    !input ||
    sender !== state.selectedAddress ||
    !/^kaspa:[a-z0-9]{61,63}$/.test(recipient)
  )
    throw rpc(-32602, "Invalid asset transfer request.");
  const entry = state.addresses.find((item) => item.address === sender);
  const wallet = vault.wallets.find((item) => item.id === entry?.walletId);
  if (!entry || entry.watchOnly || !wallet)
    throw rpc(4100, "Selected wallet cannot sign.");
  const assets = await inscriptionAssets(sender);
  let operation: any;
  if (method === "sendKRC20") {
    const ticker = String(input.ticker ?? "")
      .trim()
      .toUpperCase();
    const amount = String(input.amount ?? "");
    if (
      !/^[A-Z0-9_-]{1,32}$/.test(ticker) ||
      !/^\d+$/.test(amount) ||
      amount === "0"
    )
      throw rpc(-32602, "Invalid KRC-20 amount or ticker.");
    const holding = assets.tokens.find(
      (item: any) => item.symbol.toUpperCase() === ticker,
    );
    if (!holding || BigInt(amount) > BigInt(holding.raw_balance))
      throw rpc(-32602, "Insufficient verified KRC-20 balance.");
    const displayAmount = formatRawTokenAmount(
      amount,
      Number(holding.decimals ?? 8),
    );
    operation = {
      kind: "krc20",
      sender,
      recipient,
      ticker,
      amount,
      displayAmount,
      tokenId: `krc20-${ticker.toLowerCase()}`,
      assetId: "",
    };
  } else if (method === "transferKNS") {
    const assetId = String(input.assetId ?? "").toLowerCase();
    if (
      !/^[0-9a-f]{64}i0$/.test(assetId) ||
      !assets.domains.some((item: any) => item.asset_id === assetId)
    )
      throw rpc(
        -32602,
        "The selected wallet does not own this verified KNS asset.",
      );
    operation = {
      kind: "kns",
      sender,
      recipient,
      ticker: "",
      amount: "",
      tokenId: "",
      assetId,
    };
  } else {
    const ticker = String(input.ticker ?? "")
      .trim()
      .toUpperCase();
    const tokenId = String(input.tokenId ?? "").trim();
    if (
      !/^[A-Z0-9_-]{1,32}$/.test(ticker) ||
      !tokenId ||
      tokenId.length > 128 ||
      !(await verifyKrc721Ownership(sender, ticker, tokenId))
    )
      throw rpc(
        -32602,
        "The selected wallet does not own this verified KRC-721 token.",
      );
    operation = {
      kind: "krc721",
      sender,
      recipient,
      ticker,
      amount: "",
      tokenId,
      assetId: "",
    };
  }
  const wasm = await core();
  const plan = JSON.parse(wasm.prepareInscription(JSON.stringify(operation)));
  const spend = await spendingData(sender, state.network);
  const commitRequest = {
    sender,
    recipient: plan.commitAddress,
    amountSompi: plan.commitAmountSompi,
    feeRate: spend.feeRate,
    utxosJson: spend.utxosJson,
    sendAll: false,
  };
  const commit = JSON.parse(
    wasm.prepareTransaction(JSON.stringify(commitRequest)),
  );
  const label =
    method === "sendKRC20"
      ? `${operation.amount} raw units ${operation.ticker}`
      : method === "transferKNS"
        ? `KNS ${operation.assetId}`
        : `${operation.ticker} #${operation.tokenId}`;
  if (
    !(await approve({
      origin,
      title: "Approve asset commit?",
      description: "This is step 1 of the Kaspa commit/reveal transfer.",
      details: [
        label,
        `To: ${recipient}`,
        `Commit: ${plan.commitAmountSompi / 100_000_000} KAS`,
        `Fee: ${formatSompi(commit.feeSompi)} KAS`,
      ],
    }))
  )
    throw rpc(4001, "Asset transfer rejected.");
  const signedCommit = JSON.parse(
    wasm.signTransaction(
      signingSecret(wallet, entry),
      JSON.stringify(commitRequest),
      commit.reviewHash,
    ),
  );
  const id = await broadcast(signedCommit.submitJson, state.network);
  if (id && id !== signedCommit.transactionId)
    throw rpc(-32000, "Node returned a mismatching commit ID.");
  await chrome.storage.local.set({
    pendingInscription: {
      operation,
      plan,
      commitTransactionId: signedCommit.transactionId,
      createdAt: Date.now(),
    },
  });
  const commitUtxosJson = await waitForUtxo(
    plan.commitAddress,
    signedCommit.transactionId,
    state.network,
  );
  const revealRequest = {
    operation,
    commitTransactionId: signedCommit.transactionId,
    commitUtxosJson,
    feeRate: (await spendingData(plan.commitAddress, state.network)).feeRate,
  };
  const reveal = JSON.parse(wasm.prepareReveal(JSON.stringify(revealRequest)));
  if (
    !(await approve({
      origin,
      title: "Approve asset reveal?",
      description:
        "This final transaction publishes the reviewed asset transfer.",
      details: [
        label,
        `To: ${recipient}`,
        `Reveal fee: ${formatSompi(reveal.feeSompi)} KAS`,
        `Commit transaction: ${signedCommit.transactionId}`,
      ],
    }))
  )
    throw rpc(
      4001,
      "Reveal rejected; the commit remains recoverable in Kaspire.",
    );
  const signedReveal = JSON.parse(
    wasm.signReveal(
      signingSecret(wallet, entry),
      JSON.stringify(revealRequest),
      reveal.reviewHash,
    ),
  );
  const revealId = await broadcast(signedReveal.submitJson, state.network);
  if (revealId && revealId !== signedReveal.transactionId)
    throw rpc(-32000, "Node returned a mismatching reveal ID.");
  await recordWalletActivity(sender, {
    transactionId: signedReveal.transactionId,
    commitTransactionId: signedCommit.transactionId,
    blockTime: Date.now(),
    isAccepted: true,
    incoming: false,
    assetKind:
      operation.kind === "krc721"
        ? "KRC-721"
        : operation.kind === "kns"
          ? "KNS"
          : "KRC-20",
    assetSymbol: operation.ticker || operation.assetId || "KNS",
    displayAmount:
      operation.displayAmount ||
      (operation.kind === "krc721" ? "1" : ""),
    tokenId: operation.tokenId || operation.assetId || "",
    counterparty: recipient,
    from: [{ address: sender }],
    to: [{ address: recipient }],
    feeSompi: reveal.feeSompi,
    type: "transfer",
  });
  await chrome.storage.local.remove("pendingInscription");
  lastActivity = Date.now();
  return {
    kind: operation.kind,
    commitTransactionId: signedCommit.transactionId,
    revealTransactionId: signedReveal.transactionId,
    commitFeeSompi: commit.feeSompi,
    revealFeeSompi: reveal.feeSompi,
  };
}

const GOTHDAG_WYRM_ORIGIN = "https://gothdag.kaslab.space";
const GOTHDAG_WYRM_TEST_WALLET =
  "kaspa:qp0mtdvzscrkfft702j85s8yzdl8a87n5d6pgtm8vrxg6hqu0wywzvwkevdk3";
const WYRM_ELEMENTS = [
  "Fire",
  "Ice",
  "Wind",
  "Earth",
  "Shadow",
  "Light",
  "Steel",
  "Lightning",
  "Rock",
  "Cosmos",
  "Crystal",
  "Cyber",
  "Nuclear",
] as const;

async function mintCovenantWyrm(
  origin: string,
  params: unknown,
  state: Awaited<ReturnType<typeof loadState>>,
  vault: VaultPayload,
) {
  if (state.network !== "mainnet")
    throw rpc(4200, "Covenant Wyrms are available on Mainnet only.");
  if (origin !== GOTHDAG_WYRM_ORIGIN)
    throw rpc(4100, "Covenant Wyrm genesis is restricted to GothDAG.");
  const input = params as any;
  const sender = String(input?.from ?? state.selectedAddress ?? "");
  const serial = Number(input?.serial);
  const element = Number(input?.element);
  if (
    sender !== state.selectedAddress ||
    sender !== GOTHDAG_WYRM_TEST_WALLET ||
    !Number.isSafeInteger(serial) ||
    serial < 1 ||
    serial > WYRM_ELEMENTS.length ||
    !Number.isSafeInteger(element) ||
    element < 0 ||
    element >= WYRM_ELEMENTS.length ||
    serial !== element + 1
  )
    throw rpc(-32602, "Invalid or unauthorized Covenant Wyrm genesis request.");
  const entry = state.addresses.find((item) => item.address === sender);
  const wallet = vault.wallets.find((item) => item.id === entry?.walletId);
  if (!entry || entry.watchOnly || !wallet)
    throw rpc(4100, "Selected wallet cannot sign.");

  const funding = await spendingData(sender, state.network);
  const request = {
    sender,
    serial,
    element,
    feeRate: funding.feeRate,
    fundingUtxosJson: funding.utxosJson,
  };
  const wasm = await core();
  const review = JSON.parse(wasm.prepareWyrmGenesis(JSON.stringify(request)));
  if (
    !(await approve({
      origin,
      title: "Mint Covenant Wyrm Genesis Egg?",
      description:
        "This creates a permanent Mainnet Covenant asset. The 1 KAS reserve remains locked inside the living Wyrm cell.",
      details: [
        "Element: " + WYRM_ELEMENTS[element],
        "Genesis serial: " + serial + " / 287",
        "Covenant ID: " + review.covenantId,
        "Permanent template: " + review.templateHash,
        "Locked reserve: " + (Number(review.reserveSompi) / 100_000_000).toFixed(8) + " KAS",
        "Network fee: " + (Number(review.feeSompi) / 100_000_000).toFixed(8) + " KAS",
      ],
      rawJson: { request, review },
    }))
  )
    throw rpc(4001, "Covenant Wyrm mint rejected.");

  const signed = JSON.parse(
    wasm.signWyrmGenesis(
      signingSecret(wallet, entry),
      JSON.stringify(request),
      review.reviewHash,
    ),
  );
  await broadcastKcc20(signed.wrpcJson, signed.transactionId);
  await recordWalletActivity(sender, {
    transactionId: signed.transactionId,
    blockTime: Date.now(),
    isAccepted: true,
    incoming: false,
    assetKind: "COVENANT-WYRM",
    assetSymbol: WYRM_ELEMENTS[element],
    displayAmount: "1 Genesis Egg",
    tokenId: String(serial),
    covenantId: signed.covenantId,
    templateHash: review.templateHash,
    counterparty: signed.covenantId,
    from: [{ address: sender }],
    to: [{ address: sender }],
    feeSompi: review.feeSompi,
    mass: review.mass,
    storageMass: review.storageMass,
    lockedKasSompi: review.reserveSompi,
    type: "covenant-genesis",
  });
  lastActivity = Date.now();
  return {
    transactionId: signed.transactionId,
    covenantId: signed.covenantId,
    serial,
    element,
    templateHash: review.templateHash,
    reserveSompi: review.reserveSompi,
    feeSompi: review.feeSompi,
    cell: {
      covenantId: signed.covenantId,
      transactionId: signed.transactionId,
      index: 0,
      valueSompi: signed.valueSompi,
      outputAddress: signed.outputAddress,
      scriptPublicKey: signed.scriptPublicKey,
      state: signed.state,
    },
  };
}

async function actCovenantWyrm(
  origin: string,
  params: unknown,
  state: Awaited<ReturnType<typeof loadState>>,
  vault: VaultPayload,
) {
  if (state.network !== "mainnet")
    throw rpc(4200, "Covenant Wyrms are available on Mainnet only.");
  if (origin !== GOTHDAG_WYRM_ORIGIN)
    throw rpc(4100, "Covenant Wyrm actions are restricted to GothDAG.");
  const input = params as any;
  const sender = String(input?.from ?? state.selectedAddress ?? "");
  const action = String(input?.action ?? "");
  const allowedActions = new Set(["incubate", "warm", "hatch", "feed", "transfer", "grow", "die", "name", "sleep", "wake", "specialFeed"]);
  if (sender !== state.selectedAddress || !allowedActions.has(action))
    throw rpc(-32602, "Invalid Covenant Wyrm action request.");
  const entry = state.addresses.find((item) => item.address === sender);
  const wallet = vault.wallets.find((item) => item.id === entry?.walletId);
  if (!entry || entry.watchOnly || !wallet)
    throw rpc(4100, "Selected wallet cannot sign.");
  const cell = { ...input?.cell };
  await verifyWyrmCell(cell);

  const wasm = await core();
  const initialFunding = await spendingData(sender, state.network);
  const commitRequest = {
    sender,
    recipient: sender,
    amountSompi: 100_000_000,
    feeRate: initialFunding.feeRate,
    utxosJson: initialFunding.utxosJson,
    sendAll: false,
  };
  const commitReview = JSON.parse(wasm.prepareTransaction(JSON.stringify(commitRequest)));
  if (
    !(await approve({
      origin,
      title: "Commit Covenant Wyrm action?",
      description:
        "Step 1 of 2 creates a fresh self-owned action UTXO. Its confirmed DAA score provides the non-forgeable time used by the Wyrm covenant.",
      details: [
        "Action: " + action,
        "Wyrm: #" + String(cell?.state?.serial ?? "?"),
        "Temporary self-output: 1 KAS (returned by step 2, minus fees)",
        "Commit fee: " + formatSompi(commitReview.feeSompi) + " KAS",
      ],
      rawJson: { commitRequest, commitReview, cell },
    }))
  )
    throw rpc(4001, "Covenant Wyrm action rejected.");
  const signedCommit = JSON.parse(
    wasm.signTransaction(
      signingSecret(wallet, entry),
      JSON.stringify(commitRequest),
      commitReview.reviewHash,
    ),
  );
  const commitId = await broadcast(signedCommit.submitJson, state.network);
  if (commitId && commitId !== signedCommit.transactionId)
    throw rpc(-32000, "Node returned a mismatching Wyrm action commit ID.");
  const allCommitUtxos = JSON.parse(
    await waitForUtxo(sender, signedCommit.transactionId, state.network),
  );
  const committed = Array.isArray(allCommitUtxos)
    ? allCommitUtxos.filter(
        (item: any) =>
          String(item?.outpoint?.transactionId ?? "").toLowerCase() ===
          signedCommit.transactionId.toLowerCase(),
      )
    : [];
  if (!committed.length)
    throw rpc(-32000, "The confirmed Wyrm action UTXO could not be isolated.");
  const transitionRequest = {
    sender,
    action,
    cell,
    recipient: String(input?.recipient ?? ""),
    name: String(input?.name ?? ""),
    specialFeedKind: Number(input?.specialFeedKind ?? 0),
    specialization: Number(input?.specialization ?? 0),
    feeRate: (await spendingData(sender, state.network)).feeRate,
    actionUtxosJson: JSON.stringify(committed),
  };
  const review = JSON.parse(
    wasm.prepareWyrmTransition(JSON.stringify(transitionRequest)),
  );
  if (
    !(await approve({
      origin,
      title: "Apply Covenant Wyrm action?",
      description:
        "Step 2 consumes the current Wyrm state and creates its covenant-authorized successor.",
      details: [
        "Action: " + action,
        "Wyrm: #" + review.serial + " · " + WYRM_ELEMENTS[review.element],
        "Covenant ID: " + review.covenantId,
        "Confirmed action DAA: " + review.actionDaaScore,
        ...(action === "specialFeed" ? ["Special feed kind: " + String(input?.specialFeedKind ?? "?")] : []),
        ...(action === "grow" && Number(input?.specialization ?? 0) > 0 ? ["Chosen specialization: " + String(input.specialization)] : []),
        "Transition fee: " + formatSompi(review.feeSompi) + " KAS",
      ],
      rawJson: { transitionRequest, review },
    }))
  )
    throw rpc(4001, "Covenant Wyrm transition rejected. The self-output remains ordinary spendable KAS.");
  const signed = JSON.parse(
    wasm.signWyrmTransition(
      signingSecret(wallet, entry),
      JSON.stringify(transitionRequest),
      review.reviewHash,
    ),
  );
  await broadcastKcc20(signed.wrpcJson, signed.transactionId);
  await recordWalletActivity(sender, {
    transactionId: signed.transactionId,
    commitTransactionId: signedCommit.transactionId,
    blockTime: Date.now(),
    isAccepted: true,
    incoming: false,
    assetKind: "COVENANT-WYRM",
    assetSymbol: WYRM_ELEMENTS[review.element],
    displayAmount: action,
    tokenId: String(review.serial),
    covenantId: review.covenantId,
    templateHash: review.templateHash,
    counterparty: action === "transfer" ? String(input?.recipient ?? "") : review.covenantId,
    from: [{ address: sender }],
    to: [{ address: action === "transfer" ? String(input?.recipient ?? "") : sender }],
    feeSompi: Number(commitReview.feeSompi) + Number(review.feeSompi),
    mass: review.mass,
    storageMass: review.storageMass,
    type: "covenant-transition",
  });
  lastActivity = Date.now();
  return {
    commitTransactionId: signedCommit.transactionId,
    transactionId: signed.transactionId,
    covenantId: signed.covenantId,
    action,
    nextState: signed.nextState,
    feeSompi: Number(commitReview.feeSompi) + Number(review.feeSompi),
    cell: {
      covenantId: signed.covenantId,
      transactionId: signed.transactionId,
      index: 0,
      valueSompi: signed.valueSompi,
      outputAddress: signed.outputAddress,
      scriptPublicKey: signed.scriptPublicKey,
      state: signed.nextState,
    },
  };
}

async function kcc20Transfer(
  origin: string,
  params: unknown,
  state: Awaited<ReturnType<typeof loadState>>,
  vault: VaultPayload,
) {
  if (state.network !== "mainnet")
    throw rpc(4200, "KCC20 is available on Mainnet only.");
  const input = params as any;
  const sender = String(input?.from ?? state.selectedAddress ?? "");
  const recipient = String(input?.to ?? "");
  const covenantId = String(input?.covenantId ?? "").toLowerCase();
  const amount = Number(String(input?.amount ?? ""));
  if (
    sender !== state.selectedAddress ||
    !/^kaspa:[a-z0-9]{61,63}$/.test(recipient) ||
    !/^[0-9a-f]{64}$/.test(covenantId) ||
    !Number.isSafeInteger(amount) ||
    amount <= 0
  )
    throw rpc(-32602, "Invalid KCC20 request.");
  const entry = state.addresses.find((item) => item.address === sender);
  const wallet = vault.wallets.find((item) => item.id === entry?.walletId);
  if (!entry || entry.watchOnly || !wallet)
    throw rpc(4100, "Selected wallet cannot sign.");
  const verified = await kcc20TransferData(sender, covenantId, amount);
  const funding = await spendingData(sender, state.network);
  const request = {
    sender,
    recipient,
    covenantId,
    ticker: verified.ticker,
    amount,
    decimals: verified.decimals,
    feeRate: funding.feeRate,
    templateHash: verified.templateHash,
    cells: verified.cells,
    fundingUtxosJson: funding.utxosJson,
  };
  const wasm = await core();
  const review = JSON.parse(wasm.prepareKcc20Transfer(JSON.stringify(request)));
  const display = (amount / 10 ** verified.decimals).toLocaleString("en-US", {
    maximumFractionDigits: verified.decimals,
  });
  if (
    !(await approve({
      origin,
      title: "Approve verified KCC20 transfer?",
      description:
        "Kaspire checked indexer cells against the local node and executes the covenant locally.",
      details: kcc20ReviewDetails(
        { ticker: verified.ticker, displayAmount: display, recipient },
        review,
      ),
      rawJson: { request, review },
    }))
  )
    throw rpc(4001, "KCC20 transfer rejected.");
  const signed = JSON.parse(
    wasm.signKcc20Transfer(
      signingSecret(wallet, entry),
      JSON.stringify(request),
      review.reviewHash,
    ),
  );
  await broadcastKcc20(signed.wrpcJson, signed.transactionId);
  await recordWalletActivity(sender, {
    transactionId: signed.transactionId,
    blockTime: Date.now(),
    isAccepted: true,
    incoming: false,
    assetKind: "KCC20",
    assetSymbol: verified.ticker,
    displayAmount: display,
    tokenId: covenantId,
    covenantId: review.covenantId,
    templateHash: review.templateHash,
    counterparty: recipient,
    from: [{ address: sender }],
    to: [{ address: recipient }],
    feeSompi: review.feeSompi,
    inputCount: review.covenantInputCount,
    outputCount: review.covenantOutputCount,
    mass: review.mass,
    computeMass: review.computeMass,
    storageMass: review.storageMass,
    storageMassTarget: review.storageMassTarget,
    transientMass: review.transientMass,
    feeMass: review.feeMass,
    computeBudget: review.computeBudget,
    lockedKasSompi: review.lockedKasSompi,
    lockedKasTopUpSompi: review.lockedKasTopUpSompi,
    lockedKasReleasedSompi: review.lockedKasReleasedSompi,
    lockedKasOutputSompi: review.lockedKasOutputSompi,
    type: "transfer",
  });
  lastActivity = Date.now();
  return signed.transactionId;
}

async function finishPendingInscription(
  origin: string,
  pending: any,
  state: Awaited<ReturnType<typeof loadState>>,
  vault: VaultPayload,
  progress: (stage: string) => void = () => {},
) {
  const generation = sessionGeneration;
  if (state.network !== "mainnet")
    throw new Error("Switch back to Mainnet to resume the reveal.");
  const operation = pending?.operation;
  const plan = pending?.plan;
  const commitTransactionId = String(pending?.commitTransactionId ?? "");
  if (!operation || !plan || !/^[0-9a-f]{64}$/.test(commitTransactionId))
    throw new Error("Pending reveal data is damaged.");
  const entry = state.addresses.find(
    (item) => item.address === operation.sender,
  );
  const wallet = vault.wallets.find((item) => item.id === entry?.walletId);
  if (!entry || entry.watchOnly || !wallet)
    throw new Error("The wallet controlling this reveal is unavailable.");
  progress("Looking for the committed output…");
  const commitUtxosJson = await waitForUtxo(
    plan.commitAddress,
    commitTransactionId,
    state.network,
  );
  const revealRequest = {
    operation,
    commitTransactionId,
    commitUtxosJson,
    feeRate: (await spendingData(plan.commitAddress, state.network)).feeRate,
  };
  const wasm = await core();
  const review = JSON.parse(wasm.prepareReveal(JSON.stringify(revealRequest)));
  progress("Review and authorize the final reveal…");
  if (
    !(await approve({
      origin,
      title: "Resume pending asset reveal?",
      description:
        "The commit is already on-chain. Verify and publish the final asset transfer.",
      details: [
        `Kind: ${operation.kind}`,
        ...(operation.ticker ? [`Ticker: ${operation.ticker}`] : []),
        ...(operation.displayAmount ? [`Amount: ${operation.displayAmount}`] : []),
        ...(operation.tokenId ? [`Token ID: ${operation.tokenId}`] : []),
        `From: ${operation.sender}`,
        `To: ${operation.recipient}`,
        `Reveal fee: ${formatSompi(review.feeSompi)} KAS`,
        `Commit: ${commitTransactionId}`,
      ],
      rawJson: { request: revealRequest, review },
    }))
  )
    throw rpc(4001, "Reveal rejected.");
  const current = await loadState();
  await expireSessionIfNeeded(current);
  if (!sessionVault || generation !== sessionGeneration)
    throw rpc(4100, "Wallet was locked during reveal recovery. Unlock Kaspire and resume again.");
  if (current.network !== state.network || current.selectedAddress !== state.selectedAddress ||
      !current.addresses.some(item => item.address === operation.sender && item.walletId === entry.walletId && !item.watchOnly))
    throw rpc(4100, "Wallet account or network changed during approval. Resume the reveal again.");
  progress("Signing and broadcasting the reveal…");
  const signed = JSON.parse(
    wasm.signReveal(
      signingSecret(wallet, entry),
      JSON.stringify(revealRequest),
      review.reviewHash,
    ),
  );
  const id = await broadcast(signed.submitJson, state.network);
  if (id && id !== signed.transactionId)
    throw new Error("Node returned a mismatching reveal ID.");
  await recordWalletActivity(operation.sender, {
    transactionId: signed.transactionId,
    commitTransactionId,
    blockTime: Date.now(),
    isAccepted: true,
    incoming: false,
    assetKind:
      operation.kind === "krc721"
        ? "KRC-721"
        : operation.kind === "kns"
          ? "KNS"
          : "KRC-20",
    assetSymbol: operation.ticker || operation.domainName || "KNS",
    displayAmount:
      operation.displayAmount ||
      operation.amount ||
      (operation.kind === "krc721" ? "1" : ""),
    tokenId: operation.tokenId || operation.assetId || "",
    counterparty: operation.recipient,
    from: [{ address: operation.sender }],
    to: [{ address: operation.recipient }],
    feeSompi: review.feeSompi,
    type: "transfer",
  });
  await chrome.storage.local.remove("pendingInscription");
  return {
    commitTransactionId,
    revealTransactionId: signed.transactionId,
    revealFeeSompi: review.feeSompi,
  };
}

async function approve(input: Omit<ApprovalView, "id">) {
  if (approvals.size >= 4)
    throw new Error("Too many wallet approvals are already pending.");
  if ([...approvals.values()].some((item) => item.view.origin === input.origin))
    throw new Error("An approval for this site is already pending.");
  const id = crypto.randomUUID();
  const view = { id, ...input };
  return new Promise<boolean>(async (resolve) => {
    const timer = setTimeout(() => {
      approvals.delete(id);
      resolve(false);
    }, 600_000) as unknown as number;
    approvals.set(id, {
      view,
      resolve,
      timer,
      generation: sessionVault ? sessionGeneration : null,
    });
    if (input.origin === "Kaspire Wallet") return;
    try {
      await chrome.windows.create({
        url: chrome.runtime.getURL(
          `approval.html?id=${encodeURIComponent(id)}`,
        ),
        type: "popup",
        width: 430,
        height: 650,
        focused: true,
      });
    } catch {
      clearTimeout(timer);
      approvals.delete(id);
      resolve(false);
    }
  });
}

function rpc(code: number, message: string) {
  return Object.assign(new Error(message), { code });
}
function formatSompi(value: unknown) {
  const sompi = BigInt(String(value));
  const digits = sompi.toString().padStart(9, "0");
  const whole = digits.slice(0, -8);
  const fraction = digits.slice(-8).replace(/0+$/g, "");
  return fraction ? `${whole}.${fraction}` : whole;
}
function formatSignedSompi(value: unknown) {
  const raw = BigInt(String(value));
  return `${raw < 0n ? "-" : ""}${formatSompi(raw < 0n ? -raw : raw)}`;
}
function kcc20ReviewDetails(operation: any, review: any) {
  return [
    `${operation.displayAmount || operation.amount} ${operation.ticker}`,
    `To: ${operation.recipient}`,
    `Covenant ID: ${review.covenantId}`,
    `Template hash: ${review.templateHash}`,
    `Covenant inputs: ${review.covenantInputCount} · outputs: ${review.covenantOutputCount}`,
    `KAS in token inputs: ${formatSompi(review.lockedKasSompi)} KAS`,
    ...(Number(review.lockedKasTopUpSompi)
      ? [`KAS reserve top-up: ${formatSompi(review.lockedKasTopUpSompi)} KAS`]
      : []),
    ...(Number(review.lockedKasReleasedSompi)
      ? [`KAS returned: ${formatSompi(review.lockedKasReleasedSompi)} KAS`]
      : []),
    `KAS in new token cells: ${formatSompi(review.lockedKasOutputSompi)} KAS`,
    `Network fee: ${formatSompi(review.feeSompi)} KAS`,
    `Effective mass: ${Number(review.mass).toLocaleString("en-US")}`,
    `Compute mass: ${Number(review.computeMass).toLocaleString("en-US")}`,
    `Storage mass: ${Number(review.storageMass).toLocaleString("en-US")}`,
    `Transient mass: ${Number(review.transientMass).toLocaleString("en-US")}`,
    `Fee mass: ${Number(review.feeMass).toLocaleString("en-US")}`,
  ];
}
function normalize(error: unknown) {
  const item = error as { code?: unknown; message?: unknown };
  const message =
    typeof item?.message === "string"
      ? item.message
      : typeof error === "string"
        ? error
        : typeof error === "object" && error
          ? String(error)
          : "Kaspire request failed.";
  return {
    code: typeof item?.code === "number" ? item.code : -32603,
    message:
      message && message !== "[object Object]"
        ? message
        : "Kaspire request failed. Check Network diagnostics and try again.",
  };
}
