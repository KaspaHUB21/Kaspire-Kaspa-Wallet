import { Star } from "./icons";
import { usePortfolioStore } from "../services/portfolio";

interface FavoriteButtonProps {
  tokenId: string;
  compact?: boolean;
  bare?: boolean;
}

export function FavoriteButton({ tokenId, compact = false, bare = false }: FavoriteButtonProps) {
  const { isFavorite, toggleFavorite } = usePortfolioStore();
  const active = isFavorite(tokenId);
  const className = bare
    ? [
      "focus-ring inline-flex h-6 w-6 items-center justify-center rounded-sm transition",
      active ? "text-kaspa-primary" : "text-kaspa-muted hover:text-kaspa-primary"
    ].join(" ")
    : [
      "focus-ring inline-flex items-center justify-center rounded-md border transition",
      compact ? "h-7 w-7" : "h-7 w-7",
      active
        ? "border-kaspa-primary bg-kaspa-primary/15 text-kaspa-primary shadow-kaspa"
        : "border-kaspa-border bg-kaspa-background text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary"
    ].join(" ");

  return (
    <button
      type="button"
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
        toggleFavorite(tokenId);
      }}
      className={className}
      title={active ? "Remove from favorites" : "Add to favorites"}
      aria-label={active ? "Remove from favorites" : "Add to favorites"}
      aria-pressed={active}
    >
      <Star className={bare ? "h-3.5 w-3.5" : compact ? "h-3.5 w-3.5" : "h-3.5 w-3.5"} fill={active ? "currentColor" : "none"} aria-hidden="true" />
    </button>
  );
}

