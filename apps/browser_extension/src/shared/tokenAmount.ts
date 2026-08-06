export function formatRawTokenAmount(raw: string, decimals: number): string {
  if (!/^[0-9]+$/.test(raw) || !Number.isInteger(decimals) || decimals < 0 || decimals > 18) {
    throw new Error("Invalid raw token amount.");
  }
  if (decimals === 0) return BigInt(raw).toString();
  const digits = BigInt(raw).toString().padStart(decimals + 1, "0");
  const whole = digits.slice(0, -decimals);
  const fraction = digits.slice(-decimals).replace(/0+$/g, "");
  return fraction ? `${whole}.${fraction}` : whole;
}
