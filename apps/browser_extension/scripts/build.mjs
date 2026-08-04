import { build } from "esbuild";
import { cp, mkdir, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

await rm("dist", { recursive: true, force: true });
await rm("generated", { recursive: true, force: true });
await mkdir("dist/wasm", { recursive: true });
await mkdir("generated/wasm", { recursive: true });
execFileSync("cargo", ["build", "--locked", "--release", "-p", "kaspa_secure_core", "--target", "wasm32-unknown-unknown"], { cwd: "../..", stdio: "inherit" });
execFileSync("/root/.cargo/bin/wasm-bindgen", ["../../target/wasm32-unknown-unknown/release/kaspa_secure_core.wasm", "--target", "web", "--out-dir", "generated/wasm", "--no-typescript"], { stdio: "inherit" });
await cp("generated/wasm", "dist/wasm", { recursive: true });
await cp("node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa_bg.wasm", "dist/wasm/kron_kaspa_bg.wasm");
await cp("manifest.json", "dist/manifest.json");
await cp("static", "dist", { recursive: true });
await cp("../mobile_flutter/assets/branding/kaspire_app_icon_v4.png", "dist/kaspire-icon.png");
await cp("../mobile_flutter/assets/branding/hub21_wordmark.png", "dist/hub21-wordmark.png");
for (const [entry, outfile] of Object.entries({ "src/background/index.ts": "dist/background.js", "src/content/index.ts": "dist/content.js", "src/inpage/provider.ts": "dist/inpage.js", "src/ui/popup.ts": "dist/popup.js", "src/ui/wallet.ts": "dist/wallet.js", "src/ui/approval.ts":"dist/approval.js" })) {
  await build({ entryPoints: [entry], outfile, bundle: true, format: "esm", target: "chrome120", sourcemap: true, alias: { "kaspire-wasm": resolve("generated/wasm/kaspa_secure_core.js") } });
}
