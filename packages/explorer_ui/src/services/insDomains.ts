import { useEffect, useMemo, useState } from "react";
import type { ResolvedWalletLabel } from "./walletLabels";

const cache = new Map<string, string | null>();

function normalize(address: string | undefined | null) {
  const trimmed = address?.trim().toLowerCase() || "";
  return /^0x[a-f0-9]{40}$/.test(trimmed) ? trimmed : "";
}

async function reverseIns(address: string) {
  if (cache.has(address)) {
    return cache.get(address) || null;
  }
  const url = new URL("/api/reverse", "https://insdomains.org");
  url.searchParams.set("address", address);
  const response = await fetch(url.toString(), { headers: { accept: "application/json" } });
  if (!response.ok) {
    cache.set(address, null);
    return null;
  }
  const data = await response.json() as { primary?: string | null };
  const primary = data.primary && data.primary.endsWith(".igra") ? data.primary : null;
  cache.set(address, primary);
  return primary;
}

export function useInsDomainLabels(addresses: Array<string | undefined | null>, enabled: boolean) {
  const addressKey = addresses.map(normalize).filter(Boolean).sort().join("|");
  const normalized = useMemo(() => addressKey ? addressKey.split("|") : [], [addressKey]);
  const [labels, setLabels] = useState<Record<string, string>>({});

  useEffect(() => {
    if (!enabled || normalized.length === 0) {
      return;
    }
    let active = true;
    Promise.all(normalized.map(async (address) => ({ address, name: await reverseIns(address).catch(() => null) })))
      .then((items) => {
        if (!active) return;
        setLabels((current) => {
          const next = { ...current };
          for (const item of items) {
            if (item.name) {
              next[item.address] = item.name;
            }
          }
          return next;
        });
      });
    return () => {
      active = false;
    };
  }, [enabled, normalized]);

  return (address: string | undefined | null): ResolvedWalletLabel | null => {
    const key = normalize(address);
    return key && labels[key] ? { label: labels[key], source: "ins" } : null;
  };
}

