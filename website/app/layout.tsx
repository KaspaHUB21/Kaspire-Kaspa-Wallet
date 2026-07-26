import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Kaspire — Native Kaspa Wallet for Android",
  description:
    "A native self-custody Kaspa wallet for KAS, KRC-20, KRC-721, KNS, KCC20 and WalletConnect.",
  metadataBase: new URL("https://kaspire.kaslab.space"),
  openGraph: {
    title: "Kaspire — Your Kaspa universe. One secure wallet.",
    description:
      "Native Android self-custody, local Rust signing and one wallet for the growing Kaspa ecosystem.",
    type: "website",
    url: "https://kaspire.kaslab.space",
    images: ["/kaspire-logo.png"],
  },
  icons: {
    icon: [
      {
        url: "/kaspire-logo.png",
        type: "image/png",
      },
    ],
    apple: "/kaspire-logo.png",
  },
};

export const viewport: Viewport = {
  themeColor: "#050a0d",
  colorScheme: "dark",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
