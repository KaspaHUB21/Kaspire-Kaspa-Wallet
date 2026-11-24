import type { Token } from "../types/token";

export function hasVolumeWindow(token: Token, window: "7d" | "30d") {
  if (token.layer !== "L2" && token.layer !== "KCC20") {
    return true;
  }

  const explicit = window === "7d" ? token.volume_7d_available : token.volume_30d_available;
  if (explicit !== undefined) {
    return explicit;
  }

  return token.layer === "L2" && Boolean(token.source?.includes("KaspaCom Defi API"));
}

