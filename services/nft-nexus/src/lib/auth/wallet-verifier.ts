import * as kaspa from 'kaspa-wasm';

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
    return { valid: false, reason: "Kaspire did not provide a public key. Unlock the wallet and try again." };
  }

  // Resolve the verifier at service startup, not through a lazy CJS/ESM import
  // in the request path. A broken runtime must not masquerade as a bad user key.
  if (typeof kaspa.PublicKey !== 'function' || typeof kaspa.verifyMessage !== 'function') {
    return { valid: false, reason: "Kaspire login verification is temporarily unavailable. Please try again." };
  }

  const normalizedPublicKey = normalizeHex(input.publicKey);
  if (!/^(?:[0-9a-f]{64}|0[23][0-9a-f]{64}|04[0-9a-f]{128})$/i.test(normalizedPublicKey)) {
    return { valid: false, reason: "Invalid wallet public key. Unlock the selected wallet and try again." };
  }
  const publicKey = safeValue(() => new kaspa.PublicKey(normalizedPublicKey));
  if (!publicKey) {
    return { valid: false, reason: "Invalid wallet public key. Unlock the selected wallet and try again." };
  }

  // Kaspire signs the challenge with Schnorr. Do not try the legacy ECDSA
  // conversion: an x-only key does not contain its parity, and this WASM
  // version traps on toAddressECDSA rather than yielding a usable address.
  const derivedAddress = safeValue(() => {
    const address = publicKey.toAddress("mainnet");
    try { return address.toString().toLowerCase(); }
    finally { address.free(); }
  });
  publicKey.free();
  const walletAddress = input.walletAddress.toLowerCase();

  if (derivedAddress !== walletAddress) {
    return { valid: false, reason: "The public key does not match the selected Kaspire wallet. Reopen Nexus Offers and try again." };
  }

  const signatures = signatureCandidates(input.signature);
  const messages = messageCandidates(input.message);

  if (signatures.length === 0) {
    return { valid: false, reason: "The wallet returned an unsupported login signature format." };
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
    : { valid: false, reason: "The Kaspire login signature could not be verified. Please try again." };
}

function normalizeHex(value: string) {
  return value.trim().replace(/^0x/i, "");
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
