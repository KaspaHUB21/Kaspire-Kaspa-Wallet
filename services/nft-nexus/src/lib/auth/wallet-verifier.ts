export async function verifyWalletSignature(input: {
  walletAddress: string;
  message: string;
  signature: string;
  publicKey?: string;
}) {
  const result = await verifyWalletSignatureDetailed(input);
  return result.valid;
}

export async function verifyWalletSignatureDetailed(input: {
  walletAddress: string;
  message: string;
  signature: string;
  publicKey?: string;
}) {
  if (!input.publicKey) {
    return { valid: false, reason: "Kasware did not provide a public key." };
  }

  const kaspa = await import("kaspa-wasm").catch(() => null);
  if (!kaspa) {
    return { valid: false, reason: "Kaspa signature verifier could not be loaded." };
  }

  const normalizedPublicKey = normalizeHex(input.publicKey);
  const publicKey = safeValue(() => new kaspa.PublicKey(normalizedPublicKey));
  if (!publicKey) {
    return { valid: false, reason: "Kasware returned an invalid public key." };
  }

  const derivedAddresses = [
    safeAddress(() => publicKey.toAddress("mainnet").toString()),
    safeAddress(() => publicKey.toAddressECDSA("mainnet").toString())
  ].filter((address): address is string => Boolean(address));
  const walletAddress = input.walletAddress.toLowerCase();

  if (!derivedAddresses.map((address) => address.toLowerCase()).includes(walletAddress)) {
    return { valid: false, reason: "Kasware public key does not match the selected wallet address." };
  }

  const signatures = signatureCandidates(input.signature);
  const messages = messageCandidates(input.message);

  if (signatures.length === 0) {
    return { valid: false, reason: "Kasware returned an unsupported signature format." };
  }

  const valid = signatures.some((signature) => messages.some((message) => {
    try {
      return kaspa.verifyMessage({
        message,
        signature,
        publicKey: normalizedPublicKey
      });
    } catch {
      return false;
    }
  }));

  return valid
    ? { valid: true }
    : { valid: false, reason: "Kasware signature could not be verified for this login challenge." };
}

function normalizeHex(value: string) {
  return value.trim().replace(/^0x/i, "");
}

function safeAddress(createAddress: () => string) {
  try {
    return createAddress();
  } catch {
    return null;
  }
}

function safeValue<T>(createValue: () => T) {
  try {
    return createValue();
  } catch {
    return null;
  }
}

function signatureCandidates(signature: string) {
  const trimmed = signature.trim();
  const candidates = new Set<string>();
  const withoutPrefix = normalizeHex(trimmed);

  if (/^[0-9a-fA-F]+$/.test(withoutPrefix)) {
    candidates.add(withoutPrefix);
    candidates.add(withoutPrefix.toLowerCase());
  }

  const base64Hex = base64ToHex(trimmed);
  if (base64Hex) {
    candidates.add(base64Hex);
  }

  const base64UrlHex = base64ToHex(trimmed.replace(/-/g, "+").replace(/_/g, "/"));
  if (base64UrlHex) {
    candidates.add(base64UrlHex);
  }

  return Array.from(candidates);
}

function messageCandidates(message: string) {
  return [
    message,
    Buffer.from(message, "utf8").toString("hex")
  ];
}

function base64ToHex(value: string) {
  if (!/^[A-Za-z0-9+/_=-]+$/.test(value)) {
    return null;
  }

  try {
    const padded = value.padEnd(Math.ceil(value.length / 4) * 4, "=");
    const buffer = Buffer.from(padded, "base64");
    return buffer.length > 0 ? buffer.toString("hex") : null;
  } catch {
    return null;
  }
}
