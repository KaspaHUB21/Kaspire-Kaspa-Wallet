import { NavLink } from "react-router-dom";
export function NamesNav() {
  return <nav aria-label="Name service" className="mb-6 flex flex-wrap gap-3">
    {[["/kns", "KNS · .kas"], ["/dotk", "dot.k · Covenant names"]].map(([to, label]) => <NavLink key={to} to={to} className={({ isActive }) => `focus-ring rounded-md border px-4 py-3 font-bold ${isActive ? "border-kaspa-primary bg-kaspa-primary/10 text-kaspa-primary" : "border-kaspa-border text-kaspa-muted"}`}>{label}</NavLink>)}
  </nav>;
}

