/** Presentation only: preserve source data and never alter signing payloads. */
export function sortedAssets<T extends { symbol?: unknown; name?: unknown; id?: unknown; covenantId?: unknown }>(assets: readonly T[]): T[] {
  return [...assets].sort((a, b) =>
    String(a.symbol ?? a.name ?? '').localeCompare(String(b.symbol ?? b.name ?? ''), 'en', { sensitivity: 'base', numeric: true }) ||
    String(a.covenantId ?? a.id ?? '').localeCompare(String(b.covenantId ?? b.id ?? ''), 'en'));
}

export function assetTicker(value: unknown): string {
  return String(value ?? '').trim().toUpperCase();
}

export function sameAsset(left: any, right: any, kind: string): boolean {
  if (!left || !right) return false;
  if (left === right) return true;
  if (kind === 'kcc20') return Boolean(left.covenantId) && left.covenantId === right.covenantId;
  if (kind === 'kns') return Boolean(left.name) && left.name === right.name;
  return Boolean(left.symbol) && assetTicker(left.symbol) === assetTicker(right.symbol);
}
