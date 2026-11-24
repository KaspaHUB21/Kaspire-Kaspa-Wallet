import { useState } from "react";
import { Circle, Crown, Moon, Sun } from "./icons";

export type SiteTheme = "green" | "blue" | "light" | "hub21";

const storageKey = "kashub-site-theme";
const themes: Array<{ id: SiteTheme; label: string; icon: typeof Circle; iconClass: string }> = [
  { id: "green", label: "Kaspa green dark mode", icon: Circle, iconClass: "text-[#63e0ca]" },
  { id: "blue", label: "Midnight blue dark mode", icon: Moon, iconClass: "text-[#60a5fa]" },
  { id: "light", label: "Light mode", icon: Sun, iconClass: "text-[#f59e0b]" },
  { id: "hub21", label: "HUB21 silver and gold mode", icon: Crown, iconClass: "" }
];

export function ThemeSwitcher() {
  const [theme, setTheme] = useState<SiteTheme>(() => currentTheme());

  const selectTheme = (nextTheme: SiteTheme) => {
    document.documentElement.dataset.theme = nextTheme;
    window.localStorage.setItem(storageKey, nextTheme);
    updateThemeColor(nextTheme);
    setTheme(nextTheme);
  };

  return (
    <div className="inline-flex shrink-0 items-center gap-1 rounded-md border border-kaspa-border bg-kaspa-card p-1" aria-label="Choose page theme">
      {themes.map((option) => {
        const Icon = option.icon;
        const selected = theme === option.id;
        return (
          <button
            key={option.id}
            type="button"
            onClick={() => selectTheme(option.id)}
            title={option.label}
            aria-label={option.label}
            aria-pressed={selected}
            className={[
              "focus-ring inline-flex h-8 w-8 items-center justify-center rounded-md border transition",
              selected
                ? "border-kaspa-primary bg-kaspa-primary/15 text-kaspa-primary shadow-kaspa"
                : "border-transparent text-kaspa-muted hover:border-kaspa-border hover:text-kaspa-text"
            ].join(" ")}
          >
            <Icon className={`h-4 w-4 ${option.iconClass}`} />
          </button>
        );
      })}
    </div>
  );
}

function currentTheme(): SiteTheme {
  const theme = document.documentElement.dataset.theme;
  return theme === "blue" || theme === "light" || theme === "hub21" ? theme : "green";
}

function updateThemeColor(theme: SiteTheme) {
  const colors: Record<SiteTheme, string> = {
    green: "#061210",
    blue: "#0b0f14",
    light: "#f5faf9",
    hub21: "#12110c"
  };
  document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')?.setAttribute("content", colors[theme]);
}

