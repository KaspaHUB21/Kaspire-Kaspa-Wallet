import type { Config } from "tailwindcss";

export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        kaspa: {
          primary: "rgb(var(--kaspa-primary) / <alpha-value>)",
          background: "rgb(var(--kaspa-background) / <alpha-value>)",
          card: "rgb(var(--kaspa-card) / <alpha-value>)",
          border: "rgb(var(--kaspa-border) / <alpha-value>)",
          text: "rgb(var(--kaspa-text) / <alpha-value>)",
          muted: "rgb(var(--kaspa-muted) / <alpha-value>)"
        }
      },
      boxShadow: {
        kaspa: "0 0 0 1px rgb(var(--kaspa-primary) / 0.14), 0 8px 28px rgba(0,0,0,0.24), 0 0 22px rgb(var(--kaspa-primary) / 0.10)"
      }
    }
  },
  plugins: []
} satisfies Config;

