import { loadState, saveState } from "./state";
import { core } from "./core";
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
  tokenMarket,
  verifyKrc721Ownership,
  waitForUtxo,
  walletAssets,
  walletBalance,
  walletCoreSnapshot,
  walletHistory,
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
  "signPskt",
  "pushTx",
  "signPolicyTransaction",
  "transferKRC721",
  "transferKNS",
]);
const extensionVersion = chrome.runtime.getManifest().version;
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
const preparedEvmTransfers = new Map<string, { request: any; review: any; secret: string; createdAt: number }>();
interface ApprovalView {
  id: string;
  origin: string;
  title: string;
  description: string;
  details: string[];
  rawJson?: unknown;
}
const approvals = new Map<
  string,
  { view: ApprovalView; resolve: (approved: boolean) => void; timer: number }
>();
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
  const autoLockMs = state.settings.autoLockMinutes * 60_000;
  if (state.settings.autoLockMinutes < 0) return;
  if (
    !sessionVault ||
    (autoLockMs > 0 && Date.now() - lastActivity < autoLockMs)
  )
    return;
  sessionVault = null;
  sessionPassword = null;
  await chrome.storage.session.remove(["unlockedVault", "lastActivity"]);
  await saveState({ ...state, locked: true });
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
      clearTimeout(pending.timer);
      approvals.delete(pending.view.id);
      pending.resolve(message.approved === true);
      respond({ result: true });
      return false;
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
    .catch((error) => respond({ error: normalize(error) }));
  return true;
});
chrome.runtime.onConnect.addListener((port) => {
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
  if (sessionVault) await touchSession();
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
    clearTimeout(pending.timer);
    approvals.delete(id);
    pending.resolve(message.approved === true);
    return true;
  }
  if (message.command === "mnemonicWordStatus")
    return JSON.parse(
      (await core()).mnemonicWordStatus(String(message.phrase ?? "")),
    );
  if (message.command === "snapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") return evmWalletSnapshot(state);
    return walletSnapshot(state.selectedAddress, state.network);
  }
  if (message.command === "coreSnapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    return walletCoreSnapshot(state.selectedAddress, state.network);
  }
  if (message.command === "balanceSnapshot") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    if (state.network === "kasplex" || state.network === "igra") return evmWalletSnapshot(state);
    return walletBalance(state.selectedAddress, state.network);
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
    return activityHistory(state.selectedAddress, state.network);
  }
  if (message.command === "market") {
    return state.network === "mainnet"
      ? marketPrice(state.settings.currency)
      : null;
  }
  if (message.command === "evmAddress") return (await evmContext(state)).address;
  if (message.command === "prepareEvmTransfer") {
    if (state.network !== "kasplex" && state.network !== "igra") throw new Error("Select Kasplex or Igra first.");
    const { address, secret } = await evmContext(state);
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
    const id = crypto.randomUUID();
    preparedEvmTransfers.set(id, { request, review, secret, createdAt: Date.now() });
    return { id, review, fee: formatUnits(fee, 18, 18), nativeSymbol: config.nativeSymbol, rawJson: request };
  }
  if (message.command === "submitEvmTransfer") {
    const id = String(message.id ?? ""), prepared = preparedEvmTransfers.get(id);
    if (!prepared || Date.now() - prepared.createdAt > 10 * 60_000) throw new Error("Secure EVM review expired. Review the transfer again.");
    preparedEvmTransfers.delete(id);
    const config = evmConfig(state.network);
    if (!(await approve({ origin: "Kaspire Wallet", title: `Send ${prepared.review.tokenSymbol}`, description: "Review this L2 transaction before signing.", details: [`Network: ${prepared.review.network}`, `Recipient: ${prepared.review.recipient}`, `Amount: ${prepared.review.displayAmount} ${prepared.review.tokenSymbol}`, `Network fee: ${formatUnits(BigInt(prepared.request.gasPriceWei) * BigInt(prepared.request.gasLimit), 18, 18)} ${config.nativeSymbol}`], rawJson: prepared.request }))) throw rpc(4001, "User rejected the transaction.");
    const signed = JSON.parse((await core()).signEvmTransaction(prepared.secret, JSON.stringify(prepared.request), prepared.review.reviewHash));
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
  if (message.command === "nftCollection") {
    if (!state.selectedAddress) throw new Error("No wallet is selected.");
    return nftCollection(
      state.selectedAddress,
      String(message.ticker ?? "").toUpperCase(),
      Number(message.offset ?? 0),
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
      sessionVault = null;
      sessionPassword = null;
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
      sessionVault = null;
      sessionPassword = null;
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
    return (await core()).exportPrivateKey(signingSecret(wallet, entry));
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
    const spend = await spendingData(entry.address, state.network);
    const request = {
      sender: entry.address,
      recipient,
      amountSompi: amount,
      feeRate: spend.feeRate,
      utxosJson: spend.utxosJson,
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
        signingSecret(wallet, entry),
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
    const spend = await spendingData(entry.address, state.network);
    const count = JSON.parse(spend.utxosJson).length;
    if (count < 2) throw new Error("This wallet has fewer than two UTXOs.");
    const request = {
      sender: entry.address,
      recipient: entry.address,
      amountSompi: 0,
      feeRate: spend.feeRate,
      utxosJson: spend.utxosJson,
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
          `${review.inputCount} inputs → ${review.outputCount} output`,
          `Returned: ${review.amountSompi / 100_000_000} KAS`,
          `Network fee: ${formatSompi(review.feeSompi)} KAS`,
        ],
      }))
    )
      throw rpc(4001, "UTXO compound rejected.");
    const signed = JSON.parse(
      wasm.signTransaction(
        signingSecret(wallet, entry),
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
    return finishPendingInscription(
      "Kaspire Wallet",
      pending,
      state,
      sessionVault,
    );
  }
  if (message.command === "prepareAsset") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    return prepareWalletAsset(message, state, progress);
  }
  if (message.command === "confirmPreparedAsset") {
    if (!sessionVault) throw new Error("Unlock Kaspire first.");
    return confirmPreparedAsset(
      String(message.preparedId ?? ""),
      state,
      sessionVault,
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
    let backup: any;
    try {
      backup = JSON.parse(String(message.backup ?? ""));
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
      const addresses = backup.state.addresses.filter(
        (item: any) =>
          typeof item?.address === "string" &&
          typeof item?.walletId === "string",
      );
      if (!addresses.length) throw new Error("Backup contains no wallets.");
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
    sessionVault = null;
    sessionPassword = null;
    await chrome.storage.session.remove(["unlockedVault", "lastActivity"]);
    await saveState({ ...state, locked: true });
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
  await rememberSession(sessionVault);
}
async function hydrateSession() {
  if (sessionVault) return;
  const stored = await chrome.storage.session.get([
    "unlockedVault",
    "lastActivity",
  ]);
  const payload = stored.unlockedVault as VaultPayload | undefined;
  if (payload?.version === 2 && Array.isArray(payload.wallets)) {
    sessionVault = payload;
    lastActivity = Number(stored.lastActivity) || Date.now();
  }
}
async function rememberSession(payload: VaultPayload) {
  lastActivity = Date.now();
  await chrome.storage.session.set({ unlockedVault: payload, lastActivity });
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
async function convertNetwork(
  state: Awaited<ReturnType<typeof loadState>>,
  network: KaspaNetwork,
) {
  const previousNetwork = state.network;
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
  if (previousNetwork === "testnet-10" || network === "testnet-10")
    state.permissions = {};
  await saveState(state);
  return { network, selectedAddress: state.selectedAddress };
}
async function activityHistory(address: string, network: KaspaNetwork) {
  const [node, assets, kcc, stored] = await Promise.all([
    walletHistory(address, network),
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
  const local = (
    Array.isArray(stored.walletActivity) ? stored.walletActivity : []
  )
    .filter((item: any) => item?.wallet === address)
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

const connectableNetworks = ["mainnet", "kasplex", "igra"] as const;
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
    throw rpc(-32602, "Only Mainnet, Kasplex and Igra can be connected.");
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
  if (networks.includes("kasplex") || networks.includes("igra")) {
    if (!sessionVault) throw rpc(4100, "Unlock Kaspire before connecting Layer 2.");
    const { address } = await evmContext(state);
    if (networks.includes("kasplex")) result.kasplex = address;
    if (networks.includes("igra")) result.igra = address;
  }
  return result;
}

async function mainnetProviderState(
  state: Awaited<ReturnType<typeof loadState>>,
) {
  const wasm = await core();
  const addresses = state.addresses.map((entry) => ({
    ...entry,
    address: wasm.addressWithPrefix(entry.address, false),
  }));
  const selectedIndex = state.addresses.findIndex(
    (entry) => entry.address === state.selectedAddress,
  );
  return {
    ...state,
    network: "mainnet" as const,
    addresses,
    selectedAddress:
      (selectedIndex >= 0 ? addresses[selectedIndex]?.address : undefined) ??
      addresses[0]?.address ??
      null,
  };
}

function connectionDetails(
  accounts: Partial<Record<ConnectableNetwork, string>>,
) {
  return connectableNetworks.flatMap((network) =>
    accounts[network]
      ? [
          `${network === "mainnet" ? "Kaspa Mainnet" : network === "kasplex" ? "Kasplex L2" : "Igra L2"}: ${accounts[network]}`,
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
    const mainnetState = await mainnetProviderState(state);
    return mainnetState.selectedAddress ? [mainnetState.selectedAddress] : [];
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
    const mainnetState = await mainnetProviderState(state);
    if (!permissionNetworks(permission, state.network).includes("mainnet"))
      throw rpc(4100, "Kaspa Mainnet is not connected.");
    return walletSnapshot(mainnetState.selectedAddress!, "mainnet");
  }
  if (method === "getUtxoEntries") {
    if (!state.selectedAddress) throw rpc(4100, "No wallet selected.");
    if ((params as any)?.network === "kasplex" || (params as any)?.network === "igra")
      throw rpc(-32601, "UTXOs are not used on Layer 2 networks.");
    if (!permissionNetworks(permission, state.network).includes("mainnet"))
      throw rpc(4100, "Kaspa Mainnet is not connected.");
    const mainnetState = await mainnetProviderState(state);
    return (await walletSnapshot(mainnetState.selectedAddress!, "mainnet")).utxos;
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
        title: `Switch to ${network === "mainnet" ? "Mainnet" : network === "testnet-10" ? "TN10" : network === "kasplex" ? "Kasplex" : "Igra"}?`,
        description:
          "All Kaspire wallet addresses and subsequent requests will use this network.",
        details: ["Existing keys and derivation paths do not change."],
      }))
    )
      throw rpc(4001, "Network switch rejected.");
    await convertNetwork(state, network as KaspaNetwork);
    return network;
  }
  if (
    l1ProviderMethods.has(method) &&
    !permissionNetworks(permission, state.network).includes("mainnet")
  )
    throw rpc(4100, "Kaspa Mainnet is not connected for this site.");
  const providerState = l1ProviderMethods.has(method)
    ? await mainnetProviderState(state)
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
    return broadcast(transaction, "mainnet");
  }
  if (!sessionVault) throw rpc(4100, "Unlock Kaspire before signing.");
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
    const { address, secret } = await evmContext(state);
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
    const signed = JSON.parse(
      wasm.signEvmTransaction(
        secret,
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
    lastActivity = Date.now();
    return {
      address,
      signature: (await core()).signPersonalMessage(
        signingSecret(wallet, entry),
        address,
        message,
      ),
    };
  }
  if (method === "sendKaspa") {
    const input = params as Record<string, unknown> | null;
    const allowed = new Set(["to", "amountSompi", "from"]);
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
    if (
      senderAddress !== providerState.selectedAddress ||
      !/^kaspa(test)?:[a-z0-9]{61,63}$/.test(recipient) ||
      !Number.isSafeInteger(amount) ||
      amount <= 0 ||
      amount > 2_100_000_000_000_000
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
    const spend = await spendingData(senderAddress, "mainnet");
    const request = {
      sender: senderAddress,
      recipient,
      amountSompi: amount,
      feeRate: spend.feeRate,
      utxosJson: spend.utxosJson,
      sendAll: false,
    };
    const wasm = await core();
    const review = JSON.parse(wasm.prepareTransaction(JSON.stringify(request)));
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
    const signed = JSON.parse(
      wasm.signTransaction(
        signingSecret(wallet, entry),
        JSON.stringify(request),
        review.reviewHash,
      ),
    );
    const broadcastId = await broadcast(signed.submitJson, "mainnet");
    if (broadcastId && broadcastId !== signed.transactionId)
      throw rpc(-32000, "Node returned a mismatching transaction ID.");
    lastActivity = Date.now();
    return signed.transactionId;
  }
  if (method === "signPskt") {
    const input = params as any;
    const senderAddress = String(input?.sender ?? providerState.selectedAddress ?? "");
    const signInputs = input?.options?.signInputs ?? input?.signInputs;
    if (
      !input ||
      senderAddress !== providerState.selectedAddress ||
      typeof input.txJsonString !== "string" ||
      !Array.isArray(signInputs)
    )
      throw rpc(-32602, "Invalid PSKT request.");
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
      signInputs,
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
          `Fee: ${(review.feeSompi / 100_000_000).toLocaleString("en-US")} KAS`,
          `Wallet net: ${(review.walletNetSompi / 100_000_000).toLocaleString("en-US")} KAS`,
          `${review.selectedInputCount.toLocaleString("en-US")} of ${review.inputCount.toLocaleString("en-US")} inputs selected`,
          ...warningDetails,
        ],
        rawJson: { request, review },
      }))
    )
      throw rpc(4001, "PSKT signature rejected.");
    lastActivity = Date.now();
    return JSON.parse(
      wasm.signPskt(
        signingSecret(wallet, entry),
        JSON.stringify(request),
        review.reviewHash,
      ),
    ).signedTxJson;
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
        tokenId.length > 128 ||
        !assets.krc721.some(
          (item: any) => String(item.symbol).toUpperCase() === ticker,
        )
      )
        throw new Error("Select a held KRC-721 NFT.");
      operation = { ...operation, ticker, tokenId };
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
      !assets.krc721.some(
        (item: any) => item.symbol.toUpperCase() === ticker,
      ) ||
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
) {
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
  if (
    !(await approve({
      origin,
      title: "Resume pending asset reveal?",
      description:
        "The commit is already on-chain. Verify and publish the final asset transfer.",
      details: [
        `Kind: ${operation.kind}`,
        `To: ${operation.recipient}`,
        `Reveal fee: ${formatSompi(review.feeSompi)} KAS`,
        `Commit: ${commitTransactionId}`,
      ],
    }))
  )
    throw rpc(4001, "Reveal rejected.");
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
  const id = crypto.randomUUID();
  const view = { id, ...input };
  return new Promise<boolean>(async (resolve) => {
    const timer = setTimeout(() => {
      approvals.delete(id);
      resolve(false);
    }, 600_000) as unknown as number;
    approvals.set(id, { view, resolve, timer });
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
