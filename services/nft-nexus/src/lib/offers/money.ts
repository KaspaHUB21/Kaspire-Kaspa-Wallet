const SOMPI_PER_KAS = 100_000_000n;

export function kasToSompi(input: string): bigint {
  const trimmed = input.trim();
  if (!/^\d+(\.\d{1,8})?$/.test(trimmed)) {
    throw new Error("Enter a KAS amount with up to 8 decimal places.");
  }

  const [whole, fraction = ""] = trimmed.split(".");
  return BigInt(whole) * SOMPI_PER_KAS + BigInt(fraction.padEnd(8, "0"));
}

export function sompiToKas(sompi: bigint | number | string | null | undefined) {
  if (sompi === null || sompi === undefined) {
    return null;
  }

  const value = BigInt(sompi);
  const whole = value / SOMPI_PER_KAS;
  const fraction = value % SOMPI_PER_KAS;
  const fractionText = fraction.toString().padStart(8, "0").replace(/0+$/, "");
  return fractionText ? `${whole}.${fractionText}` : whole.toString();
}
