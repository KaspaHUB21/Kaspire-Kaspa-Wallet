export function CovenantIdentity({value}:{value:string|undefined}) {
  if (!value || !/^[a-f0-9]{64}$/i.test(value)) return null;
  return <div data-search-covenant={value} title={'Covenant ID: '+value} aria-label={'Covenant ID: '+value} className="mt-1 break-all font-mono text-[11px] leading-relaxed text-kaspa-muted"><span className="sm:hidden">CID: <span className="inline-block whitespace-nowrap">{value.slice(0,6)}...{value.slice(-6)}</span></span><span className="hidden sm:inline">Covenant ID: {value}</span></div>;
}
