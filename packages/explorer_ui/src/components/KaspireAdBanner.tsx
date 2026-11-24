export function KaspireAdBanner({ className = "" }: { className?: string }) {
  return (
    <aside aria-label="Advertisement" className={className}>
      <a
        href="https://kaspire.kaslab.space"
        target="_blank"
        rel="sponsored noopener noreferrer"
        className="focus-ring block overflow-hidden rounded-md"
      >
        <img
          src="/assets/kaspire-wallet-banner.png"
          alt="Kaspire Wallet — Get the peak Kaspa wallet"
          width={2172}
          height={724}
          decoding="async"
          className="block h-auto w-full"
        />
      </a>
    </aside>
  );
}

