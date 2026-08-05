const root = document.querySelector<HTMLElement>("#app")!;
type View =
  | "home"
  | "wallets"
  | "watch"
  | "create-wallet"
  | "import-seed"
  | "import-key"
  | "rename"
  | "remove"
  | "settings"
  | "display"
  | "security"
  | "network"
  | "address-book"
  | "contact"
  | "my-wallets"
  | "backups"
  | "receive"
  | "activity";
let view: View = "home";
let status: any;
let snapshot: any;
let context: any = {};

async function rawCommand(name: string, values: Record<string, unknown> = {}) {
  let timer: number | undefined;
  try {
    const response = await Promise.race([
      chrome.runtime.sendMessage({
        channel: "wallet",
        command: name,
        ...values,
      }),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () =>
            reject(
              new Error(
                "The secure review did not respond within 30 seconds. Try again.",
              ),
            ),
          30_000,
        ) as unknown as number;
      }),
    ]);
    if (!response)
      throw new Error("Kaspire background service did not return a response.");
    if (response.error)
      throw Object.assign(new Error(response.error.message), response.error);
    return response.result;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
function persistentCommand(name: string, values: Record<string, unknown> = {}) {
  return new Promise<any>((resolve, reject) => {
    const port = chrome.runtime.connect({ name: "wallet-operation" });
    let finished = false;
    const timer = setTimeout(() => {
      if (!finished) {
        finished = true;
        port.disconnect();
        reject(
          new Error(
            "The secure operation did not respond within 45 seconds. Try again.",
          ),
        );
      }
    }, 45_000);
    const close = () => {
      if (!finished) {
        finished = true;
        clearTimeout(timer);
        port.disconnect();
      }
    };
    port.onMessage.addListener((response) => {
      if (response?.progress) {
        const button = document.querySelector<HTMLButtonElement>("#review");
        if (button) button.textContent = response.progress;
        return;
      }
      close();
      response?.error
        ? reject(
            Object.assign(new Error(response.error.message), response.error),
          )
        : resolve(response?.result);
    });
    port.onDisconnect.addListener(() => {
      if (!finished) {
        finished = true;
        clearTimeout(timer);
        reject(
          new Error(
            chrome.runtime.lastError?.message ??
              "Kaspire background operation was interrupted.",
          ),
        );
      }
    });
    port.postMessage({ channel: "wallet", command: name, ...values });
  });
}
function esc(input: any) {
  const node = document.createElement("span");
  node.textContent = String(input ?? "");
  return node.innerHTML;
}
function value(id: string) {
  return (
    document.querySelector<HTMLInputElement | HTMLSelectElement>(`#${id}`)
      ?.value ?? ""
  ).trim();
}
function short(input: string | null) {
  return input ? `${input.slice(0, 11)}…${input.slice(-6)}` : "No wallet";
}
function fmt(input: number, digits = 8) {
  return Number(input || 0).toLocaleString("en-US", {
    maximumFractionDigits: digits,
  });
}
function tokenAmount(raw: string, decimals: number) {
  const input = String(raw ?? "0").padStart(decimals + 1, "0");
  const whole = (decimals ? input.slice(0, -decimals) : input).replace(
    /\B(?=(\d{3})+(?!\d))/g,
    ",",
  );
  const fraction = decimals ? input.slice(-decimals).replace(/0+$/g, "") : "";
  return fraction ? `${whole}.${fraction}` : whole;
}
function rawAmount(input: string, decimals: number) {
  const [whole, fraction = ""] = input.split(".");
  if (fraction.length > decimals)
    throw new Error(`This asset supports at most ${decimals} decimals.`);
  return `${whole}${fraction.padEnd(decimals, "0")}`.replace(/^0+(?=\d)/, "");
}
async function copy(text: string, message = "Copied") {
  await navigator.clipboard.writeText(text);
  toast(message);
}
function toast(message: string, error = false) {
  const item = document.createElement("div");
  item.className = `toast ${error ? "toast-error" : ""}`;
  item.textContent = message;
  document.body.append(item);
  setTimeout(() => item.remove(), 2200);
}
function download(content: string, name: string) {
  const url = URL.createObjectURL(
    new Blob([content], { type: "application/json" }),
  );
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}
const caseWords: Record<string, string> = {
  KAS: "KAS",
  KASPA: "Kaspa",
  KRC20: "KRC20",
  "KRC-20": "KRC-20",
  KRC721: "KRC721",
  "KRC-721": "KRC-721",
  KCC20: "KCC20",
  KNS: "KNS",
  NFT: "NFT",
  NFTS: "NFTs",
  UTXO: "UTXO",
  UTXOS: "UTXOs",
  HUB21: "HUB21",
  BIP39: "BIP39",
  "BIP-39": "BIP-39",
  TN10: "TN10",
  TX: "TX",
  ID: "ID",
  DAPPS: "dApps",
  DAPP: "dApp",
  USD: "USD",
};
function classicCase(container: HTMLElement) {
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
  let node: Node | null;
  while ((node = walker.nextNode())) {
    if (node.parentElement?.closest("[data-preserve-case]")) continue;
    const text = node.textContent ?? "";
    if (!/[A-Z]/.test(text) || text !== text.toUpperCase()) continue;
    node.textContent = text
      .toLowerCase()
      .replace(
        /[a-z0-9]+(?:-[a-z0-9]+)*/g,
        (word, index) =>
          caseWords[word.toUpperCase()] ??
          word[0]!.toUpperCase() + word.slice(1),
      );
  }
}
function ticker(input: unknown) {
  return String(input ?? "")
    .trim()
    .toUpperCase();
}
function shell(content: string, title = "KASPIRE", back = false) {
  root.innerHTML = `<main class="app natural-case"><header class="top">${back ? '<button id="back" class="icon" aria-label="Back">‹</button>' : '<img src="kaspire-icon.png" alt="Kaspire">'}<b>${esc(title)}</b><span></span></header>${content}</main>`;
  classicCase(root);
  document
    .querySelector<HTMLButtonElement>("#back")
    ?.addEventListener("click", () => {
      view =
        view === "wallets" || view === "settings" || view === "home"
          ? "home"
          : (context.returnView ??
            (view === "contact" || view === "my-wallets"
              ? "address-book"
              : "settings"));
      context = {};
      void render();
    });
}

async function render() {
  status = await command("status");
  document.documentElement.dataset.theme = status.settings?.theme ?? "midnight";
  if (!status.hasVault) return onboarding();
  if (status.locked) return unlock();
  if (status.recoveryVerified === false)
    return recovery(await command("pendingRecovery"));
  if (view === "home") return home();
  if (view === "wallets") return wallets();
  if (
    view === "watch" ||
    view === "create-wallet" ||
    view === "import-seed" ||
    view === "import-key" ||
    view === "rename"
  )
    return walletForm();
  if (view === "remove") return removeWallet();
  if (view === "settings") return settings();
  if (view === "display" || view === "security" || view === "backups")
    return settingsDetail();
  if (view === "network") return network();
  if (view === "address-book") return addressBook();
  if (view === "contact") return contactForm();
  if (view === "my-wallets") return myWallets();
  if (view === "receive") return receive();
  if (view === "activity") return activity();
}

function legacyOnboarding(initialMode: "create" | "seed" | "key" = "create") {
  let mode: "create" | "seed" | "key" = initialMode,
    count = 24;
  const paint = () => {
    shell(
      `<section class="onboard"><p class="eyebrow">KASPIRE BROWSER WALLET</p><h1>${mode === "create" ? "Create a secure wallet" : mode === "seed" ? "Import recovery words" : "Import private key"}</h1><div class="segmented"><button data-mode="create" class="${mode === "create" ? "active" : ""}">Create</button><button data-mode="seed" class="${mode === "seed" ? "active" : ""}">Seed</button><button data-mode="key" class="${mode === "key" ? "active" : ""}">Private key</button></div><div class="form">${mode === "seed" ? `<div class="word-count"><button data-count="12" class="${count === 12 ? "active" : ""}">12 words</button><button data-count="24" class="${count === 24 ? "active" : ""}">24 words</button></div><div class="seed-grid">${seedFields(count)}</div><label>BIP-39 passphrase <small>optional</small><input id="passphrase" type="password"></label>` : ""}${mode === "key" ? '<label>Wallet name<input id="wallet-name" value="Imported key"></label><label>Private key<input id="private-key" type="password" maxlength="64"></label>' : mode === "create" ? '<label>BIP-39 passphrase <small>optional</small><input id="passphrase" type="password"></label>' : ""}<label>Vault password<input id="password" type="password" minlength="12"></label><label>Confirm password<input id="password-confirm" type="password" minlength="12"></label><button id="submit">${mode === "create" ? "CREATE WALLET" : mode === "seed" ? "IMPORT WALLET" : "IMPORT PRIVATE KEY"}</button><p id="error" class="error"></p></div></section>`,
    );
    document.querySelectorAll<HTMLButtonElement>("[data-mode]").forEach(
      (button) =>
        (button.onclick = () => {
          mode = button.dataset.mode as typeof mode;
          paint();
        }),
    );
    document.querySelectorAll<HTMLButtonElement>("[data-count]").forEach(
      (button) =>
        (button.onclick = () => {
          count = Number(button.dataset.count);
          paint();
        }),
    );
    if (mode === "seed") wireSeed();
    document.querySelector<HTMLButtonElement>("#submit")!.onclick =
      async () => {
        try {
          const password = value("password");
          if (password !== value("password-confirm"))
            throw new Error("Passwords do not match.");
          if (password.length < 12)
            throw new Error("Use at least 12 characters.");
          if (mode === "key")
            await command("createPrivateKey", {
              password,
              privateKey: value("private-key"),
              name: value("wallet-name"),
            });
          else {
            const result = await command(
              mode === "create" ? "create" : "import",
              {
                password,
                passphrase: value("passphrase"),
                words: mode === "seed" ? readSeed(count) : "",
              },
            );
            if (result.recoveryPhrase) return recovery(result.recoveryPhrase);
          }
          view = "home";
          await render();
        } catch (error) {
          document.querySelector("#error")!.textContent = (
            error as Error
          ).message;
        }
      };
  };
  paint();
}
function seedFields(count: number, words: string[] = []) {
  return Array.from(
    { length: count },
    (_, index) =>
      `<label class="seed-word"><span>${index + 1}</span><input data-word="${index}" value="${esc(words[index] ?? "")}" spellcheck="false"><div class="suggestions"></div></label>`,
  ).join("");
}
function wireSeed() {
  document.querySelectorAll<HTMLInputElement>("[data-word]").forEach(
    (input) =>
      (input.oninput = async () => {
        input.value = input.value.toLowerCase().replace(/[^a-z]/g, "");
        const result = await command("mnemonicWordStatus", {
          phrase: input.value,
        });
        input.classList.toggle(
          "invalid",
          Boolean(
            input.value &&
              result.invalidWords.length &&
              !result.suggestions.length,
          ),
        );
        const box =
          input.parentElement!.querySelector<HTMLElement>(".suggestions")!;
        box.innerHTML = result.suggestions
          .slice(0, 5)
          .map((word: string) => `<button type="button">${word}</button>`)
          .join("");
        box.querySelectorAll("button").forEach(
          (button) =>
            (button.onclick = () => {
              input.value = button.textContent ?? "";
              box.innerHTML = "";
              document
                .querySelector<HTMLInputElement>(
                  `[data-word="${Number(input.dataset.word) + 1}"]`,
                )
                ?.focus();
            }),
        );
      }),
  );
}
function readSeed(count: number) {
  const words = Array.from({ length: count }, (_, index) =>
    document
      .querySelector<HTMLInputElement>(`[data-word="${index}"]`)!
      .value.trim(),
  );
  if (words.some((word) => !word))
    throw new Error(`Enter all ${count} recovery words.`);
  return words.join(" ");
}
function recovery(phrase: string) {
  const words = phrase.split(" ");
  shell(
    `<section class="onboard recovery"><p class="eyebrow">RECOVERY PHRASE</p><h1>Write these words down.</h1><p class="warning-box">Never photograph, copy or share these words.</p><div class="seed-grid read-only">${seedFields(words.length, words)}</div><button id="verify">I SAVED IT OFFLINE</button></section>`,
  );
  document
    .querySelectorAll<HTMLInputElement>("[data-word]")
    .forEach((input) => (input.readOnly = true));
  document.querySelector<HTMLButtonElement>("#verify")!.onclick = () =>
    challenge(words);
}
function challenge(words: string[]) {
  const indexes = new Set<number>();
  while (indexes.size < 3)
    indexes.add(
      (crypto.getRandomValues(new Uint32Array(1))[0] ?? 0) % words.length,
    );
  const chosen = [...indexes].sort((a, b) => a - b);
  shell(
    `<section class="onboard"><p class="eyebrow">VERIFY BACKUP</p><h1>Confirm three words.</h1><div class="verify-grid">${chosen.map((index) => `<label>Word ${index + 1}<input data-check="${index}"></label>`).join("")}</div><button id="finish">VERIFY & CONTINUE</button><p id="error" class="error"></p></section>`,
    "VERIFY SEED",
    true,
  );
  document.querySelector<HTMLButtonElement>("#finish")!.onclick = async () => {
    try {
      await command("verifyRecovery", {
        checks: chosen.map((index) => ({
          index,
          word: document.querySelector<HTMLInputElement>(
            `[data-check="${index}"]`,
          )!.value,
        })),
      });
      view = "home";
      await render();
    } catch (error) {
      document.querySelector("#error")!.textContent = (error as Error).message;
    }
  };
}
function unlock() {
  shell(
    `<section class="unlock"><img class="hero-logo" src="kaspire-icon.png" alt=""><p class="eyebrow">WELCOME BACK</p><h1>Unlock Kaspire</h1><div class="form"><label>Vault password<input id="password" type="password"></label><button id="submit">UNLOCK WALLET</button><p id="error" class="error"></p></div></section>`,
  );
  document.querySelector<HTMLButtonElement>("#submit")!.onclick = async () => {
    try {
      await command("unlock", { password: value("password") });
      view = "home";
      await render();
    } catch (error) {
      document.querySelector("#error")!.textContent = (error as Error).message;
    }
  };
}

function home() {
  const selected = status.addresses.find(
    (item: any) => item.address === status.selectedAddress,
  );
  shell(
    `<section class="dashboard"><div class="wallet-head"><div class="wallet-brand"><button id="wallets" class="wallet-select"><img src="kaspire-icon.png" alt=""><span><b>${esc(selected?.name ?? "Wallet")}</b><small>${short(status.selectedAddress)}</small></span></button><button id="copy-main-address" class="copy-main" title="Copy wallet address" aria-label="Copy wallet address">⧉</button></div><div class="head-buttons"><button id="network" class="pill">● ${status.network === "mainnet" ? "MAINNET" : "TN10"}</button><button id="settings" class="icon">⚙</button></div></div><section class="balance-card"><p>TOTAL BALANCE</p><strong id="balance">— KAS</strong><small id="fiat"></small><button id="privacy" class="eye">${status.settings.hideBalances ? "◉" : "◎"}</button></section><div class="quick-actions"><button id="send"><b>↑</b><span>SEND</span></button><button id="receive"><b>↓</b><span>RECEIVE</span></button><button id="activity"><b>≡</b><span>ACTIVITY</span></button></div><section class="assets"><div class="section-title"><h2>ASSETS & NAMES</h2><span id="asset-count"></span></div><div id="asset-list"><div class="loading">Loading assets…</div></div></section><button id="app-promo" class="app-promo">Kaspire is even better in the app!<span>›</span></button></section>`,
  );
  document.querySelector<HTMLButtonElement>("#wallets")!.onclick = () =>
    go("wallets");
  document.querySelector<HTMLButtonElement>("#copy-main-address")!.onclick =
    () => copy(status.selectedAddress, "Wallet address copied");
  // Mainnet-only UI. Testnet plumbing remains in the provider for a later,
  // explicitly reviewed reactivation.
  document.querySelector<HTMLButtonElement>("#settings")!.onclick = () =>
    go("settings");
  document.querySelector<HTMLButtonElement>("#privacy")!.onclick = async () => {
    await command("setSettings", {
      settings: { hideBalances: !status.settings.hideBalances },
    });
    await render();
  };
  document.querySelector<HTMLButtonElement>("#send")!.onclick = () =>
    send({ kind: "kas" });
  document.querySelector<HTMLButtonElement>("#receive")!.onclick = () =>
    go("receive");
  document.querySelector<HTMLButtonElement>("#activity")!.onclick = () =>
    go("activity");
  document.querySelector<HTMLButtonElement>("#app-promo")!.onclick = () =>
    chrome.tabs.create({ url: "https://kaspire.kaslab.space/" });
  void loadHome();
}
async function legacyLoadHome() {
  try {
    const [core, market] = await Promise.all([
      command("coreSnapshot"),
      command("market").catch(() => null),
    ]);
    snapshot = {
      ...core,
      assets: { tokens: [], domains: [], krc721: [], kcc20: [] },
    };
    if (!document.querySelector("#balance")) return;
    document.querySelector("#balance")!.textContent = status.settings
      .hideBalances
      ? "•••• KAS"
      : `${fmt(core.balanceKas)} KAS`;
    document.querySelector("#fiat")!.textContent =
      market && !status.settings.hideBalances
        ? `≈ ${(core.balanceKas * market.kasUsd * market.rate).toLocaleString(undefined, { style: "currency", currency: market.currency })} · ${core.utxoCount} UTXOs`
        : `${core.utxoCount} UTXOs`;
    const assets = await command("assetsSnapshot");
    if (!document.querySelector("#asset-list")) return;
    snapshot = { ...core, assets };
    const items = [
      ...(assets.tokens ?? []).map((raw: any) => ({
        kind: "krc20",
        symbol: raw.symbol,
        label: "KRC-20",
        balance: tokenAmount(raw.raw_balance, raw.decimals),
        raw,
      })),
      ...(assets.krc721 ?? []).map((raw: any) => ({
        kind: "krc721",
        symbol: raw.symbol,
        label: "KRC-721 NFT",
        balance: String(raw.balance ?? 1),
        raw,
      })),
      ...(assets.domains ?? []).map((raw: any) => ({
        kind: "kns",
        symbol: raw.name,
        label: "KNS name",
        balance: "",
        raw,
      })),
      ...(assets.kcc20 ?? []).map((raw: any) => ({
        kind: "kcc20",
        symbol: raw.symbol,
        label: "KCC20",
        balance: tokenAmount(raw.rawBalance, raw.decimals),
        raw,
      })),
    ];
    document.querySelector("#asset-count")!.textContent = String(items.length);
    document.querySelector("#asset-list")!.innerHTML = items.length
      ? items
          .map(
            (item: any, index: number) =>
              `<button class="asset-row" data-asset="${index}"><span class="asset-icon">${esc(item.symbol.slice(0, 2))}</span><span><b>${esc(item.symbol)}</b><small>${item.label}</small></span><strong>${status.settings.hideBalances ? "••••" : esc(item.balance)}</strong><i>›</i></button>`,
          )
          .join("")
      : '<div class="empty">No assets or names found.</div>';
    document
      .querySelectorAll<HTMLButtonElement>("[data-asset]")
      .forEach(
        (button) =>
          (button.onclick = () =>
            assetDetail(items[Number(button.dataset.asset)])),
      );
  } catch (error) {
    if (document.querySelector("#asset-list"))
      document.querySelector("#asset-list")!.innerHTML =
        `<p class="error">${esc((error as Error).message)}</p>`;
  }
}
function legacyAssetDetail(asset: any) {
  if (asset.kind !== "krc20") return send(asset);
  shell(
    `<section class="token-detail"><div id="token-image" class="token-logo">${esc(asset.symbol.slice(0, 2))}</div><h1>${esc(asset.symbol)}</h1><p>${esc(asset.balance)} ${esc(asset.symbol)}</p><div class="price-grid"><div><small>Floor price</small><b id="floor-kas">Loading…</b><span id="floor-usd"></span></div><div><small>Balance value</small><b id="value-kas">Loading…</b><span id="value-usd"></span></div></div><button id="send-token">SEND ASSET</button><button id="explorer" class="outline">CHECK ON EXPLORER</button></section>`,
    "TOKEN DETAILS",
    true,
  );
  document.querySelector<HTMLButtonElement>("#send-token")!.onclick = () =>
    send(asset);
  void command("tokenMarket", {
    tokenId: String(asset.raw.token_id ?? asset.symbol).replace(/^krc20-/, ""),
    symbol: asset.symbol,
  }).then((market) => {
    const balance = Number(asset.balance.replaceAll(",", ""));
    document.querySelector("#floor-kas")!.textContent =
      market.priceKas == null ? "Unavailable" : `${fmt(market.priceKas)} KAS`;
    document.querySelector("#floor-usd")!.textContent =
      market.priceUsd == null ? "" : `$${fmt(market.priceUsd)}`;
    document.querySelector("#value-kas")!.textContent =
      market.priceKas == null
        ? "Unavailable"
        : `${fmt(market.priceKas * balance)} KAS`;
    document.querySelector("#value-usd")!.textContent =
      market.priceUsd == null ? "" : `$${fmt(market.priceUsd * balance)}`;
    document.querySelector<HTMLButtonElement>("#explorer")!.onclick = () =>
      chrome.tabs.create({ url: market.explorerUrl });
  });
}
function legacySend(asset: any) {
  const owned =
    asset.kind === "krc20"
      ? (snapshot?.assets?.tokens ?? [])
      : asset.kind === "krc721"
        ? (snapshot?.assets?.krc721 ?? [])
        : asset.kind === "kns"
          ? (snapshot?.assets?.domains ?? [])
          : asset.kind === "kcc20"
            ? (snapshot?.assets?.kcc20 ?? [])
            : [];
  shell(
    `<section class="send-screen"><p class="eyebrow">SEND</p><h1>${asset.kind === "kas" ? "Send KAS" : `Send ${esc(asset.symbol ?? asset.kind.toUpperCase())}`}</h1><div class="form">${asset.kind !== "kas" ? `<label>Asset<select id="asset-select">${owned.map((item: any, index: number) => `<option value="${index}" ${item === asset.raw ? "selected" : ""}>${esc(item.symbol ?? item.name)}</option>`).join("")}</select></label>` : ""}<label>Address / KNS name<input id="recipient" list="recipients"></label>${asset.kind === "krc721" ? '<label>Token ID<input id="token-id"></label>' : ""}${["kas", "krc20", "kcc20"].includes(asset.kind) ? `<label>Amount<div class="amount"><input id="amount" inputmode="decimal" placeholder="0.00"><button id="max">MAX</button></div></label><small class="available">Available: ${esc(asset.balance ?? (snapshot ? `${fmt(snapshot.balanceKas)} KAS` : "—"))}</small>` : ""}<section class="tx-meta"><span>Network</span><b>${status.network === "mainnet" ? "Kaspa Mainnet" : "Kaspa TN10"}</b><span>Fee</span><b>Live node estimate</b><span>Signer</span><b>Rusty Kaspa v2.0.1</b></section><button id="review">REVIEW TRANSFER</button><p id="error" class="error"></p></div>${recipients()}</section>`,
    "SEND",
    true,
  );
  const amount = document.querySelector<HTMLInputElement>("#amount");
  if (amount)
    amount.oninput = () => {
      amount.value =
        amount.value
          .replace(",", ".")
          .replace(/[^\d.]/g, "")
          .match(/^\d*(?:\.\d{0,8})?/)?.[0] ?? "";
    };
  document
    .querySelector<HTMLButtonElement>("#max")
    ?.addEventListener("click", () => {
      if (amount)
        amount.value =
          asset.kind === "kas"
            ? String(snapshot?.balanceKas ?? 0)
            : String(asset.balance ?? 0);
    });
  document.querySelector<HTMLButtonElement>("#review")!.onclick = async () => {
    const reviewButton = document.querySelector<HTMLButtonElement>("#review")!;
    reviewButton.disabled = true;
    reviewButton.textContent = "Preparing secure review…";
    try {
      const recipient = value("recipient");
      let result;
      if (asset.kind === "kas") {
        const input = value("amount");
        if (!/^\d+(\.\d{1,8})?$/.test(input))
          throw new Error("Enter a valid amount.");
        const [whole, fraction = ""] = input.split(".");
        result = await command("sendKas", {
          recipient,
          amountSompi: Number(`${whole}${fraction.padEnd(8, "0")}`),
        });
      } else {
        const selected = owned[Number(value("asset-select"))] ?? asset.raw;
        let amountValue = value("amount");
        if (["krc20", "kcc20"].includes(asset.kind))
          amountValue = rawAmount(amountValue, Number(selected.decimals ?? 8));
        result = await command("sendAsset", {
          kind: asset.kind,
          to: recipient,
          ticker: selected.symbol,
          amount: amountValue,
          tokenId: value("token-id"),
          assetId: selected.asset_id,
          covenantId: selected.covenantId,
        });
      }
      transactionReceipt(result, {
        kind: asset.kind,
        recipient,
        amount: value("amount"),
        symbol: asset.symbol ?? "KAS",
      });
    } catch (error) {
      document.querySelector("#error")!.textContent = (error as Error).message;
    }
  };
}
function recipients() {
  const items = [
    ...status.addresses.map((item: any) => ({
      name: `My wallet · ${item.name}`,
      address: item.address,
    })),
    ...status.contacts,
  ];
  return `<datalist id="recipients">${items.map((item: any) => `<option value="${esc(item.address)}">${esc(item.name)}</option>`).join("")}</datalist>`;
}

function walletCard(item: any) {
  return `<article class="wallet-card ${item.watchOnly ? "watch-card" : ""}" data-select="${esc(item.address)}"><div class="wallet-type">${item.watchOnly ? "◉ WATCH WALLET" : "◆ SIGNING WALLET"}</div><div class="wallet-card-main"><span class="wallet-symbol">${item.watchOnly ? "◎" : "▣"}</span><span><b>${esc(item.name)}</b><small>${esc(item.path)}</small><button class="copy-wallet" data-copy="${esc(item.address)}">${short(item.address)} ⧉</button></span></div><div class="wallet-card-actions"><button class="mini rename-wallet" data-address="${esc(item.address)}">RENAME</button><button class="mini danger-outline remove-wallet" data-address="${esc(item.address)}">REMOVE</button></div></article>`;
}
function wallets() {
  const signing = status.addresses.filter(
    (item: any) =>
      !item.watchOnly && (status.settings.showSubwallets || item.index === 0),
  );
  const watches = status.addresses.filter((item: any) => item.watchOnly);
  shell(
    `<section class="wallets-screen"><p class="eyebrow">KASPIRE WALLETS</p><h1>Wallets</h1><h2>SIGNING WALLETS</h2><div class="wallet-list">${signing.map(walletCard).join("") || '<div class="empty">No signing wallets.</div>'}</div><h2>WATCH WALLETS</h2><div class="wallet-list">${watches.map(walletCard).join("") || '<div class="empty">No watch wallets stored.</div>'}</div><div class="wallet-actions"><button id="subwallet">＋ SUBWALLET</button><button id="account">＋ ACCOUNT</button><button id="create-wallet">＋ CREATE WALLET</button><button id="seed" class="outline">IMPORT 12 / 24 WORDS</button><button id="key" class="outline">IMPORT PRIVATE KEY</button><button id="watch" class="outline">ADD WATCH WALLET</button></div></section>`,
    "WALLETS",
    true,
  );
  document.querySelectorAll<HTMLElement>("[data-select]").forEach(
    (card) =>
      (card.onclick = async (event) => {
        if ((event.target as HTMLElement).closest("button")) return;
        await command("select", { address: card.dataset.select });
        view = "home";
        await render();
      }),
  );
  document
    .querySelectorAll<HTMLButtonElement>("[data-copy]")
    .forEach(
      (button) =>
        (button.onclick = () =>
          copy(button.dataset.copy ?? "", "Address copied")),
    );
  document.querySelectorAll<HTMLButtonElement>(".rename-wallet").forEach(
    (button) =>
      (button.onclick = () => {
        context = { address: button.dataset.address, returnView: "wallets" };
        go("rename");
      }),
  );
  document.querySelectorAll<HTMLButtonElement>(".remove-wallet").forEach(
    (button) =>
      (button.onclick = () => {
        context = { address: button.dataset.address, returnView: "wallets" };
        go("remove");
      }),
  );
  document.querySelector<HTMLButtonElement>("#watch")!.onclick = () =>
    go("watch");
  document.querySelector<HTMLButtonElement>("#create-wallet")!.onclick = () =>
    go("create-wallet");
  document.querySelector<HTMLButtonElement>("#seed")!.onclick = () =>
    go("import-seed");
  document.querySelector<HTMLButtonElement>("#key")!.onclick = () =>
    go("import-key");
  document.querySelector<HTMLButtonElement>("#subwallet")!.onclick =
    async () => {
      try {
        await command("addSubwallet");
        await render();
      } catch (error) {
        toast((error as Error).message, true);
      }
    };
  document.querySelector<HTMLButtonElement>("#account")!.onclick = async () => {
    try {
      await command("addAccount");
      await render();
    } catch (error) {
      toast((error as Error).message, true);
    }
  };
}
function walletForm() {
  const mode = view,
    current = status.addresses.find(
      (item: any) => item.address === context.address,
    ),
    countState = { count: 12 };
  const title =
    mode === "watch"
      ? "Add watch wallet"
      : mode === "create-wallet"
        ? "Create a secure wallet"
      : mode === "import-seed"
        ? "Import recovery words"
        : mode === "import-key"
          ? "Import private key"
          : "Rename wallet";
  shell(
    `<section class="form-page"><p class="eyebrow">${mode === "watch" ? "WATCH ONLY" : "KASPIRE WALLET"}</p><h1>${title}</h1>${mode === "watch" ? '<p class="info-box">Watch wallets display public balances and assets, but cannot sign or spend.</p>' : mode === "create-wallet" ? '<p class="info-box">Choose 12 or 24 recovery words. An optional BIP-39 passphrase creates a separate wallet and cannot be recovered from the words alone.</p>' : ""}<div class="form"><label>Wallet name<input id="wallet-name" value="${esc(current?.name ?? (mode === "watch" ? "Watch wallet" : mode === "create-wallet" ? `Wallet ${status.addresses.filter((item: any) => !item.watchOnly && item.account === 0 && item.index === 0).length + 1}` : mode === "import-key" ? "Imported key" : "Imported wallet"))}"></label>${mode === "watch" ? '<label>Kaspa address or name.kas<input id="wallet-address" placeholder="kaspa:… or name.kas"></label>' : mode === "import-key" ? '<label>Private key<input id="private-key" type="password" maxlength="64"></label><label>Vault password<input id="vault-password" type="password"></label>' : mode === "import-seed" ? `<div class="word-count"><button data-count="12" class="active">12 words</button><button data-count="24">24 words</button></div><div id="seed-grid" class="seed-grid">${seedFields(12)}</div><label>BIP-39 passphrase <small>optional</small><input id="passphrase" type="password"></label><label>Vault password<input id="vault-password" type="password"></label>` : mode === "create-wallet" ? '<div class="word-count"><button data-count="12" class="active">12 words</button><button data-count="24">24 words</button></div><label>BIP-39 passphrase <small>optional</small><input id="passphrase" type="password" autocomplete="off"></label><label>Vault password<input id="vault-password" type="password" autocomplete="current-password"></label>' : ""}<button id="save">${mode === "rename" ? "SAVE NAME" : mode === "watch" ? "ADD WATCH WALLET" : mode === "create-wallet" ? "CREATE WALLET" : "IMPORT WALLET"}</button><p id="error" class="error"></p></div></section>`,
    title.toUpperCase(),
    true,
  );
  if (mode === "import-seed" || mode === "create-wallet") {
    if (mode === "import-seed") wireSeed();
    document.querySelectorAll<HTMLButtonElement>("[data-count]").forEach(
      (button) =>
        (button.onclick = () => {
          countState.count = Number(button.dataset.count);
          if (mode === "import-seed")
            document.querySelector("#seed-grid")!.innerHTML = seedFields(
              countState.count,
            );
          document
            .querySelectorAll("[data-count]")
            .forEach((item) =>
              item.classList.toggle(
                "active",
                (item as HTMLElement).dataset.count ===
                  String(countState.count),
              ),
            );
          if (mode === "import-seed") wireSeed();
        }),
    );
  }
  document.querySelector<HTMLButtonElement>("#save")!.onclick = async () => {
    try {
      if (mode === "watch")
        await command("addWatch", {
          name: value("wallet-name"),
          address: value("wallet-address"),
        });
      else if (mode === "import-key")
        await command("addPrivateKey", {
          name: value("wallet-name"),
          privateKey: value("private-key"),
          password: value("vault-password"),
        });
      else if (mode === "import-seed")
        await command("addMnemonic", {
          name: value("wallet-name"),
          words: readSeed(countState.count),
          passphrase: value("passphrase"),
          password: value("vault-password"),
        });
      else if (mode === "create-wallet") {
        const result = await command("addGeneratedMnemonic", {
          name: value("wallet-name"),
          wordCount: countState.count,
          passphrase: value("passphrase"),
          password: value("vault-password"),
        });
        context = {};
        return recovery(result.recoveryPhrase);
      }
      else
        await command("rename", {
          address: context.address,
          name: value("wallet-name"),
        });
      context = {};
      view = "wallets";
      await render();
    } catch (error) {
      document.querySelector("#error")!.textContent = (error as Error).message;
    }
  };
}
function removeWallet() {
  const item = status.addresses.find(
    (entry: any) => entry.address === context.address,
  );
  shell(
    `<section class="confirm-page"><div class="confirm-icon">!</div><h1>Remove ${esc(item?.name ?? "wallet")}?</h1><p>${item?.watchOnly ? "This removes only the watch-wallet entry." : "Verify your offline backup before removing a signing address."}</p><button id="remove" class="danger">REMOVE WALLET</button><button id="cancel" class="outline">CANCEL</button><p id="error" class="error"></p></section>`,
    "CONFIRM",
    true,
  );
  document.querySelector<HTMLButtonElement>("#cancel")!.onclick = () =>
    go("wallets");
  document.querySelector<HTMLButtonElement>("#remove")!.onclick = async () => {
    try {
      await command("removeAddress", { address: context.address });
      context = {};
      view = "wallets";
      await render();
    } catch (error) {
      document.querySelector("#error")!.textContent = (error as Error).message;
    }
  };
}

function settingsLink(
  icon: string,
  title: string,
  subtitle: string,
  target: View,
) {
  return `<button class="settings-link" data-view="${target}"><span class="setting-icon">${icon}</span><span><b>${title}</b><small>${subtitle}</small></span><i>›</i></button>`;
}
function settings() {
  shell(
    `<section class="settings"><div class="settings-title"><span><p class="eyebrow">KASPIRE</p><h1>Settings</h1></span><button id="hub21"><img src="hub21-wordmark.png" alt="HUB21"></button></div>${settingsLink("⌾", "Security", "Automatic lock · encrypted vault", "security")}${settingsLink("▣", "Wallets", "Signing · watch · accounts · subwallets", "wallets")}${settingsLink("◉", "Wallet display", `${status.settings.currency} · ${status.settings.theme} · privacy`, "display")}${settingsLink("◎", "Network", "Endpoint · dApp sessions · diagnostics", "network")}${settingsLink("♙", "Address book", "Contacts · recipient allowlist", "address-book")}${settingsLink("⇩", "Backups", "Encrypted backup · recovery · private key", "backups")}<details class="settings-group"><summary><span class="setting-icon">↗</span><b>HUB21 Toolbox</b><i>›</i></summary><div class="settings-content">${toolbox()}</div></details><button id="lock" class="outline settings-lock">LOCK KASPIRE</button><footer class="settings-about"><span>Kaspire Extension</span><b>Version ${esc(chrome.runtime.getManifest().version)}</b><button id="report-bug" class="report-bug"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21.7 3.2 18.5 20c-.2 1.2-.9 1.5-1.9.9l-4.9-3.6-2.4 2.3c-.3.3-.5.5-1 .5l.4-5 9.1-8.2c.4-.4-.1-.6-.6-.2L6 13.7l-4.8-1.5c-1.1-.3-1.1-1 .2-1.5L20.2 3c.9-.3 1.7.2 1.5.2Z"/></svg><span>Report a bug</span></button></footer></section>`,
    "SETTINGS",
    true,
  );
  document.querySelector<HTMLButtonElement>("#hub21")!.onclick = () =>
    chrome.tabs.create({ url: "https://kaslab.space" });
  document.querySelector<HTMLButtonElement>("#report-bug")!.onclick = () =>
    chrome.tabs.create({ url: "https://t.me/kaspirewallet" });
  document
    .querySelectorAll<HTMLButtonElement>("[data-view]")
    .forEach(
      (button) => (button.onclick = () => go(button.dataset.view as View)),
    );
  document.querySelector<HTMLButtonElement>("#lock")!.onclick = async () => {
    await command("lock");
    await render();
  };
  wireLinks();
}
function settingsDetail() {
  if (view === "security")
    shell(
      `<section class="form-page"><h1>Security</h1><div class="form"><label>Automatic wallet lock<select id="autolock">${[1, 5, 15, 30, 60].map((minutes) => `<option value="${minutes}" ${status.settings.autoLockMinutes === minutes ? "selected" : ""}>${minutes} minutes</option>`).join("")}</select></label><div class="endpoint-card"><b>Hardware-backed browser vault</b><span>Argon2id + AES-256-GCM</span><small>Secrets remain encrypted at rest.</small></div></div></section>`,
      "SECURITY",
      true,
    );
  else if (view === "display")
    shell(
      `<section class="form-page"><h1>Wallet display</h1><div class="form"><label>Currency<select id="currency">${["USD", "EUR", "GBP", "AUD", "CAD", "JPY", "CNY", "CHF", "INR", "BRL", "KRW"].map((code) => `<option ${status.settings.currency === code ? "selected" : ""}>${code}</option>`).join("")}</select></label><label>Kaspire design<select id="theme">${["midnight", "emerald", "amethyst", "sakura", "crimson", "phoenix", "cypherpunk"].map((theme) => `<option ${status.settings.theme === theme ? "selected" : ""}>${theme}</option>`).join("")}</select></label>${toggle("show-subwallets", "Show subwallets", status.settings.showSubwallets)}${toggle("hide", "Privacy: hide wallet amounts", status.settings.hideBalances)}</div></section>`,
      "WALLET DISPLAY",
      true,
    );
  else
    shell(
      `<section class="form-page"><h1>Backups</h1><p class="info-box">All sensitive actions stay inside Kaspire.</p><button id="backup">EXPORT ENCRYPTED BACKUP</button><button id="restore" class="outline">RESTORE ENCRYPTED BACKUP</button><button id="recovery" class="danger-outline">EXPORT RECOVERY PHRASE</button><button id="private" class="danger-outline">EXPORT PRIVATE KEY</button></section>`,
      "BACKUPS",
      true,
    );
  if (view === "security")
    document.querySelector<HTMLSelectElement>("#autolock")!.onchange = (
      event,
    ) =>
      void command("setSettings", {
        settings: {
          autoLockMinutes: Number((event.target as HTMLSelectElement).value),
        },
      });
  if (view === "display") {
    const keys: any = {
      "show-subwallets": "showSubwallets",
      hide: "hideBalances",
    };
    Object.entries(keys).forEach(
      ([id, key]) =>
        (document.querySelector<HTMLInputElement>(`#${id}`)!.onchange = (
          event,
        ) =>
          void command("setSettings", {
            settings: {
              [String(key)]: (event.target as HTMLInputElement).checked,
            },
          })),
    );
    document.querySelector<HTMLSelectElement>("#currency")!.onchange = (
      event,
    ) =>
      void command("setSettings", {
        settings: { currency: (event.target as HTMLSelectElement).value },
      });
    document.querySelector<HTMLSelectElement>("#theme")!.onchange = async (
      event,
    ) => {
      await command("setSettings", {
        settings: { theme: (event.target as HTMLSelectElement).value },
      });
      await render();
    };
  }
  if (view === "backups") wireBackup();
}
function toggle(id: string, label: string, checked: boolean) {
  return `<label class="toggle-row"><span>${label}</span><input id="${id}" type="checkbox" ${checked ? "checked" : ""}></label>`;
}
function toolbox() {
  return [
    ["Token Explorer", "https://kaspatoken.kaslab.space"],
    ["KasCoven Vaults", "https://vaults.kaslab.space"],
    ["Kaspa Dev Tools", "https://devtools.kaslab.space"],
    ["KCC20 Indexer", "https://kcc20.info"],
    ["Discover more", "https://kaslab.space"],
  ]
    .map(
      ([name, url]) =>
        `<button class="tool-link outline" data-url="${url}">${name}<span>↗</span></button>`,
    )
    .join("");
}
function wireLinks() {
  document
    .querySelectorAll<HTMLButtonElement>(".tool-link")
    .forEach(
      (button) =>
        (button.onclick = () =>
          chrome.tabs.create({ url: button.dataset.url ?? "" })),
    );
}
function wireBackup() {
  for (const action of ["backup", "restore", "recovery", "private"])
    document.querySelector<HTMLButtonElement>(`#${action}`)!.onclick = () =>
      secretAction(action);
}
function secretAction(action: string) {
  const backup = action === "backup",
    restore = action === "restore";
  shell(
    `<section class="form-page"><p class="eyebrow">SECURE ACTION</p><h1>${backup ? "Encrypted portable backup" : restore ? "Restore encrypted backup" : "Confirm vault password"}</h1>${backup ? '<p class="info-box">Choose a unique password. Kaspire cannot recover this password or a lost BIP-39 passphrase.</p>' : restore ? '<p class="info-box">Paste the complete kaspire-backup-v1 or v2 JSON. It is decrypted only inside Kaspire.</p>' : ""}<div class="form">${restore ? '<label>Encrypted Kaspire backup<textarea id="backup-code" rows="7" placeholder="Paste the complete backup text"></textarea></label>' : ""}<label>${backup ? "Backup password (12+ characters)" : "Vault password"}<input id="secret-password" type="password"></label>${backup ? '<label>Confirm backup password<input id="confirm-password" type="password"></label>' : ""}<button id="continue">${backup ? "ENCRYPT BACKUP" : restore ? "RESTORE" : "CONTINUE"}</button><p id="error" class="error"></p><pre id="secret" hidden></pre><div id="backup-actions" hidden><button id="copy-backup" class="outline">COPY BACKUP TEXT</button><button id="save-backup" class="outline">SAVE JSON FILE</button></div></div></section>`,
    "AUTHORIZE",
    true,
  );
  document.querySelector<HTMLButtonElement>("#continue")!.onclick =
    async () => {
      try {
        const password = value("secret-password");
        if (backup) {
          if (password.length < 12)
            throw new Error("Use at least 12 characters.");
          if (password !== value("confirm-password"))
            throw new Error("Backup passwords do not match.");
          const secret = await command("exportBackup", { password });
          const output = document.querySelector<HTMLElement>("#secret")!;
          output.hidden = false;
          output.textContent = secret;
          const actions =
            document.querySelector<HTMLElement>("#backup-actions")!;
          actions.hidden = false;
          document.querySelector<HTMLButtonElement>("#copy-backup")!.onclick =
            () => copy(secret, "Encrypted backup copied");
          document.querySelector<HTMLButtonElement>("#save-backup")!.onclick =
            () => download(secret, "kaspire-backup-v2.json");
          document.querySelector<HTMLInputElement>("#secret-password")!.value =
            "";
          document.querySelector<HTMLInputElement>("#confirm-password")!.value =
            "";
        } else if (restore) {
          await command("importBackup", {
            password,
            backup: value("backup-code"),
          });
          toast("Backup restored");
          view = "home";
          await render();
        } else {
          const secret = await command("exportSecret", {
            password,
            type: action,
          });
          const output = document.querySelector<HTMLElement>("#secret")!;
          output.hidden = false;
          output.textContent = secret;
        }
      } catch (error) {
        document.querySelector("#error")!.textContent = (
          error as Error
        ).message;
      }
    };
}

function network() {
  shell(
    `<section class="network-screen"><p class="eyebrow">NETWORK</p><h1>Kaspa Mainnet</h1><div class="endpoint-card"><b>Kaspa endpoint</b><code>https://kaspire.kaslab.space/api</code><small>Own Kaspire node gateway</small></div><div class="network-list"><div><span>KRC-20 / KNS / KRC-721</span><b>KaspaToken + fallbacks</b></div><div><span>KCC20</span><b>kcc20.info</b></div><div><span>Connection</span><b>Encrypted browser provider</b></div><div><span>Connected dApps</span><b>${Object.keys(status.permissions).length}</b></div></div><button id="diagnostics">RUN NETWORK DIAGNOSTICS</button><div id="results"></div></section>`,
    "NETWORK",
    true,
  );
  document.querySelector<HTMLButtonElement>("#diagnostics")!.onclick =
    async () => {
      const output = document.querySelector<HTMLElement>("#results")!;
      output.innerHTML = '<div class="loading">Running checks…</div>';
      const checks = await command("networkDiagnostics");
      output.innerHTML = checks
        .map(
          (check: any) =>
            `<article class="diagnostic ${check.ok ? "ok" : "fail"}"><b>${check.ok ? "●" : "!"} ${esc(check.name)}</b><code>${esc(check.url)}</code><span>${esc(check.detail)} · ${check.elapsedMs} ms</span></article>`,
        )
        .join("");
    };
}
function addressBook() {
  shell(
    `<section class="address-book"><p class="eyebrow">RECIPIENTS</p><h1>Address book</h1><label class="allowlist"><span><b>Only allow saved recipients</b><small>Blocks transfers to addresses outside this address book.</small></span><input id="allowlist" type="checkbox" ${status.settings.recipientAllowlist ? "checked" : ""}></label><div class="contact-list">${status.contacts.map((item: any) => `<article><span class="contact-avatar">♙</span><span><b>${esc(item.name)}</b><small>${short(item.address)}</small></span><button class="mini edit" data-id="${item.id}">EDIT</button><button class="mini danger-outline delete" data-id="${item.id}">×</button></article>`).join("") || '<div class="empty">No saved contacts.</div>'}</div><div class="bottom-actions"><button id="mine" class="outline">MY WALLETS</button><button id="add">ADD CONTACT</button></div></section>`,
    "ADDRESS BOOK",
    true,
  );
  document.querySelector<HTMLInputElement>("#allowlist")!.onchange = (event) =>
    void command("setSettings", {
      settings: {
        recipientAllowlist: (event.target as HTMLInputElement).checked,
      },
    });
  document.querySelector<HTMLButtonElement>("#mine")!.onclick = () =>
    go("my-wallets");
  document.querySelector<HTMLButtonElement>("#add")!.onclick = () => {
    context = { returnView: "address-book" };
    go("contact");
  };
  document.querySelectorAll<HTMLButtonElement>(".edit").forEach(
    (button) =>
      (button.onclick = () => {
        context = { contactId: button.dataset.id, returnView: "address-book" };
        go("contact");
      }),
  );
  document.querySelectorAll<HTMLButtonElement>(".delete").forEach(
    (button) =>
      (button.onclick = async () => {
        await command("removeContact", { id: button.dataset.id });
        await render();
      }),
  );
}
function contactForm() {
  const contact = status.contacts.find(
    (item: any) => item.id === context.contactId,
  );
  shell(
    `<section class="form-page"><p class="eyebrow">ADDRESS BOOK</p><h1>${contact ? "Edit contact" : "Add contact"}</h1><div class="form"><label>Name<input id="name" value="${esc(contact?.name ?? "")}"></label><label>Kaspa address or name.kas<input id="address" value="${esc(contact?.address ?? "")}"></label><button id="save">SAVE CONTACT</button><p id="error" class="error"></p></div></section>`,
    "CONTACT",
    true,
  );
  document.querySelector<HTMLButtonElement>("#save")!.onclick = async () => {
    try {
      await command(contact ? "editContact" : "addContact", {
        id: contact?.id,
        name: value("name"),
        address: value("address"),
      });
      context = {};
      view = "address-book";
      await render();
    } catch (error) {
      document.querySelector("#error")!.textContent = (error as Error).message;
    }
  };
}
function myWallets() {
  shell(
    `<section class="wallets-screen"><p class="eyebrow">ADDRESS BOOK</p><h1>My wallets</h1><div class="wallet-list">${status.addresses.map((item: any) => `<article class="my-wallet"><span class="wallet-symbol">${item.watchOnly ? "◎" : "▣"}</span><span><b>${esc(item.name)}</b><small>${esc(item.watchOnly ? "Watch wallet" : item.path)}</small><code>${esc(item.address)}</code></span><button class="mini own-copy" data-address="${esc(item.address)}">COPY</button></article>`).join("")}</div></section>`,
    "MY WALLETS",
    true,
  );
  document
    .querySelectorAll<HTMLButtonElement>(".own-copy")
    .forEach(
      (button) =>
        (button.onclick = () =>
          copy(button.dataset.address ?? "", "Wallet address copied")),
    );
}
function receive() {
  const current = status.addresses.find(
    (item: any) => item.address === status.selectedAddress,
  );
  shell(
    `<section class="receive"><div class="receive-icon">↓</div><p class="eyebrow">RECEIVE KASPA</p><h1>${esc(current?.name ?? "Wallet")}</h1><div class="address-full">${esc(status.selectedAddress)}</div><button id="copy">COPY ADDRESS</button><p>Only send assets for the selected network.</p></section>`,
    "RECEIVE",
    true,
  );
  document.querySelector<HTMLButtonElement>("#copy")!.onclick = () =>
    copy(status.selectedAddress, "Address copied");
}
async function legacyActivity() {
  shell(
    '<section class="activity"><p class="eyebrow">ACTIVITY</p><h1>Transactions</h1><div id="history"><div class="loading">Loading activity…</div></div></section>',
    "ACTIVITY",
    true,
  );
  try {
    const rows = await command("history");
    document.querySelector("#history")!.innerHTML = rows.length
      ? rows
          .map(
            (item: any) =>
              `<details class="tx"><summary><span>${item.isAccepted ? "●" : "○"}</span><b>${short(item.transactionId)}</b><i>›</i></summary><div><label>Transaction ID</label><code>${esc(item.transactionId)}</code><button class="mini tx-copy" data-id="${item.transactionId}">COPY TX ID</button><p>${item.inputs.length} inputs · ${item.outputs.length} outputs · mass ${item.mass}</p><pre>${esc(JSON.stringify({ inputs: item.inputs, outputs: item.outputs, payload: item.payload }, null, 2))}</pre></div></details>`,
          )
          .join("")
      : '<div class="empty">No transactions found.</div>';
    document
      .querySelectorAll<HTMLButtonElement>(".tx-copy")
      .forEach(
        (button) =>
          (button.onclick = () =>
            copy(button.dataset.id ?? "", "Transaction ID copied")),
      );
  } catch (error) {
    document.querySelector("#history")!.innerHTML =
      `<p class="error">${esc((error as Error).message)}</p>`;
  }
}
async function loadHome() {
  try {
    const balance = await command("balanceSnapshot");
    snapshot = {
      ...balance,
      utxoCount: 0,
      utxos: [],
      assets: { tokens: [], domains: [], krc721: [], kcc20: [] },
    };
    if (!document.querySelector("#balance")) return;
    document.querySelector("#balance")!.textContent = status.settings
      .hideBalances
      ? "•••• KAS"
      : `${fmt(balance.balanceKas)} KAS`;
    document.querySelector("#fiat")!.textContent = "Loading market value…";
    void command("market")
      .then((market) => {
        if (!document.querySelector("#fiat")) return;
        document.querySelector("#fiat")!.textContent =
          market && !status.settings.hideBalances
            ? `≈ ${(balance.balanceKas * market.kasUsd * market.rate).toLocaleString("en-US", { style: "currency", currency: market.currency })}`
            : "Live balance";
      })
      .catch(() => {
        if (document.querySelector("#fiat"))
          document.querySelector("#fiat")!.textContent = "Live balance";
      });
    void command("coreSnapshot").then((core) => {
      snapshot = { ...snapshot, ...core };
      if (document.querySelector("#fiat"))
        document.querySelector("#fiat")!.textContent +=
          " · " + fmt(core.utxoCount, 0) + " UTXOs";
      addCompound(core);
    });
    const assets = await command("assetsSnapshot");
    if (!document.querySelector("#asset-list")) return;
    snapshot = { ...snapshot, assets };
    renderAssetGroups(assets);
  } catch (error) {
    if (document.querySelector("#asset-list"))
      document.querySelector("#asset-list")!.innerHTML =
        `<p class="error">${esc((error as Error).message)}</p>`;
  }
}
function renderAssetGroups(assets: any) {
  const groups = [
    {
      key: "krc20",
      title: "KRC-20 TOKENS",
      items: (assets.tokens ?? []).map((raw: any) => ({
        kind: "krc20",
        symbol: ticker(raw.symbol),
        balance: tokenAmount(raw.raw_balance, raw.decimals),
        raw: { ...raw, symbol: ticker(raw.symbol) },
      })),
    },
    {
      key: "kcc20",
      title: "KCC20 COVENANT TOKENS",
      items: (assets.kcc20 ?? []).map((raw: any) => ({
        kind: "kcc20",
        symbol: ticker(raw.symbol),
        balance: tokenAmount(raw.rawBalance, raw.decimals),
        raw: { ...raw, symbol: ticker(raw.symbol) },
      })),
    },
    {
      key: "krc721",
      title: "KRC-721 COLLECTIONS",
      items: (assets.krc721 ?? []).map((raw: any) => ({
        kind: "krc721",
        symbol: ticker(raw.symbol),
        balance: String(raw.balance ?? 1),
        raw: { ...raw, symbol: ticker(raw.symbol) },
      })),
    },
    {
      key: "kns",
      title: "KNS DOMAINS",
      items: (assets.domains ?? []).map((raw: any) => ({
        kind: "kns",
        symbol: raw.name,
        balance: "",
        raw,
      })),
    },
  ].filter((group) => group.items.length);
  document.querySelector("#asset-count")!.textContent = String(
    groups.reduce((sum, group) => sum + group.items.length, 0),
  );
  document.querySelector("#asset-list")!.innerHTML = groups.length
    ? groups
        .map(
          (group) =>
            `<details class="asset-group"><summary><span class="group-icon">▱</span><span><b>${group.title}</b><small>${group.items.length} asset${group.items.length === 1 ? "" : "s"}</small></span><i>⌄</i></summary><div>${group.key === "kns" ? `<div class="kns-chips">${group.items.map((item: any, index: number) => `<button data-group="${group.key}" data-index="${index}">◎ ${esc(item.symbol)}</button>`).join("")}</div>` : group.items.map((item: any, index: number) => `<button class="asset-row" data-group="${group.key}" data-index="${index}"><span class="asset-icon" id="icon-${group.key}-${index}">${item.raw.image_url ? `<img src="${esc(item.raw.image_url)}" alt="">` : esc(item.symbol.slice(0, 1))}</span><span><b data-preserve-case>${esc(item.symbol)}</b><small>${status.settings.hideBalances ? "••••••" : esc(item.balance)}</small></span><i>›</i></button>`).join("")}</div></details>`,
        )
        .join("")
    : '<div class="empty">No assets or names found.</div>';
  for (const group of groups)
    document
      .querySelectorAll<HTMLButtonElement>(`[data-group="${group.key}"]`)
      .forEach(
        (button) =>
          (button.onclick = () =>
            assetDetail(group.items[Number(button.dataset.index)])),
      );
  const tokens = groups.find((group) => group.key === "krc20")?.items ?? [];
  tokens.forEach(
    (item: any, index: number) =>
      void command("tokenMarket", {
        tokenId: item.raw.token_id ?? `krc20-${item.symbol.toLowerCase()}`,
        symbol: item.symbol,
      })
        .then((market) => {
          item.market = market;
          const icon = document.querySelector<HTMLElement>(
            `#icon-krc20-${index}`,
          );
          if (icon && market.imageUrl)
            icon.innerHTML = `<img src="${esc(market.imageUrl)}" alt="">`;
        })
        .catch(() => undefined),
  );
}
function assetDetail(asset: any) {
  if (asset.kind === "krc721") return nftGallery(asset);
  if (asset.kind === "kcc20" && asset.raw?.standard === "kron-native")
    return kronDetail(asset);
  if (asset.kind !== "krc20") return send(asset);
  shell(
    `<section class="token-detail"><div id="token-image" class="token-logo">${esc(asset.symbol.slice(0, 2))}</div><h1>${esc(asset.symbol)}</h1><p>${esc(asset.balance)} ${esc(asset.symbol)}</p><div class="price-grid"><div><small>Floor price</small><b id="floor-kas">Loading…</b><span id="floor-usd"></span></div><div><small>Balance value</small><b id="value-kas">Loading…</b><span id="value-usd"></span></div></div><button id="send-token">SEND ASSET</button><button id="explorer" class="outline">CHECK ON EXPLORER</button><p id="market-error" class="error"></p></section>`,
    "TOKEN DETAILS",
    true,
  );
  document.querySelector<HTMLButtonElement>("#send-token")!.onclick = () =>
    send(asset);
  const apply = (market: any) => {
    const balance = Number(asset.balance.replaceAll(",", ""));
    document.querySelector("#floor-kas")!.textContent =
      market.priceKas == null ? "—" : `${fmt(market.priceKas)} KAS`;
    document.querySelector("#floor-usd")!.textContent =
      market.priceUsd == null ? "—" : `$${fmt(market.priceUsd)}`;
    document.querySelector("#value-kas")!.textContent =
      market.priceKas == null ? "—" : `${fmt(market.priceKas * balance)} KAS`;
    document.querySelector("#value-usd")!.textContent =
      market.priceUsd == null ? "—" : `$${fmt(market.priceUsd * balance)}`;
    if (market.imageUrl)
      document.querySelector("#token-image")!.innerHTML =
        `<img src="${esc(market.imageUrl)}" alt="">`;
    document.querySelector<HTMLButtonElement>("#explorer")!.onclick = () =>
      chrome.tabs.create({ url: market.explorerUrl });
  };
  if (asset.market) apply(asset.market);
  else
    void command("tokenMarket", {
      tokenId: asset.raw.token_id ?? `krc20-${asset.symbol.toLowerCase()}`,
      symbol: asset.symbol,
    })
      .then(apply)
      .catch((error) => {
        document.querySelector("#floor-kas")!.textContent = "—";
        document.querySelector("#value-kas")!.textContent = "—";
        document.querySelector("#market-error")!.textContent = (
          error as Error
        ).message;
      });
}
function kronDetail(asset: any) {
  const image = asset.raw?.image_url
    ? `<img src="${esc(asset.raw.image_url)}" alt="">`
    : esc(asset.symbol.slice(0, 2));
  shell(
    `<section class="token-detail"><div class="token-logo">${image}</div><h1>${esc(asset.symbol)}</h1><p>${esc(asset.raw?.name ?? "KRON Native token")}</p><strong>${esc(asset.balance)} ${esc(asset.symbol)}</strong><div class="review-card"><div><span>Standard</span><b>KRON Native KCC20</b></div><div><span>Verification</span><b>Template verified</b></div><div><span>Covenant ID</span><b class="wrap-id">${esc(asset.raw.covenantId)}</b></div></div><button id="send-kron">Send asset</button><button id="kcc-explorer" class="outline">Check on KCC20 Explorer</button><p class="hint">The KRON covenant transaction is built locally, reviewed by Kaspire and signed only after your approval.</p></section>`,
    "TOKEN DETAILS",
    true,
  );
  document.querySelector<HTMLButtonElement>("#send-kron")!.onclick = () =>
    send(asset);
  document.querySelector<HTMLButtonElement>("#kcc-explorer")!.onclick = () =>
    chrome.tabs.create({ url: asset.raw.explorerUrl });
}
async function nftGallery(asset: any) {
  shell(
    `<section class="nft-screen"><p class="eyebrow">KRC-721 COLLECTION</p><h1>${esc(asset.symbol)} NFTs</h1><p id="nft-count" class="muted">Loading held token IDs…</p><div id="nft-grid" class="nft-grid"><div class="loading">Loading gallery…</div></div><button id="load-more" hidden>LOAD MORE</button></section>`,
    `${asset.symbol} NFTs`,
    true,
  );
  let offset = 0;
  const load = async (more = false) => {
    try {
      const page = await command("nftCollection", {
        ticker: asset.symbol,
        offset,
      });
      if (!document.querySelector("#nft-grid")) return;
      document.querySelector("#nft-count")!.textContent =
        `${page.total} NFTs held`;
      const html = page.nfts
        .map(
          (nft: any, index: number) =>
            `<button class="nft-card" data-nft='${esc(JSON.stringify(nft))}'><span>${nft.imageUrl ? `<img src="${esc(nft.imageUrl)}" alt="${esc(nft.ticker)} #${esc(nft.tokenId)}">` : "<b>NO IMAGE</b>"}</span><b>#${esc(nft.tokenId)}</b><small>${nft.rarityRank == null ? "RANK —" : `RANK #${nft.rarityRank}`}</small></button>`,
        )
        .join("");
      if (more)
        document
          .querySelector("#nft-grid")!
          .insertAdjacentHTML("beforeend", html);
      else
        document.querySelector("#nft-grid")!.innerHTML =
          html || '<div class="empty">No NFTs returned.</div>';
      document
        .querySelectorAll<HTMLButtonElement>(".nft-card")
        .forEach(
          (button) =>
            (button.onclick = () =>
              nftPreview(JSON.parse(button.dataset.nft ?? "{}"), asset)),
        );
      const loadMore = document.querySelector<HTMLButtonElement>("#load-more")!;
      loadMore.hidden = page.nextOffset == null;
      if (page.nextOffset != null) {
        offset = page.nextOffset;
        loadMore.onclick = () => void load(true);
      }
    } catch (error) {
      document.querySelector("#nft-grid")!.innerHTML =
        `<p class="error">${esc((error as Error).message)}</p>`;
    }
  };
  await load();
}
function legacyNftPreview(nft: any, asset: any) {
  const overlay = document.createElement("div");
  overlay.className = "kaspire-modal";
  overlay.innerHTML = `<section class="nft-preview">${nft.imageUrl ? `<img src="${esc(nft.imageUrl)}" alt="">` : ""}<h2>${esc(nft.ticker)} #${esc(nft.tokenId)}</h2><p>${nft.rarityRank == null ? "Rarity rank unavailable" : `Rarity rank #${nft.rarityRank}`}</p><div><button id="close-nft" class="outline">CLOSE</button><button id="send-nft">SEND NFT</button></div></section>`;
  document.body.append(overlay);
  overlay.querySelector<HTMLButtonElement>("#close-nft")!.onclick = () =>
    overlay.remove();
  overlay.querySelector<HTMLButtonElement>("#send-nft")!.onclick = () => {
    overlay.remove();
    send({
      ...asset,
      raw: { ...asset.raw, tokenId: nft.tokenId },
      tokenId: nft.tokenId,
    });
  };
}
function send(asset: any) {
  const owned =
    asset.kind === "krc20"
      ? (snapshot?.assets?.tokens ?? [])
      : asset.kind === "krc721"
        ? [asset.raw]
        : asset.kind === "kns"
          ? (snapshot?.assets?.domains ?? [])
          : asset.kind === "kcc20"
            ? (snapshot?.assets?.kcc20 ?? [])
            : [];
  shell(
    `<section class="send-screen"><p class="eyebrow">SEND</p><h1>${asset.kind === "kas" ? "Send KAS" : `Send <span data-preserve-case>${esc(ticker(asset.symbol ?? asset.kind))}</span>`}</h1><div class="form">${asset.kind !== "kas" ? `<label>Asset<select id="asset-select" data-preserve-case>${owned.map((item: any, index: number) => `<option value="${index}" ${item === asset.raw || item.symbol === asset.raw?.symbol ? "selected" : ""}>${esc(asset.kind === "kns" ? item.name : ticker(item.symbol))}${asset.tokenId ? ` #${esc(asset.tokenId)}` : ""}</option>`).join("")}</select></label>` : ""}<label>Address / KNS name<div class="recipient-input"><input id="recipient" autocomplete="off"><button id="choose-recipient" type="button" title="Address book">♙</button></div></label>${asset.kind === "krc721" ? `<label>Token ID<input id="token-id" value="${esc(asset.tokenId ?? asset.raw?.tokenId ?? "")}" readonly></label>` : ""}${["kas", "krc20", "kcc20"].includes(asset.kind) ? `<label>Amount<div class="amount"><input id="amount" inputmode="decimal" placeholder="0.00"><button id="max" type="button">MAX</button></div></label><small class="available">Available: ${esc(asset.balance ?? (snapshot ? `${fmt(snapshot.balanceKas)} KAS` : "—"))}</small>` : ""}<section class="tx-meta"><span>Network</span><b>${status.network === "mainnet" ? "Kaspa Mainnet" : "Kaspa TN10"}</b><span>Fee</span><b>Live node estimate</b><span>Signer</span><b>Rusty Kaspa v2.0.1</b></section><button id="review">REVIEW TRANSFER</button><p id="error" class="error"></p></div></section>`,
    "Send",
    true,
  );
  const amount = document.querySelector<HTMLInputElement>("#amount");
  if (amount)
    amount.oninput = () => {
      amount.value =
        amount.value
          .replace(",", ".")
          .replace(/[^\d.]/g, "")
          .match(/^\d*(?:\.\d{0,8})?/)?.[0] ?? "";
    };
  document
    .querySelector<HTMLButtonElement>("#max")
    ?.addEventListener("click", () => {
      if (amount)
        amount.value = (
          asset.kind === "kas"
            ? String(snapshot?.balanceKas ?? 0)
            : String(asset.balance ?? 0)
        ).replaceAll(",", "");
    });
  document.querySelector<HTMLButtonElement>("#choose-recipient")!.onclick =
    () => recipientPicker();
  document.querySelector<HTMLButtonElement>("#review")!.onclick = async () => {
    const reviewButton = document.querySelector<HTMLButtonElement>("#review")!;
    reviewButton.disabled = true;
    reviewButton.textContent = "Preparing secure review…";
    try {
      const recipient = value("recipient");
      if (asset.kind === "kas") {
        const input = value("amount");
        if (!/^\d+(\.\d{1,8})?$/.test(input))
          throw new Error("Enter a valid amount.");
        const [whole, fraction = ""] = input.split(".");
        const result = await command("sendKas", {
          recipient,
          amountSompi: Number(`${whole}${fraction.padEnd(8, "0")}`),
        });
        transactionReceipt(result, {
          kind: "kas",
          recipient,
          amount: input,
          symbol: "KAS",
        });
        return;
      }
      const selected = owned[Number(value("asset-select"))] ?? asset.raw;
      const displayAmount = value("amount");
      let amountValue = displayAmount;
      if (["krc20", "kcc20"].includes(asset.kind))
        amountValue = rawAmount(displayAmount, Number(selected.decimals ?? 8));
      const prepared = await persistentCommand("prepareAsset", {
        kind: asset.kind,
        to: recipient,
        ticker: selected.symbol ?? asset.symbol,
        amount: amountValue,
        displayAmount,
        tokenId: value("token-id"),
        assetId: selected.asset_id,
        covenantId: selected.covenantId,
      });
      assetTransferReview(prepared);
    } catch (error) {
      const label = document.querySelector("#error");
      if (label) label.textContent = (error as Error).message;
      reviewButton.disabled = false;
      reviewButton.textContent = "Review transfer";
    }
  };
}

function assetTransferReview(prepared: any) {
  const operation = prepared.operation,
    review = prepared.review;
  const row = (label: string, value: any) =>
    `<div class="detail-row"><span>${esc(label)}</span><b ${label === "Ticker" ? "data-preserve-case" : ""}>${esc(value)}</b></div>`;
  if (prepared.type === "kron") review.feeSompi = review.networkFeeSompi;
  const kcc =
    prepared.type === "kcc20" || prepared.type === "kron"
      ? `${row("Validation", prepared.type === "kron" ? "KRON template verified" : "Indexer verified")}${row("Covenant ID", review.covenantId ?? operation.covenantId)}${review.templateHash ? row("Template hash", review.templateHash) : ""}${row("Covenant inputs", fmt(review.covenantInputCount, 0))}${row("Covenant outputs", fmt(review.covenantOutputCount, 0))}${row("KAS in token inputs", sompiLabel(review.lockedKasSompi))}${Number(review.lockedKasTopUpSompi) ? row("KAS reserve top-up", sompiLabel(review.lockedKasTopUpSompi)) : ""}${Number(review.lockedKasReleasedSompi) ? row("KAS returned to wallet", sompiLabel(review.lockedKasReleasedSompi)) : ""}${row("KAS in new token cells", sompiLabel(review.lockedKasOutputSompi))}${row("Effective mass", fmt(review.mass, 0))}${row("Compute mass", fmt(review.computeMass, 0))}${review.storageMass != null ? row("Storage mass (normalized)", fmt(review.storageMass, 0)) : ""}${review.storageMassTarget != null ? row("Safe storage target", fmt(review.storageMassTarget, 0)) : ""}${row("Transient mass (normalized)", fmt(review.transientMass, 0))}${row("Fee mass", fmt(review.feeMass, 0))}${row("Compute budget", fmt(review.computeBudget, 0))}`
      : "";
  const raw = review.rawJson ?? prepared.request ?? {};
  shell(
    `<section class="transaction-detail"><p class="eyebrow">Review asset transfer</p><h1>Verify every detail</h1><section class="detail-section">${row("Protocol", String(operation.kind).toUpperCase())}${row("Recipient", operation.recipient)}${operation.ticker ? row("Ticker", ticker(operation.ticker)) : ""}${operation.amount ? row("Raw amount", operation.amount) : ""}${operation.displayAmount ? row("Amount", `${operation.displayAmount} ${ticker(operation.ticker)}`) : ""}${operation.tokenId ? row("Token ID", operation.tokenId) : ""}${kcc}${prepared.type === "inscription" ? row("Temporary commit", `${sompiLabel(review.amountSompi)}`) : ""}${row("Network fee", sompiLabel(review.feeSompi))}</section>${prepared.type === "inscription" ? '<p class="muted">The 0.3 KAS commit returns to this wallet through the reveal transaction, minus network fees. A committed transfer can be resumed.</p>' : Number(review.lockedKasTopUpSompi) ? '<p class="reserve-note">The reserve top-up adds only the KAS needed to keep the new token cells spendable. It is not a network fee.</p>' : ""}${Number(review.lockedKasReleasedSompi) ? '<p class="return-note">Excess KAS from consumed token cells returns as normal wallet change.</p>' : ""}<details class="raw-json"><summary>Raw JSON output</summary><pre>${esc(JSON.stringify(raw, null, 2))}</pre></details><button id="confirm-asset">Authorize ${prepared.type === "inscription" ? "commit + reveal" : "on-chain transfer"}</button><button id="cancel-asset" class="outline">Cancel</button><p id="review-error" class="error"></p></section>`,
    "Review asset transfer",
    true,
  );
  document.querySelector<HTMLButtonElement>("#cancel-asset")!.onclick = () => {
    view = "home";
    void render();
  };
  document.querySelector<HTMLButtonElement>("#confirm-asset")!.onclick =
    async () => {
      const button =
        document.querySelector<HTMLButtonElement>("#confirm-asset")!;
      button.disabled = true;
      button.textContent = "Authorizing…";
      try {
        const result = await command("confirmPreparedAsset", {
          preparedId: prepared.preparedId,
        });
        transactionReceipt(result, {
          kind: operation.kind,
          recipient: operation.recipient,
          amount: operation.displayAmount,
          symbol:
            ticker(operation.ticker) || String(operation.kind).toUpperCase(),
        });
      } catch (error) {
        document.querySelector("#review-error")!.textContent = (
          error as Error
        ).message;
        button.disabled = false;
        button.textContent = "Authorize commit + reveal";
      }
    };
}
function recipientPicker() {
  const overlay = document.createElement("div");
  overlay.className = "kaspire-modal";
  const own = status.addresses.map((item: any) => ({
    ...item,
    detail: item.watchOnly ? "Watch wallet" : item.path,
  }));
  overlay.innerHTML = `<section class="recipient-sheet"><div class="sheet-title"><h2>Address book</h2><button id="close-picker" class="icon">×</button></div><label class="allowlist"><span><b>Only allow saved recipients</b><small>${status.settings.recipientAllowlist ? "Enabled" : "Disabled"}</small></span></label><h3>CONTACTS</h3>${status.contacts.map((item: any) => `<button class="recipient-row" data-address="${esc(item.address)}"><span>♙</span><span><b>${esc(item.name)}</b><small>${short(item.address)}</small></span></button>`).join("") || '<p class="muted">No saved contacts.</p>'}<h3>MY WALLETS</h3>${own.map((item: any) => `<button class="recipient-row" data-address="${esc(item.address)}"><span>▣</span><span><b>${esc(item.name)}</b><small>${esc(item.detail)} · ${short(item.address)}</small></span></button>`).join("")}</section>`;
  document.body.append(overlay);
  overlay.querySelector<HTMLButtonElement>("#close-picker")!.onclick = () =>
    overlay.remove();
  overlay.querySelectorAll<HTMLButtonElement>("[data-address]").forEach(
    (button) =>
      (button.onclick = () => {
        document.querySelector<HTMLInputElement>("#recipient")!.value =
          button.dataset.address ?? "";
        overlay.remove();
      }),
  );
}
function sompiLabel(value: any) {
  if (value == null) return "—";
  const digits = BigInt(String(value)).toString().padStart(9, "0");
  const fraction = digits.slice(-8).replace(/0+$/g, "");
  return `${digits.slice(0, -8)}${fraction ? `.${fraction}` : ""} KAS`;
}
function prettyJson(value: unknown) {
  return JSON.stringify(
    value,
    (_key, nested) =>
      typeof nested === "bigint" ? nested.toString() : nested,
    2,
  );
}
async function activity() {
  shell(
    '<section class="activity"><p class="eyebrow">Activity</p><h1>Transactions</h1><div id="history"><div class="loading">Loading activity…</div></div></section>',
    "Activity",
    true,
  );
  try {
    const rows = await command("history");
    if (!document.querySelector("#history")) return;
    document.querySelector("#history")!.innerHTML = rows.length
      ? rows
          .map((item: any, index: number) => {
            const direction = item.incoming ? "Received" : "Sent";
            const amount =
              item.assetKind === "KAS"
                ? sompiLabel(item.amountSompi)
                : `${item.displayAmount ? `${esc(item.displayAmount)} ` : ""}${esc(item.assetSymbol ?? item.assetKind)}${item.tokenId ? ` #${esc(item.tokenId)}` : ""}`;
            return `<button class="activity-row" data-tx="${index}"><span class="activity-direction ${item.incoming ? "incoming" : "outgoing"}">${item.incoming ? "↙" : "↗"}</span><span><b>${direction}</b><small>${esc(item.assetKind)}${item.assetSymbol && item.assetSymbol !== item.assetKind ? ` · ${esc(item.assetSymbol)}` : ""}</small><em>${item.blockTime ? new Date(item.blockTime).toLocaleString() : "Pending"} · ${short(item.transactionId)}</em>${item.counterparty ? `<em>${item.incoming ? "From" : "To"} ${short(item.counterparty)}</em>` : ""}</span><strong>${status.settings.hideBalances ? "••••••" : `${item.incoming ? "+" : "-"}${amount}`}</strong><i>›</i></button>`;
          })
          .join("")
      : '<div class="empty">No transactions yet.</div>';
    document
      .querySelectorAll<HTMLButtonElement>("[data-tx]")
      .forEach(
        (button) =>
          (button.onclick = () =>
            transactionDetail(rows[Number(button.dataset.tx)])),
      );
  } catch (error) {
    document.querySelector("#history")!.innerHTML =
      `<p class="error">${esc((error as Error).message)}</p>`;
  }
}
function transactionDetail(item: any) {
  context.returnView = "activity";
  const direction = item.incoming ? "Received" : "Sent",
    amount =
      item.assetKind === "KAS"
        ? sompiLabel(item.amountSompi)
        : `${item.displayAmount ?? ""} ${item.assetSymbol ?? item.assetKind}${item.tokenId && item.assetKind !== "KCC20" ? ` #${item.tokenId}` : ""}`;
  const parties = (title: string, rows: any[]) =>
    `<section class="detail-section"><h3>${title}</h3>${rows?.length ? rows.map((row) => `<div class="party"><code>${esc(row.address)}</code>${row.amountSompi != null ? `<b>${sompiLabel(row.amountSompi)}</b>` : ""}${row.ownerId ? `<small>Owner / Covenant: <span>${esc(row.ownerId)}</span></small>` : ""}</div>`).join("") : "<p>Not available</p>"}</section>`;
  const kcc =
    item.assetKind === "KCC20" && item.covenantId
      ? `<section class="detail-section"><h3>KCC20 covenant</h3>${detailRow("Covenant ID", item.covenantId)}${item.templateHash ? detailRow("Template hash", item.templateHash) : ""}${item.inputCount != null ? detailRow("Covenant inputs", fmt(item.inputCount, 0)) : ""}${item.outputCount != null ? detailRow("Covenant outputs", fmt(item.outputCount, 0)) : ""}${item.lockedKasSompi != null ? detailRow("KAS in token inputs", sompiLabel(item.lockedKasSompi)) : ""}${Number(item.lockedKasTopUpSompi) ? detailRow("KAS reserve top-up", sompiLabel(item.lockedKasTopUpSompi)) : ""}${Number(item.lockedKasReleasedSompi) ? detailRow("KAS returned to wallet", sompiLabel(item.lockedKasReleasedSompi)) : ""}${item.lockedKasOutputSompi != null ? detailRow("KAS in new token cells", sompiLabel(item.lockedKasOutputSompi)) : ""}${item.computeMass != null ? detailRow("Compute mass", fmt(item.computeMass, 0)) : ""}${item.storageMass != null ? detailRow("Storage mass", fmt(item.storageMass, 0)) : ""}${item.transientMass != null ? detailRow("Transient mass", fmt(item.transientMass, 0)) : ""}${item.feeMass != null ? detailRow("Fee mass", fmt(item.feeMass, 0)) : ""}</section>${Number(item.lockedKasTopUpSompi) ? '<p class="reserve-note">The reserve top-up adds only the KAS needed to keep the new token cells spendable. It is not a network fee.</p>' : ""}`
      : "";
  const rawJson =
    item.rawJson ?? {
      transactionId: item.transactionId,
      assetKind: item.assetKind,
      inputs: item.inputs ?? item.from ?? [],
      outputs: item.outputs ?? item.to ?? [],
      payload: item.payload ?? "",
      feeSompi: item.feeSompi,
      mass: item.mass,
    };
  const rawOutput = `<details class="raw-json"><summary>Raw JSON output</summary><pre>${esc(prettyJson(rawJson))}</pre></details>`;
  shell(
    `<section class="transaction-detail"><header class="tx-detail-head"><span class="activity-direction ${item.incoming ? "incoming" : "outgoing"}">${item.incoming ? "↙" : "↗"}</span><span><h1>${direction}</h1><b>${status.settings.hideBalances ? "••••••" : `${item.incoming ? "+" : "-"}${esc(amount)}`}</b></span></header><section class="detail-section"><h3>Transfer</h3>${detailRow("Direction", direction)}${detailRow("Asset", `${item.assetKind}${item.assetSymbol && item.assetSymbol !== item.assetKind ? ` · ${item.assetSymbol}` : ""}`)}${detailRow("Amount", amount)}${detailRow("Status", item.isAccepted ? "Confirmed" : "Pending")}${detailRow("Date", item.blockTime ? new Date(item.blockTime).toLocaleString() : "Pending")}</section>${parties("From", item.from)}${parties("To", item.to)}${kcc}<section class="detail-section"><h3>Network</h3>${item.feeSompi != null ? detailRow("Fee", sompiLabel(item.feeSompi)) : ""}${item.totalInputSompi != null ? detailRow("Total inputs", sompiLabel(item.totalInputSompi)) : ""}${item.totalOutputSompi != null ? detailRow("Total outputs", sompiLabel(item.totalOutputSompi)) : ""}${item.inputCount != null ? detailRow("Inputs", item.inputCount) : ""}${item.outputCount != null ? detailRow("Outputs", item.outputCount) : ""}${item.mass != null ? detailRow("Effective mass", fmt(item.mass, 0)) : ""}${item.blockDaaScore ? detailRow("Block DAA score", item.blockDaaScore) : ""}${detailRow("Coinbase", item.isCoinbase ? "Yes" : "No")}</section><section class="copy-detail"><label>Transaction ID</label><code>${esc(item.transactionId)}</code><button id="copy-detail">Copy transaction ID</button></section>${item.tokenId ? `<section class="copy-detail"><label>Token / Asset ID</label><code>${esc(item.tokenId)}</code></section>` : ""}</section>`,
    "Transaction details",
    true,
  );
  document
    .querySelector(".transaction-detail")!
    .insertAdjacentHTML("beforeend", rawOutput);
  document.querySelector<HTMLButtonElement>("#copy-detail")!.onclick = () =>
    copy(item.transactionId, "Transaction ID copied");
}
function detailRow(label: string, value: any) {
  return `<div class="detail-row"><span>${esc(label)}</span><b>${esc(value)}</b></div>`;
}
async function command(name: string, values: Record<string, unknown> = {}) {
  const guarded = [
    "sendKas",
    "sendAsset",
    "confirmPreparedAsset",
    "compound",
    "resumeInscription",
    "exportSecret",
  ].includes(name);
  return guarded
    ? withInAppApprovals(persistentCommand(name, values))
    : rawCommand(name, values);
}
async function withInAppApprovals<T>(task: Promise<T>) {
  let settled = false,
    result: T | undefined,
    failure: unknown;
  void task
    .then((value) => {
      result = value;
      settled = true;
    })
    .catch((error) => {
      failure = error;
      settled = true;
    });
  while (!settled) {
    const pending = await rawCommand("pendingApproval");
    if (pending) {
      const approved = await approvalModal(pending);
      await rawCommand("resolveWalletApproval", { id: pending.id, approved });
    } else await new Promise((resolve) => setTimeout(resolve, 80));
  }
  if (failure) throw failure;
  return result as T;
}
function approvalModal(item: any) {
  return new Promise<boolean>((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "kaspire-modal approval-modal";
    overlay.innerHTML = `<section class="approval-sheet"><p class="eyebrow">SECURE APPROVAL</p><h1>${esc(item.title)}</h1><h2>${esc(item.origin)}</h2><p>${esc(item.description)}</p><div class="approval-details">${item.details.map((detail: string) => `<p>${esc(detail)}</p>`).join("")}</div>${item.rawJson != null ? `<details class="raw-json"><summary>Raw JSON output</summary><pre>${esc(prettyJson(item.rawJson))}</pre></details>` : ""}<div class="approval-actions"><button id="reject-approval" class="outline">REJECT</button><button id="accept-approval">APPROVE</button></div><small>Verify every detail. Kaspire never signs silently.</small></section>`;
    document.body.append(overlay);
    const finish = (approved: boolean) => {
      overlay.remove();
      resolve(approved);
    };
    overlay.querySelector<HTMLButtonElement>("#reject-approval")!.onclick =
      () => finish(false);
    overlay.querySelector<HTMLButtonElement>("#accept-approval")!.onclick =
      () => finish(true);
  });
}
function transactionReceipt(result: any, details: any) {
  const ids =
    typeof result === "string"
      ? [result]
      : [
          result?.commitTransactionId,
          result?.revealTransactionId,
          result?.transactionId,
        ].filter(Boolean);
  shell(
    `<section class="receipt-screen"><div class="receipt-check">✓</div><p class="eyebrow">TRANSACTION CONFIRMED</p><h1>Transaction sent</h1><div class="receipt-details"><span>Asset</span><b>${esc(details.symbol ?? details.kind?.toUpperCase())}</b>${details.amount ? `<span>Amount</span><b>${esc(details.amount)}</b>` : ""}<span>Recipient</span><code>${esc(details.recipient ?? status.selectedAddress)}</code>${ids.map((id: string, index: number) => `<span>${ids.length > 1 ? (index === 0 ? "Commit transaction" : "Reveal transaction") : "Transaction ID"}</span><code>${esc(id)}</code><button class="mini receipt-copy" data-id="${esc(id)}">COPY TX ID</button>`).join("")}</div><button id="close-receipt">CLOSE</button></section>`,
    "RECEIPT",
  );
  document
    .querySelectorAll<HTMLButtonElement>(".receipt-copy")
    .forEach(
      (button) =>
        (button.onclick = () =>
          copy(button.dataset.id ?? "", "Transaction ID copied")),
    );
  document.querySelector<HTMLButtonElement>("#close-receipt")!.onclick = () => {
    view = "home";
    void render();
  };
}
function addCompound(core: any) {
  if (
    core.utxoCount < 2 ||
    !document.querySelector(".balance-card") ||
    document.querySelector("#compound")
  )
    return;
  const button = document.createElement("button");
  button.id = "compound";
  button.className = "compound outline";
  button.textContent = `COMPOUND ${core.utxoCount} UTXOS`;
  button.onclick = async () => {
    try {
      const result = await command("compound");
      transactionReceipt(result, {
        kind: "compound",
        symbol: "KAS UTXO COMPOUND",
        recipient: status.selectedAddress,
      });
    } catch (error) {
      toast((error as Error).message, true);
    }
  };
  document.querySelector(".balance-card")!.append(button);
}
function nftPreview(nft: any, asset: any) {
  const overlay = document.createElement("div");
  overlay.className = "kaspire-modal";
  overlay.innerHTML = `<section class="nft-preview">${nft.imageUrl ? `<img src="${esc(nft.imageUrl)}" alt="">` : ""}<h2>${esc(nft.ticker)} #${esc(nft.tokenId)}</h2><p id="nft-rarity">Loading rarity rank…</p><div><button id="close-nft" class="outline">CLOSE</button><button id="send-nft">SEND NFT</button></div></section>`;
  document.body.append(overlay);
  overlay.querySelector<HTMLButtonElement>("#close-nft")!.onclick = () =>
    overlay.remove();
  overlay.querySelector<HTMLButtonElement>("#send-nft")!.onclick = () => {
    overlay.remove();
    send({
      ...asset,
      raw: { ...asset.raw, tokenId: nft.tokenId },
      tokenId: nft.tokenId,
    });
  };
  void command("nftRarity", { ticker: nft.ticker, tokenId: nft.tokenId })
    .then((value) => {
      const label = overlay.querySelector("#nft-rarity");
      if (label)
        label.textContent =
          value.rarityRank == null
            ? "Rarity rank unavailable"
            : `Rarity rank #${value.rarityRank}`;
    })
    .catch(() => {
      const label = overlay.querySelector("#nft-rarity");
      if (label) label.textContent = "Rarity rank unavailable";
    });
}
function onboarding() {
  shell(
    `<section class="first-run"><div class="first-brand"><img src="kaspire-icon.png" alt=""><b>KASPIRE</b></div><h1>YOUR KASPA.<br>YOUR CONTROL.</h1><p>The Kaspa wallet that makes no compromises. Fully open source and secure.</p><div class="first-actions"><button id="first-create">＋ CREATE 24-WORD WALLET</button><button id="first-seed" class="outline">◆ IMPORT 12 / 24 WORDS</button><button id="first-key" class="outline">▣ IMPORT PRIVATE KEY</button></div><div class="watch-divider"><span></span><b>OR WATCH ONLY</b><span></span></div><div class="form"><label>Watch a Kaspa address or KNS domain<input id="first-watch-address" placeholder="kaspa:q… or name.kas"></label><label>Wallet name<input id="first-watch-name" value="Watch wallet"></label><label>Vault password<input id="first-watch-password" type="password" minlength="12"></label><label>Confirm password<input id="first-watch-confirm" type="password" minlength="12"></label><button id="first-watch">WATCH WALLET</button><p id="first-error" class="error"></p></div></section>`,
  );
  document.querySelector<HTMLButtonElement>("#first-create")!.onclick = () =>
    legacyOnboarding("create");
  document.querySelector<HTMLButtonElement>("#first-seed")!.onclick = () =>
    legacyOnboarding("seed");
  document.querySelector<HTMLButtonElement>("#first-key")!.onclick = () =>
    legacyOnboarding("key");
  document.querySelector<HTMLButtonElement>("#first-watch")!.onclick =
    async () => {
      try {
        const password = value("first-watch-password");
        if (password !== value("first-watch-confirm"))
          throw new Error("Passwords do not match.");
        await command("createWatch", {
          address: value("first-watch-address"),
          name: value("first-watch-name"),
          password,
        });
        view = "home";
        await render();
      } catch (error) {
        document.querySelector("#first-error")!.textContent = (
          error as Error
        ).message;
      }
    };
}
function go(next: View) {
  if (!context.returnView) context.returnView = view;
  view = next;
  void render();
}
const casingObserver = new MutationObserver((records) => {
  for (const record of records)
    for (const added of Array.from(record.addedNodes)) {
      if (added instanceof HTMLElement) classicCase(added);
      else if (added.parentElement) classicCase(added.parentElement);
    }
});
casingObserver.observe(document.body, { childList: true, subtree: true });
void render();
export {};
