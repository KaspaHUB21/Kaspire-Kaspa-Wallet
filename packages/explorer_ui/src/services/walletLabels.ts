import { useCallback, useEffect, useMemo, useState } from "react";

const storageKey = "kaspa-token-explorer-wallet-labels-v1";
const eventName = "kaspa-wallet-labels-updated";

export interface WalletLabel {
  address: string;
  label: string;
  createdAt: string;
  updatedAt: string;
}

export interface ResolvedWalletLabel {
  label: string;
  source: "global" | "personal" | "ins";
}

interface WalletLabelState {
  version: 1;
  labels: Record<string, WalletLabel>;
}

const globalWalletLabels = new Map<string, string>([
  ["kaspa:qpy4ypnz6f85hr8gwn4t2h0ezpuh8n4tvunhn4dgedrpdfqmah5vgzlvcunln", "Kasmo Project Wallet"],
  ["kaspa:qrf5mw2ru0av3dgfmkhvh0hets8k84wxcaqqr3jv9wdf6st44h0cxql4syxt8", "KAT Bridge"],
  ["kaspa:qpwztwfam65p88zpw44m6ht6ghpvx8k3qszcwghkgvwe644kzp0g2p8jvych2", "CoinEx"],
  ["kaspa:qzg3untq9022jtyq4e36kensh9c6jhxwek66kayceyzd5ksxn8f7j69pxyjxp", "Biconomy"],
  ["kaspa:qpzpfwcsqsxhxwup26r55fd0ghqlhyugz8cp6y3wxuddc02vcxtjg75pspnwz", "MEXC"],
  ["kaspa:qrelgny7sr3vahq69yykxx36m65gvmhryxrlwngfzgu8xkdslum2yxjp3ap8m", "Gate.io"],
  ["kaspa:qrel0mhkpldly0u68lyat80f6skxny8c42289c0rshg4ymj72q7zvp3ap8m", "Gate.io"],
  ["kaspa:qrj59crrt87qul4p7e9ywa7mz42cffjmk29p7ry7fd8vuxmla6fw5t4yscq00", "MEXC"],
  ["kaspa:qzadw8dsuws5vxl87t3l8vsk8fdfsnkyccwepvms9v8v7r5xjg9vshzuu9m", "KuCoin"],
  ["kaspa:qzxr5f6g9skxrywtv7skxw7dy9cxfhyugz8cp6y3wxuddc02vcxtjg04vj3w", "Uphold"],
  ["kaspa:qqfxskpldly0u68lyat80f6skxny8c42289c0rshg4ymj72q7zvp0hdys", "Bitvavo"],
  ["kaspa:qzaf0mhkpldly0u68lyat80f6skxny8c42289c0rshg4ymj72q7zv2ls8zs", "Kraken"],
  ["kaspa:qz4askpldly0u68lyat80f6skxny8c42289c0rshg4ymj72q7zvt3xdgw", "Kraken"],
  ["kaspa:qrvu5f6g9skxrywtv7skxw7dy9cxfhyugz8cp6y3wxuddc02vcxtjgc3tges", "Bybit"],
  ["kaspa:qphfskpldly0u68lyat80f6skxny8c42289c0rshg4ymj72q7zvjg6gle", "Kraken"],
  ["kaspa:qqyw5f6g9skxrywtv7skxw7dy9cxfhyugz8cp6y3wxuddc02vcxtjgwqgd6j", "Bitget"],
  ["kaspa:qr8kskpldly0u68lyat80f6skxny8c42289c0rshg4ymj72q7zvtz5tsk", "KuCoin"],
  ["kaspa:qq4qnn5e6vtg2g9esvw4jfmqrf6p6l4cyfrds3qzx9le6zvreq8n6cuypplc0", "KASPY T1 MM"],
  ["kaspa:qpxvwl2ekc26xx8dem7zlyl9d55265h38z4dyc9utkc7x5kxs60asu2kmf6zp", "Old XT Wallet"],
  ["kaspa:qpecnmugatjg0nu7ydntqkf6dgnu4fr2l5tdrmu5rk5vxqvlz7lh5emtk0wsy", "Bitmart"],
  ["kaspa:qr5tz2qjk29qpfjepxxtlcpcsv9xn6hwlfkvhpyz45mxl7qh22hy5gupl5awf", "XT"],
  ["kaspa:qpq6lt496v9lvcmc744hfe5m6cl5e33qfuasmjq205gsf50xjm2nwy9er5h56", "XT"],
  ["kaspa:qz9cqmddjppjyth8rngevfs767m5nvm0480nlgs5ve8d6aegv4g9xzu2tgg0u", "Knot Meme"],
  ["kaspa:qrpyafezcpck945gax6342nr7tx76p5z6hsw6wnxw574a7k6jjsyx23qjgztf", "Ascendex"],
  ["kaspa:qzeegrxt993rkwkupx0u8yd8sz94atpeg4e7x8yrjav8x7wgulxszc8svhenj", "KREX NFT"],
  ["kaspa:qzmnk7c4ufc2rxrh9m9cq27fd4z2tewekrhphr77sau8ck0hqc6wklt47gmnh", "PPKAS Games"],
  ["kaspa:qqjxnmf5nmd220l45htt2hzpzudm32yejgr7fkr77lqyq499ysx9j30v2lmzw", "PPKAS Team"],
  ["kaspa:qzqgu4fq5y7r7pt9akfpthdq84huzsw7dhuqj4akvseg02pmdgy024dumf222", "PPKAS Listings"],
  ["kaspa:qqem9dye72lc82xh3h6aamgzdj9hcxdfaxd2v6nkjp2jzk39j3ym7khfmlk2n", "PPKAS Ecosystem"],
  ["kaspa:qp63efl3s4fyyhtpz9dpyww5mnszyj5zem0hpl8gs52q26s9xv5mqyqx466ze", "PPKAS Marketing"],
  ["kaspa:qzvj7hafg403frxmepg5xhldj8ca6k7dx36c3m2arnukj3aenpd2qlsjv443p", "PPKAS Airdrop"],
  ["kaspa:qraed0llukpgfvnnhsctmrsrm4m9vkeqyvg6ek82vtq7gmh99c8qcz9atrgz6", "HUB21"],
  ["kaspa:qqre4wt08dp0rvmxwqgwdkz4zu4m36g9uvmfledd27mx939uxe2yjpmmd37zq", "21 Million Coven"],
  ["kaspa:qpmyrtnx4qs0wp54rz3x8jjwuutaqzvmzjv30q7fstav7geg62d96v6v5rz8r", "Gothdag Game"],
  ["kaspa:qpy6s9jz30ck4xk94cjrvkeqr7yr6p2wdnzkgpf094yjzuakaufcxvrklaupq", "KasBTC Donation Funds"],
  ["kaspa:qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqkx9awp4e", "Burn Address"],
  ["kaspa:qzyuemm8wrh8twca6nnuwg0qejp3kydwagqz27qv8uxrlfs834gcwc32205fm", "FameEx"],
  ["kaspa:qyp90geyzyp56p4zqd87flxrwd64r557r2cwkuwxzuq9zxehmswcg8g54jmeu7p", "PionexUS"],
  ["kaspa:qpjunp39ssazf4rzfxxu0hd35xggfxn6lq0ls9u9q6peevzcmcv4xmv9q4njd", "MEXC"],
  ["kaspa:qqetp7ct8kqss99fxmymyz5t3fezppxp0t58wl6pawp27elqd46uudme00cl0", "MEXC"],
  ["kaspa:qz7gtc6gkgcj482s6jltww0j4n7664dhvgut5t4pn7333l7mmwah7veg0zxjq", "MEXC"],
  ["kaspa:qyp3ffdjvv6de6cg6jjgyhlg3mt3fngna2vzukdpzvwkaj5j3hctsyqecqf7dh3", "MARA"],
  ["kaspa:qz4j8mu269z8llgcczmfukm9fan2fq822kzxu4cfukd5fqrhxpsv2zhs9jxnp", "Kat Pool"],
  ["kaspa:qpamkvhgh0kzx50gwvvp5xs8ktmqutcy3dfs9dc3w7lm9rq0zs76vf959mmrp", "F2Pool"],
  ["kaspa:qpz2vgvlxhmyhmt22h538pjzmvvd52nuut80y5zulgpvyerlskvvwm7n4uk5a", "Entity X"],
  ["kaspa:qzxrs8gxjgk2q84wlt3xfd057ntws73fptalhy84g85zqfu5lcemvpu04vj3w", "Uphold"],
  ["kaspa:qr7vrlhgekw9efxgfq09ca3wqcxlslgxndcpk77pguu2usaa9aa27lhuunewj", "Uphold"],
  ["kaspa:qqfxn597v5c23td4asz99ky52sha8l2ypq8kmrsqxcu7skhdunncjgup0hdys", "Bitvavo"],
  ["kaspa:qzxs23g7txh3wq9d0t2z0hluhsflvzpf6d0yfum830ppumgtxa5d7zqca8r67", "Bitvavo"],
  ["kaspa:qz4kt3t0qzpmpcgle28mgudu6lpu0fel6rgn0y2p808l8em7gd2exnss8cr2t", "Bitvavo"],
  ["kaspa:qrvum29vk365g0zcd5gx3c7h829etfq2ytdmscjzw4zw04fjfnprcg9c3tges", "Bybit"],
  ["kaspa:qzkjdp8l79u4wayjjcvfvg4sdh9vhrhrdsspll6ue22qxy0mcyxkgplelkcpm", "Bybit"],
  ["kaspa:qzctc3gu02t8zmykux3t733a7crxhw7wxyfrghpq9nprfa7r0fxqxmreqsxqm", "Bybit"],
  ["kaspa:qqywx2wszmnrsu0mzgav85rdwvzangfpdj9j3ady9jpr7hu4u8c2wl9wqgd6j", "Bitget"],
  ["kaspa:qpq94ntnvy8p9q6wrdwtn37xtspgashrydc0kuu8ctpyxulmh0wlxh2807zdh", "KuCoin"],
  ["kaspa:qq3k4du6wf2g26j7ds6fqmgtgavgm3zy676wntp2e52nsuns2n4s6xkndmx0y", "KuCoin"],
  ["kaspa:qpxtcucks59lvjdypd6mc93f8dutrpjnhekpk9ftg4h6jte6slaxygttyflqm", "KuCoin"],
  ["kaspa:qr8k05f9n6xtrd0eex5lr6878mc5n7dgrtn8xv3frfvuxgfchx9077jtz5tsk", "KuCoin"],
  ["kaspa:qzadxjufntvckxrvy76pyhvtkuu8lg5ryz252aglmhlyv27pxqplksshzuu9m", "KuCoin"],
  ["kaspa:pzg9qecsexgfj3wksyw8yh597ve84d3ynh0wf78a4e6qsyhdr3l5z5qxqy7m3", "CoinEx"],
  ["kaspa:qrf3rcpvkgkeqhsa7n4gndnvppj5edp7zh2mqj35mfc4rdm4ymkm7cdjrdl7y", "CoinEx"],
  ["kaspa:qpg2hksud4vr78znrjr3rlvaywj2rycvmmcespdnllhqlf6tk68qxlzswns2x", "CoinEx"],
  ["kaspa:qpqpyavkqnp60q6t4sfctz4yp3n0ct963z65rxkd5ft32vkehnd3wx8jqctr2", "CoinEx"],
  ["kaspa:qzafftgv50f48jv9u70s5n52tg8pnahmrjy25vrcrrdmrd9uf2eqkn62ls8zs", "Kraken"],
  ["kaspa:qz4a8yqh9m83dyp0xzpcd2g6cz00sr8mxcp92kw9vms0djyckcmp2aqt3xdgw", "Kraken"],
  ["kaspa:qphfy7yfwyj7uqw2q6v924q6xcsstfhdz70cdm7ewnzqt98r2x6jydujg6gle", "Kraken"],
  ["kaspa:qr9fqcxp9xjprsm9sv7apy6qc0ja2p676m9gf9fkcww2qmaw4npxzllh7lrw0", "Kraken"],
  ["kaspa:qq2ka745yyj0760fkt3ax3t7hpyqret6pzaypag3afnd3fp8jpv4cmzpx8yrt", "Kraken"],
  ["kaspa:qpj2x2qfmvj4g6fn0xadv6hafdaqv4fwd3t4uvyw3walwfn50rzysa4lafpma", "Kraken"],
  ["kaspa:qrr0rrkgl2jyq2k6ndk7f8xgq6z9ect07mq8tsktkju8xy547yrvsdwc4558c", "Kraken"],
  ["kaspa:qr6pqdkru9fgwlm8yyqzp7cww9vj7auuq5vratzy4ev3luzj79t5ycvp8euuf", "Kraken"],
  ["kaspa:qpxx3aapk4hpkqd7u2rv4k7ss6h0pq6m56ut9qtppcy99rxtfc0r2qyg8egtm", "Kraken"],
  ["kaspa:qq7gp3zf9yt6destk9322k6ghsdffe0a3s3v7hxmm603nzwscpf9vtpvgk95g", "Kraken"],
  ["kaspa:qpyxfjtz86qlhn7jgh9mguyx3exve9p3gjuy9zm70cd8af88tpvag9frynn0z", "Kraken"],
  ["kaspa:qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3kx3kd69ymyw3tj4tsh467xzf2", "Kasplex Bridge"],
  ["kaspa:ppvnxxzm0rr37zpnwux2f2ntvfpr4uqdpm7zsvsztg3en92r7gs0wkmr72q9n", "Igra Entry"],
  ["kaspa:pqtm55d2a456qws90g096cxnecc7msjmxr8n2ernwues8zfdamkl2kfmxr8gr", "Rust Fund"],
  ["kaspa:ppk66xua7nmq8elv3eglfet0xxcfuks835xdgsm5jlymjhazyu6h5ac62l4ey", "DAGKnight Fund"],
  ["kaspa:qypa8zmqawush3z0tqsx4t9lyn2zatagazuut3dl7z55g9mxlays7egz280zqse", "PionexUS"],
  ["kaspa:qyp0jqpdmgwawcz68zpe5hd83t5tnp28297qd4knvtqn3ullafkv8tqy7kg5g2s", "Pionex"],
  ["kaspa:qypaxqlnznpywx4aq3g5nfkkt89aywfzwj83ea3gxqz45s0zycj8u4qz5u8fxeu", "Pionex"],
  ["kaspa:qrcz0ha5krc2y3snq6vm6quyqdh7fcs8gkx0f5z5v4ld0s32l4p850cvk8udv", "ViaBTC"],
  ["kaspa:qquu5ypnp3n0za4uu3dh89rftgnjzmlc3p4czx4la4nqd4lnw2n65fsq8y8le", "Binance Pool"],
  ["kaspa:qp9rv9jvx2kyf6wu4lupuruunq5zsuszyxs0dr3l89ej7wsgs48jqkewy6xtl", "Kaspa-pool"],
  ["kaspa:qp7e00hl9qhxf2urj0mxr6u8y5swhhz2fy4qp5vudal6c7y9pq72gfe6m4rgd", "Pluto DEV"],
  ["kaspa:qrk9decfnl4rayeegp6gd3tc6605zavclkpud5jp78axat5namppwt050d57j", "HumPool"],
  ["kaspa:qzvedczjpmg0eeg32ly2ztqa3kuz0yvq2qu72rqpl7ddujg8jnezq5rp5etye", "Kryptex"],
  ["kaspa:qrlksu3pxp6w7gxe8gw7lpajz8u64t5u958ucwveq49gxttaddetg8300l73p", "2Miners"],
  ["kaspa:qzd6sfx3a8gx3q0qjvsts0pc4gj62z8a4kdf6qcndq5fg42wwxpv6sv9ngmg9", "2Miners"],
  ["kaspa:qpy827u4r43hp36nu2w78dphwgzjr3e9xdwwvm7k7dalyhpfkr84qucn4ecud", "HeroMiners"],
  ["kaspa:qrvqn64vxkcevdev6k2y49slxw4ls57cjzdqmqkcgh9wu7xmghk57v4ehla0t", "K1Pool"],
  ["kaspa:qrrzeucwfetuty3qserqydw4z4ax9unxd23zwp7tndvg7cs3ls8dvwldeayv5", "WoolyPooly"],
  ["kaspa:qpf4gjshrv5xgd7s0l7uehvcczcgx3u5juw77pt4q95h0ax0k62hvsvme480f", "ChangeNOW"],
  ["kaspa:qrxaj8q9n97hz4uchcksw27hgv5fxudlsu74xnqvecvmkdcg4jrvxsnqmkxv0", "Burtle Donation"],
  ["0xaad9fe8076bb9e3d336d1417f18fda8d641d3d60", "Pluto Dev"]
]);

function emptyState(): WalletLabelState {
  return { version: 1, labels: {} };
}

export function normalizeWalletAddress(address: string | undefined | null) {
  return (address || "").trim().toLowerCase();
}

export function globalLabelFor(address: string | undefined | null): ResolvedWalletLabel | null {
  const label = globalWalletLabels.get(normalizeWalletAddress(address));
  return label ? { label, source: "global" } : null;
}

export interface WalletLabelMatch {
  address: string;
  label: string;
  source: "global" | "personal";
}

export function globalLabelMatches(query: string): WalletLabelMatch[] {
  const normalized = normalizeLabelQuery(query);
  if (!normalized) return [];
  return Array.from(globalWalletLabels.entries())
    .filter(([, label]) => normalizeLabelQuery(label) === normalized)
    .map(([address, label]) => ({ address, label, source: "global" as const }));
}

export function globalLabelSearchMatches(query: string): WalletLabelMatch[] {
  const normalized = normalizeLabelQuery(query);
  if (!normalized) return [];
  return Array.from(globalWalletLabels.entries())
    .filter(([, label]) => normalizeLabelQuery(label).includes(normalized))
    .sort(([, a], [, b]) => Number(normalizeLabelQuery(a) !== normalized) - Number(normalizeLabelQuery(b) !== normalized) || a.localeCompare(b))
    .map(([address, label]) => ({ address, label, source: "global" as const }));
}

function normalizeLabelQuery(value: string) {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function isLabel(value: unknown): value is WalletLabel {
  if (!value || typeof value !== "object") return false;
  const item = value as Partial<WalletLabel>;
  return typeof item.address === "string" && typeof item.label === "string";
}

function normalizeLabel(address: string, label: string, existing?: WalletLabel): WalletLabel | null {
  const normalizedAddress = normalizeWalletAddress(address);
  const normalizedLabel = label.trim();
  if (!normalizedAddress || !normalizedLabel) {
    return null;
  }
  const now = new Date().toISOString();
  return {
    address: normalizedAddress,
    label: normalizedLabel,
    createdAt: existing?.createdAt || now,
    updatedAt: now
  };
}

function looksLikeWalletAddress(value: string) {
  const trimmed = value.trim();
  return /^kaspa:[a-z0-9:]+$/i.test(trimmed) || /^0x[a-f0-9]{40}$/i.test(trimmed);
}

function readState(): WalletLabelState {
  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return emptyState();
    const parsed = JSON.parse(raw) as Partial<WalletLabelState> | WalletLabel[] | Record<string, unknown>;
    const labels: Record<string, WalletLabel> = {};

    if (Array.isArray(parsed)) {
      for (const item of parsed) {
        if (!isLabel(item)) continue;
        const normalized = normalizeLabel(item.address, item.label, item);
        if (normalized) labels[normalized.address] = normalized;
      }
      return { version: 1, labels };
    }

    if (parsed && typeof parsed === "object" && "labels" in parsed && parsed.labels && typeof parsed.labels === "object") {
      for (const item of Object.values(parsed.labels)) {
        if (!isLabel(item)) continue;
        const normalized = normalizeLabel(item.address, item.label, item);
        if (normalized) labels[normalized.address] = normalized;
      }
      return { version: 1, labels };
    }

    if (parsed && typeof parsed === "object") {
      for (const [key, value] of Object.entries(parsed)) {
        if (typeof value !== "string") continue;
        const normalized = looksLikeWalletAddress(value) && !looksLikeWalletAddress(key)
          ? normalizeLabel(value, key)
          : normalizeLabel(key, value);
        if (normalized) labels[normalized.address] = normalized;
      }
    }

    return { version: 1, labels };
  } catch {
    return emptyState();
  }
}

function writeState(next: WalletLabelState) {
  window.localStorage.setItem(storageKey, JSON.stringify(next));
  window.dispatchEvent(new CustomEvent(eventName));
}

function parseImportedLabels(source: unknown) {
  const labels: Array<{ address: string; label: string }> = [];

  if (Array.isArray(source)) {
    for (const item of source) {
      if (isLabel(item)) labels.push({ address: item.address, label: item.label });
    }
    return labels;
  }

  if (source && typeof source === "object" && "labels" in source) {
    const nested = (source as { labels?: unknown }).labels;
    if (Array.isArray(nested)) {
      return parseImportedLabels(nested);
    }
    if (nested && typeof nested === "object") {
      for (const item of Object.values(nested)) {
        if (isLabel(item)) labels.push({ address: item.address, label: item.label });
      }
    }
    return labels;
  }

  if (source && typeof source === "object") {
    for (const [key, value] of Object.entries(source)) {
      if (typeof value !== "string") continue;
      if (looksLikeWalletAddress(value) && !looksLikeWalletAddress(key)) {
        labels.push({ address: value, label: key });
      } else {
        labels.push({ address: key, label: value });
      }
    }
  }

  return labels;
}

export function useWalletLabels() {
  const [state, setState] = useState<WalletLabelState>(() => readState());

  useEffect(() => {
    function sync() {
      setState(readState());
    }
    window.addEventListener("storage", sync);
    window.addEventListener(eventName, sync);
    return () => {
      window.removeEventListener("storage", sync);
      window.removeEventListener(eventName, sync);
    };
  }, []);

  const save = useCallback((updater: (current: WalletLabelState) => WalletLabelState) => {
    const next = updater(readState());
    writeState(next);
    setState(next);
  }, []);

  const labels = useMemo(() => {
    return Object.values(state.labels).sort((a, b) => a.label.localeCompare(b.label) || a.address.localeCompare(b.address));
  }, [state.labels]);

  const personalLabelFor = useCallback((address: string | undefined | null) => {
    const normalized = normalizeWalletAddress(address);
    return normalized ? state.labels[normalized]?.label || null : null;
  }, [state.labels]);

  const labelDetailsFor = useCallback((address: string | undefined | null): ResolvedWalletLabel | null => {
    const globalLabel = globalLabelFor(address);
    if (globalLabel) return globalLabel;
    const personalLabel = personalLabelFor(address);
    return personalLabel ? { label: personalLabel, source: "personal" } : null;
  }, [personalLabelFor]);

  const labelFor = useCallback((address: string | undefined | null) => {
    return labelDetailsFor(address)?.label || null;
  }, [labelDetailsFor]);

  const labelMatches = useCallback((query: string): WalletLabelMatch[] => {
    const normalized = normalizeLabelQuery(query);
    if (!normalized) return [];
    const personal = labels
      .filter((item) => normalizeLabelQuery(item.label) === normalized)
      .map((item) => ({ address: item.address, label: item.label, source: "personal" as const }));
    const personalAddresses = new Set(personal.map((item) => item.address));
    const global = globalLabelMatches(query).filter((item) => !personalAddresses.has(item.address));
    return [...personal, ...global];
  }, [labels]);

  const labelSearchMatches = useCallback((query: string): WalletLabelMatch[] => {
    const normalized = normalizeLabelQuery(query);
    if (!normalized) return [];
    const personal = labels
      .filter((item) => normalizeLabelQuery(item.label).includes(normalized))
      .sort((a, b) => Number(normalizeLabelQuery(a.label) !== normalized) - Number(normalizeLabelQuery(b.label) !== normalized) || a.label.localeCompare(b.label))
      .map((item) => ({ address: item.address, label: item.label, source: "personal" as const }));
    const personalAddresses = new Set(personal.map((item) => item.address));
    const global = globalLabelSearchMatches(query).filter((item) => !personalAddresses.has(item.address));
    return [...personal, ...global].slice(0, 12);
  }, [labels]);

  const setLabel = useCallback((address: string, label: string) => {
    save((current) => {
      const normalizedAddress = normalizeWalletAddress(address);
      const normalized = normalizeLabel(normalizedAddress, label, current.labels[normalizedAddress]);
      if (!normalized) return current;
      return { version: 1, labels: { ...current.labels, [normalized.address]: normalized } };
    });
  }, [save]);

  const removeLabel = useCallback((address: string) => {
    save((current) => {
      const labels = { ...current.labels };
      delete labels[normalizeWalletAddress(address)];
      return { version: 1, labels };
    });
  }, [save]);

  const importLabels = useCallback((input: string) => {
    const parsed = JSON.parse(input) as unknown;
    const imported = parseImportedLabels(parsed);
    let count = 0;
    save((current) => {
      const labels = { ...current.labels };
      for (const item of imported) {
        const normalized = normalizeLabel(item.address, item.label, labels[normalizeWalletAddress(item.address)]);
        if (!normalized) continue;
        labels[normalized.address] = normalized;
        count += 1;
      }
      return { version: 1, labels };
    });
    return count;
  }, [save]);

  const exportLabels = useCallback(() => {
    const exported: Record<string, string> = {};
    for (const item of labels) {
      let key = item.label;
      let suffix = 2;
      while (Object.prototype.hasOwnProperty.call(exported, key)) {
        key = `${item.label} ${suffix}`;
        suffix += 1;
      }
      exported[key] = item.address;
    }
    return JSON.stringify(exported, null, 2);
  }, [labels]);

  return { labels, labelFor, labelDetailsFor, personalLabelFor, labelMatches, labelSearchMatches, setLabel, removeLabel, importLabels, exportLabels };
}

