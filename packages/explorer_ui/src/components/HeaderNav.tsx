import { useEffect, useState } from "react";
import { DatabaseZap, Layers3, Menu, PieChart, RadioTower, Search, ShieldAlert, Star, Store } from "./icons";
import { NavLink, useLocation } from "react-router-dom";

function linkClass(active: boolean) {
  return [
    "focus-ring inline-flex h-10 shrink-0 items-center gap-2 rounded-md border px-3 text-sm font-semibold transition",
    active
      ? "border-kaspa-primary/60 bg-kaspa-primary/15 text-kaspa-primary shadow-kaspa"
      : "border-transparent bg-transparent text-kaspa-muted hover:border-kaspa-border hover:bg-kaspa-card/70 hover:text-kaspa-text"
  ].join(" ");
}

export function HeaderNav() {
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const favoriteTarget = explorerFavoriteTarget(location.pathname);
  const favoritesActive = location.pathname === "/favorites" || location.search.includes("favorites=1");
  const handleHomeClick = () => {
    if (location.pathname === "/") {
      window.location.reload();
    }
  };

  useEffect(() => {
    setOpen(false);
  }, [location.pathname]);

  return (
    <header className="mx-auto flex min-h-16 max-w-7xl flex-col items-stretch gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
      <div className="flex items-center justify-between gap-3">
        <NavLink to="/" onClick={handleHomeClick} className="focus-ring flex min-w-0 items-center gap-3 rounded-md">
          <img src="/assets/kashub-logo-v2.png" alt="" className="h-11 w-11 shrink-0 object-contain drop-shadow-[0_0_14px_rgba(99,224,202,0.3)]" />
          <div className="min-w-0">
            <div className="truncate text-sm font-bold text-kaspa-text">Kaspa Token Hub</div>
            <div className="max-w-[15rem] truncate text-xs text-kaspa-muted sm:max-w-[28rem]">Token Markets &amp; Portfolio Tracking</div>
          </div>
        </NavLink>
        <button
          type="button"
          onClick={() => setOpen((value) => !value)}
          className="focus-ring inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-md border border-kaspa-border bg-kaspa-card text-kaspa-text transition hover:border-kaspa-primary/60 hover:text-kaspa-primary sm:hidden"
          aria-label="Open navigation"
          aria-expanded={open}
        >
          <Menu className="h-5 w-5" aria-hidden="true" />
        </button>
      </div>

      <nav className="hidden w-auto flex-nowrap items-center gap-2 sm:flex" aria-label="Explorer navigation">
        <NavLink to="/krc20" className={({ isActive }) => linkClass(isActive)}>
          <RadioTower className="h-4 w-4" aria-hidden="true" />
          <span>KRC20</span>
        </NavLink>
        <NavLink to="/krc721" className={({ isActive }) => linkClass(isActive)}>
          <Store className="h-4 w-4" aria-hidden="true" />
          <span>KRC721</span>
        </NavLink>
        <NavLink to="/kcc20" className={({ isActive }) => linkClass(isActive)}>
          <ShieldAlert className="h-4 w-4" aria-hidden="true" />
          <span>KCC20</span>
        </NavLink>
        <NavLink to="/kns" className={() => linkClass(location.pathname === "/kns" || location.pathname.startsWith("/dotk"))}>
          <Search className="h-4 w-4" aria-hidden="true" />
          <span>Names</span>
        </NavLink>
        <NavLink to="/l2" className={() => linkClass(location.pathname === "/l2")}>
          <Layers3 className="h-4 w-4" aria-hidden="true" />
          <span>L2</span>
        </NavLink>
        <NavLink to="/combined" className={() => linkClass(location.pathname === "/combined")}>
          <DatabaseZap className="h-4 w-4" aria-hidden="true" />
          <span>COMBINED</span>
        </NavLink>
        <NavLink to={favoriteTarget} className={() => linkClass(favoritesActive)} title="Favorites" aria-label="Favorites">
          <Star className="h-4 w-4" aria-hidden="true" />
        </NavLink>
        <NavLink to="/portfolio" className={() => linkClass(location.pathname === "/portfolio")}>
          <PieChart className="h-4 w-4" aria-hidden="true" />
          <span>PORTFOLIO</span>
        </NavLink>
      </nav>

      {open ? (
        <nav className="grid gap-2 rounded-md border border-kaspa-border bg-kaspa-background/95 p-3 shadow-kaspa sm:hidden" aria-label="Mobile explorer navigation">
          <NavLink to="/krc20" className={({ isActive }) => linkClass(isActive)}>
            <RadioTower className="h-4 w-4" aria-hidden="true" />
            <span>KRC20</span>
          </NavLink>
          <NavLink to="/krc721" className={({ isActive }) => linkClass(isActive)}>
            <Store className="h-4 w-4" aria-hidden="true" />
            <span>KRC721</span>
          </NavLink>
          <NavLink to="/kcc20" className={({ isActive }) => linkClass(isActive)}>
            <ShieldAlert className="h-4 w-4" aria-hidden="true" />
            <span>KCC20</span>
          </NavLink>
          <NavLink to="/kns" className={() => linkClass(location.pathname === "/kns" || location.pathname.startsWith("/dotk"))}>
            <Search className="h-4 w-4" aria-hidden="true" />
            <span>Names</span>
          </NavLink>
          <NavLink to="/l2" className={() => linkClass(location.pathname === "/l2")}>
            <Layers3 className="h-4 w-4" aria-hidden="true" />
            <span>L2</span>
          </NavLink>
          <NavLink to="/combined" className={() => linkClass(location.pathname === "/combined")}>
            <DatabaseZap className="h-4 w-4" aria-hidden="true" />
            <span>COMBINED</span>
          </NavLink>
          <NavLink to={favoriteTarget} className={() => linkClass(favoritesActive)}>
            <Star className="h-4 w-4" aria-hidden="true" />
            <span>FAVORITES</span>
          </NavLink>
          <NavLink to="/portfolio" className={() => linkClass(location.pathname === "/portfolio")}>
            <PieChart className="h-4 w-4" aria-hidden="true" />
            <span>PORTFOLIO</span>
          </NavLink>
        </nav>
      ) : null}
    </header>
  );
}

function explorerFavoriteTarget(pathname: string) {
  void pathname;
  return {
    pathname: "/favorites",
    search: ""
  };
}

