interface StoredSession {
  vault: unknown;
  password: string | null;
}

let channelToken: string | null = null;
let generation = 0;
let key: CryptoKey | null = null;
let nonce: Uint8Array<ArrayBuffer> | null = null;
let ciphertext: ArrayBuffer | null = null;
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const context = encoder.encode("Kaspire volatile unlock session v1");

function clearSession() {
  channelToken = null;
  generation = 0;
  key = null;
  nonce?.fill(0);
  nonce = null;
  ciphertext = null;
}

async function store(message: any) {
  clearSession();
  channelToken = String(message.token ?? "");
  generation = Number(message.generation) || 0;
  if (!channelToken || generation <= 0)
    throw new Error("Invalid session channel.");
  key = await crypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  nonce = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(
    JSON.stringify({ vault: message.vault, password: message.password ?? null }),
  );
  try {
    ciphertext = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData: context },
      key,
      plaintext,
    );
  } finally {
    plaintext.fill(0);
  }
}

async function restore(
  token: string,
): Promise<(StoredSession & { generation: number }) | null> {
  if (
    !channelToken ||
    token !== channelToken ||
    !key ||
    !nonce ||
    !ciphertext ||
    generation <= 0
  )
    return null;
  const plaintext = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce, additionalData: context },
      key,
      ciphertext,
    ),
  );
  try {
    const value = JSON.parse(decoder.decode(plaintext)) as StoredSession;
    return { ...value, generation };
  } finally {
    plaintext.fill(0);
  }
}

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message?.kind !== "volatile-session") return false;
  void (async () => {
    if (message.command === "store") {
      await store(message);
      respond({ ok: true });
      return;
    }
    if (message.command === "get") {
      respond({ session: await restore(String(message.token ?? "")) });
      return;
    }
    if (message.command === "clear") {
      if (channelToken && String(message.token ?? "") !== channelToken)
        throw new Error("Invalid session channel.");
      clearSession();
      respond({ ok: true });
      return;
    }
    respond({ error: "Unknown volatile-session command." });
  })().catch((error) => respond({ error: String(error?.message ?? error) }));
  return true;
});

export {};
