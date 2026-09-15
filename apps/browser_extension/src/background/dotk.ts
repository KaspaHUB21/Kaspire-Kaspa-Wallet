/** dot.k v4: directory hints + locally derived deed + fresh own-node proof.
 * Matches the Android implementation. No records or deed transfers are implied.
 */
export const DOTK_REGISTRY = "ee2128c03dfac7f6d74734bb3c879bd999434c47a55945b8a6daae2a1e4a21de";
const DIRECTORY = "https://api.dotk.name/v1";
const NODE = "https://kaspire.kaslab.space/api/local-node";
type Deriver = (request: {name: string; ownerType: number; owner: string}) => Promise<any>;
let derive: Deriver | undefined;
export function configureDotkDeriver(value: Deriver) { derive = value; }
export function dotkBareName(input: string): string {
  const normalized = input.trim().toLowerCase();
  if (!normalized.endsWith(".k")) throw new Error("Enter a complete dot.k name, for example name.k.");
  const bare = normalized.slice(0, -2);
  if (!/^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/.test(bare)) throw new Error("Invalid dot.k name.");
  return bare;
}
async function get(url: string, signal: AbortSignal): Promise<any> {
  const response = await fetch(url, {signal, headers: {accept: "application/json"}, cache: "no-store"});
  if (!response.ok) throw new Error("dot.k data is unavailable or the name has no active registration.");
  const text = await response.text();
  if (text.length > 2 * 1024 * 1024) throw new Error("Oversized dot.k response.");
  return JSON.parse(text);
}
function identity(row: any) {
  if (row?.registryCovenantId !== DOTK_REGISTRY) throw new Error("dot.k registry identity mismatch.");
}
export async function dotkNamesOf(address: string) {
  const row = await get(`${DIRECTORY}/addresses/${encodeURIComponent(address)}`, AbortSignal.timeout(6000));
  identity(row);
  if (row.address !== address || !Array.isArray(row.names)) throw new Error("dot.k returned a different owner.");
  const names = row.names.map((n: unknown) => {
    if (typeof n !== "string" || dotkBareName(`${n}.k`) !== n) throw new Error("Invalid dot.k name list.");
    return n;
  });
  return [...new Set<string>(names)].sort().map(name => ({name: `${name}.k`, address, verified: false}));
}
export async function resolveDotkName(input: string, nativeDerive: Deriver | undefined = derive) {
  const name = dotkBareName(input);
  if (!nativeDerive) throw new Error("dot.k native verifier is not initialized.");
  const signal = AbortSignal.timeout(12000);
  const row = await get(`${DIRECTORY}/names/${name}`, signal);
  identity(row);
  if (row.name !== name) throw new Error("dot.k returned a different name.");
  const result = await nativeDerive({name, ownerType: row.ownerType, owner: row.owner});
  identity(result);
  if (typeof result.address !== "string" || !result.address.startsWith("kaspa:")) throw new Error("This dot.k name is covenant-owned and has no payment address.");
  if (row.address !== result.address || row.deedAddress !== result.deedAddress) throw new Error("dot.k owner or deed conflicts with native derivation.");
  const path = `${NODE}/addresses/${encodeURIComponent(result.deedAddress)}/utxos`;
  const live = await get(path, signal);
  if (!Array.isArray(live)) throw new Error("Invalid node proof for dot.k.");
  for (const u of live.slice(0, 64)) {
    const e = u?.utxoEntry, p = u?.outpoint;
    if (String(e?.amount) !== String(result.bond) || e?.isCoinbase !== false ||
        e?.scriptPublicKey?.scriptPublicKey !== result.scriptPublicKey ||
        !/^[0-9a-f]{64}$/.test(p?.transactionId ?? "") || !Number.isSafeInteger(p?.index) || p.index < 0 ||
        (u.address != null && u.address !== result.deedAddress)) continue;
    const tx = await get(`${NODE}/transactions/${p.transactionId}`, signal);
    if (tx?.transaction_id !== p.transactionId || tx?.is_accepted !== true || !Array.isArray(tx.outputs)) continue;
    if (!tx.outputs.some((o: any) => o.index === p.index && o.covenant_id === DOTK_REGISTRY &&
      String(o.amount) === String(result.bond) && o.script_public_key === result.scriptPublicKey &&
      o.script_public_key_address === result.deedAddress)) continue;
    const fresh = await get(path, signal);
    if (!Array.isArray(fresh) || !fresh.some((u: any) => u?.outpoint?.transactionId === p.transactionId &&
      u.outpoint.index === p.index && String(u?.utxoEntry?.amount) === String(result.bond))) continue;
    return {name: `${name}.k`, address: result.address, deedAddress: result.deedAddress,
      registryCovenantId: DOTK_REGISTRY, outpoint: `${p.transactionId}:${p.index}`, verified: true};
  }
  throw new Error("dot.k ownership could not be confirmed by the node. No recipient was selected; please retry.");
}
