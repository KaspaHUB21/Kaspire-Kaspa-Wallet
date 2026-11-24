import { useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { NamesNav } from "../components/NamesNav";
import { DotkMarketOverview } from "../components/DotkMarketOverview";
import { useDotk, type DotkList, type DotkName } from "../services/dotk";

const panel = "kaspa-panel rounded-md p-5";
const button = "focus-ring rounded-md border border-kaspa-primary px-4 py-2 font-bold text-kaspa-primary disabled:opacity-40";
export function DotkPage() {
  const { name } = useParams();
  const [search, setSearch] = useSearchParams();
  const query = search.get("query") || "";
  const page = Math.max(1, Number(search.get("page")) || 1);
  const [draft, setDraft] = useState(query);
  const state = useDotk<DotkList>(name ? null : "names?" + new URLSearchParams({ query, page: String(page) }));
  return <section className="space-y-5">
    <NamesNav />
    <div><h1 className="text-3xl font-bold">dot.k Covenant Names</h1><p className="mt-2 text-kaspa-muted">Native Kaspa Layer 1 names, secured by the dot.k registry covenant.</p><p className="mt-2 font-bold text-kaspa-primary">Marketplace data: Kaspire Marketplace</p></div>
    {name ? <DotkDetail name={name} /> : <>
      <form className="flex flex-wrap gap-3" onSubmit={event => { event.preventDefault(); setSearch({ query: draft.trim(), page: "1" }); }}>
        <input aria-label="Search dot.k names" maxLength={34} placeholder="Search .k name" value={draft} onChange={event => setDraft(event.target.value)} className="min-w-0 flex-1 rounded-md border border-kaspa-border bg-kaspa-card px-4 py-3" />
        <button className={button}>Search</button>
      </form>
      <DotkMarketOverview query={query} registeredTotal={state.data?.registeredTotal} />
      <h2 className="text-xl font-bold text-kaspa-text">Registered Names</h2>
      {state.loading ? <p role="status">Loading dot.k names…</p> : null}
      {state.error ? <p role="alert" className={panel}>{state.error}</p> : null}
      {state.data ? <>
        <p className="text-kaspa-muted">{state.data.total.toLocaleString("en-US")} active names · A–Z · Snapshot {new Date(state.data.indexedAt).toLocaleString()}</p>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{state.data.names.map(row => <Link className={panel + " break-all font-bold text-kaspa-primary hover:border-kaspa-primary"} key={row.name} to={"/dotk/" + encodeURIComponent(row.name)}>{row.name}<span className="mt-2 block text-xs font-normal text-kaspa-muted">View owner &amp; covenant</span></Link>)}</div>
        {!state.data.names.length ? <p className={panel}>No matching active names in this snapshot.</p> : null}
        <div className="flex items-center justify-center gap-4">
          <button className={button} disabled={page <= 1} onClick={() => setSearch({ query, page: String(page - 1) })}>Previous</button>
          <span>Page {page}</span>
          <button className={button} disabled={page * state.data.pageSize >= state.data.total} onClick={() => setSearch({ query, page: String(page + 1) })}>Next</button>
        </div>
      </> : null}
    </>}
    <p className={panel + " text-sm text-kaspa-muted"}>Source: dot.k directory. Ownership is indexed data, not an independent on-chain verification by this explorer. Your wallet must verify the current deed before sending a payment. Covenant-owned names may have no payment address. KNS sales and prices do not apply to dot.k.</p>
  </section>;
}
function DotkDetail({ name }: { name: string }) {
  const state = useDotk<DotkName>("names/" + encodeURIComponent(name));
  const data = state.data;
  return <div className="space-y-4">
    <Link to="/dotk" className={button}>← All dot.k names</Link>
    {state.loading ? <p role="status">Loading name…</p> : null}
    {state.error ? <p role="alert" className={panel}>{state.error}</p> : null}
    {data ? <div className={panel + " space-y-4"}>
      <h2 className="break-all text-2xl font-bold text-kaspa-primary">{data.name}</h2>
      <dl className="space-y-4">
        {[['Owner address', data.address || 'Covenant owner — no payment address'], ['Owner type', ({ 0: 'Schnorr public key', 3: 'P2SH', 4: 'Covenant', 133: 'ECDSA', 134: 'ECDSA' } as Record<number, string>)[data.ownerType]], ['Owner payload', data.owner], ['Deed address (not a payment recipient)', data.deedAddress], ['Registry covenant ID', data.registryCovenantId]].map(([label, value]) => <div key={label}><dt className="text-sm text-kaspa-muted">{label}</dt><dd className="mt-1 break-all font-mono text-sm">{value}</dd></div>)}
      </dl>
      {data.address ? <Link className={button + " inline-block"} to={"/wallet/krc20/" + encodeURIComponent(data.address)}>Check owner wallet</Link> : null}
    </div> : null}
  </div>;
}
export function DotkWalletNames({ address }: { address: string }) {
  const state = useDotk<{ names: string[] }>("addresses/" + encodeURIComponent(address),60000);
  return <div className={panel + " mb-5"}>
    <h2 className="text-lg font-bold">dot.k Covenant Names</h2>
    {state.loading ? <p role="status" className="mt-3 text-kaspa-muted">Loading .k names…</p> : null}
    {state.error ? <p role="alert" className="mt-3 text-kaspa-muted">{state.error}</p> : null}
    {state.data ? <div className="mt-3 flex flex-wrap gap-2">{state.data.names.length ? state.data.names.map(name => <Link key={name} className={button + " break-all"} to={"/dotk/" + encodeURIComponent(name)}>{name}</Link>) : !state.error?<p className="text-kaspa-muted">No dot.k names found.</p>:null}</div> : null}
  </div>;
}

