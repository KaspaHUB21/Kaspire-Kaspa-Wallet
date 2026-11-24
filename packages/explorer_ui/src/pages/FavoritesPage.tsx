import { Link } from "react-router-dom";
import { EmptyState } from "../components/EmptyState";
import { LoadingState } from "../components/LoadingState";
import { TokenCard } from "../components/TokenCard";
import { usePortfolioStore } from "../services/portfolio";
import { useExplorerTokens } from "../services/tokens";
import {displayableKcc20} from "../utils/kcc20Visibility";
import type { Token } from "../types/token";

export function FavoritesPage() {
  const { favoriteIds } = usePortfolioStore();
  const krc20 = useExplorerTokens("KRC20");
  const kcc20 = useExplorerTokens("KCC20");
  const krc721 = useExplorerTokens("KRC721");
  const loading = krc20.loading || kcc20.loading || krc721.loading;
  const error = krc20.error || kcc20.error || krc721.error;
  const sections = [
    buildSection("KCC20", kcc20.data?.tokens || [], favoriteIds),
    buildSection("KRC20", krc20.data?.tokens || [], favoriteIds),
    buildSection("KRC721", krc721.data?.tokens || [], favoriteIds)
  ];
  const total = sections.reduce((sum, section) => sum + section.tokens.length, 0);

  return (
    <section data-favorites-page>
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <div className="text-sm font-bold text-kaspa-primary">Watchlist</div>
          <h1 className="mt-1 text-3xl font-bold text-kaspa-text">Favorites</h1>
        </div>
        <Link to="/" className="focus-ring inline-flex h-10 items-center justify-center rounded-md border border-kaspa-border px-4 text-sm font-bold text-kaspa-muted hover:border-kaspa-primary hover:text-kaspa-primary">
          Back to explorer
        </Link>
      </div>

      {loading ? <LoadingState /> : null}
      {error ? <div className="kaspa-panel rounded-md p-4" role="status">Some favorite sources are temporarily unavailable. Saved stars are preserved; available favorites remain visible.</div> : null}
      {!loading && !error && total === 0 ? (
        <EmptyState title={favoriteIds.size ? "No listed favorites" : "No favorites yet"} body={favoriteIds.size ? "Saved stars are preserved. Legacy test tokens and assets without indexed identity are not listed." : "Use the star on tokens you want to watch. Favorites are separate from your portfolio."} />
      ) : null}
        <div className="space-y-8">
          {sections.map((section) => section.tokens.length > 0 ? (
            <div key={section.title}>
              <div className="mb-3 flex items-center gap-3">
                <h2 className="text-xl font-bold text-kaspa-text">{section.title}</h2>
                <div className="h-px flex-1 bg-kaspa-border" />
                <span className="text-sm font-bold text-kaspa-muted">{section.tokens.length}</span>
              </div>
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                {section.tokens.map((token) => (
                  <TokenCard key={token.id} token={token} showMarketData />
                ))}
              </div>
            </div>
          ) : null)}
        </div>
    </section>
  );
}

function buildSection(title: string, tokens: Token[], favoriteIds: Set<string>) {
  return {
    title,
    tokens: tokens.filter((token) => favoriteIds.has(token.id)&&(token.layer!=="KCC20"||displayableKcc20(token)))
  };
}

