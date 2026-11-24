import { KaspireAdBanner } from "./KaspireAdBanner";

export function HomeBanners({ className = "" }: { className?: string }) {
  return (
    <div className={className}>
      <div className="mx-auto grid w-[90%] max-w-5xl grid-cols-1 gap-4 lg:grid-cols-2">
        <KaspireAdBanner />
        <aside aria-label="Kashub app">
          <a
            href="https://play.google.com/store/apps/details?id=kaspatokenexplorer.app"
            target="_blank"
            rel="noopener noreferrer"
            className="focus-ring block overflow-hidden rounded-md"
          >
            {/* Match Kaspire's visible frame (y=143..567), not the lightning.
                Kashub's original frame is y=133..601 on the same 724px canvas.
                Keep the supplied asset intact and normalize only its display. */}
            <img
              src="/assets/kashub-play-store-banner.png"
              alt="Kashub — Get the app on Google Play Store"
              width={2172}
              height={724}
              decoding="async"
              className="block h-auto w-full origin-top [transform:translateY(3.10833%)_scaleY(0.905983)]"
            />
          </a>
        </aside>
      </div>
    </div>
  );
}

