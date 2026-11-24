import { build } from "esbuild";
import { cp, mkdir, rm, readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import {createHash} from 'node:crypto';

const cargoTargetDir = process.env.CARGO_TARGET_DIR
  ? resolve(process.env.CARGO_TARGET_DIR)
  : resolve("../../target");

await rm("dist", { recursive: true, force: true });
await rm("generated", { recursive: true, force: true });
await mkdir("dist/wasm", { recursive: true });
await mkdir("generated/wasm", { recursive: true });
execFileSync('cargo',['clean','--locked','-p','kaspa_secure_core','--release','--target','wasm32-unknown-unknown'],{cwd:'../..',stdio:'inherit'});
execFileSync("cargo", ["build", "--locked", "--release", "--lib", "-p", "kaspa_secure_core", "--target", "wasm32-unknown-unknown"], { cwd: "../..", stdio: "inherit" });
execFileSync("/root/.cargo/bin/wasm-bindgen", [resolve(cargoTargetDir, "wasm32-unknown-unknown/release/kaspa_secure_core.wasm"), "--target", "web", "--out-dir", "generated/wasm", "--no-typescript"], { stdio: "inherit" });
await cp("generated/wasm", "dist/wasm", { recursive: true });
execFileSync(process.execPath,['scripts/build-pool-core.mjs'],{stdio:'inherit'});
await cp('generated/trestly','dist/wasm',{recursive:true});
await mkdir('dist/licenses/trestly',{recursive:true});
for(const file of ['LICENSE','UPSTREAM.json'])await cp('../../packages/trestly-kaspa/'+file,'dist/licenses/trestly/'+file);
await cp('../../packages/trestly-kaspa/artifacts/PROVENANCE.json','dist/licenses/trestly/ARTIFACT-PROVENANCE.json');
const nativeSha=createHash('sha256').update(await readFile('generated/trestly/trestly_web_core_bg.wasm')).digest('hex');
execFileSync(process.execPath,['scripts/build-dex-engine.mjs'],{stdio:'inherit'});
await mkdir('dist/dex',{recursive:true});
for(const asset of ['engine.js','provenance.json'])await cp(`generated/dex/${asset}`,`dist/dex/${asset}`);
await cp("node_modules/@kronsdk/kron-sdk/vendor/kaspa/kaspa_bg.wasm", "dist/wasm/kron_kaspa_bg.wasm");
await cp("manifest.json", "dist/manifest.json");
if (process.env.KASPIRE_TEST_BUILD === "hub21") {
  const manifest = JSON.parse(await readFile("dist/manifest.json", "utf8"));
  manifest.version = "0.4.7.1";
  manifest.version_name = "0.4.7.1 HUB21";
  await writeFile("dist/manifest.json", JSON.stringify(manifest, null, 2) + "\n");
}
await cp("static", "dist", { recursive: true });
// One UI source and the identical trusted wallet flow in both surfaces.
const walletHtml = (await readFile('static/wallet.html', 'utf8')).replace('</head>', '<link rel="stylesheet" href="wallet-layout.css"></head>');
await writeFile('dist/wallet.html', walletHtml);
await writeFile('dist/sidepanel.html', walletHtml.replace('src="wallet.js"','src="sidepanel.js"'));
await cp("../mobile_flutter/assets/browser/kasseal.png", "dist/kasseal.png");
for(const asset of ['braid.svg','kforge.svg','kasforge.png'])await cp(`../mobile_flutter/assets/browser/${asset}`,`dist/${asset}`);
await cp('../mobile_flutter/assets/browser/trestly.svg','dist/trestly.svg');
await cp("../mobile_flutter/assets/vaults", "dist/vaults", { recursive: true });
await cp("../mobile_flutter/assets/themes/hub21", "dist/themes/hub21", { recursive: true });
await cp("../mobile_flutter/assets/themes/glacier", "dist/themes/glacier", { recursive: true });
await cp("../mobile_flutter/assets/themes/neptune", "dist/themes/neptune", { recursive: true });
await mkdir('dist/themes/cosmic',{recursive:true});
for(const asset of ['nebula.png','surface-nebula.png','planet-cutout.png'])await cp('../mobile_flutter/assets/themes/cosmic/'+asset,'dist/themes/cosmic/'+asset);
await cp('../mobile_flutter/assets/branding/kaspire_wordmark.png','dist/kaspire-wordmark.png');
await cp("../mobile_flutter/assets/branding/kaspire_app_icon_v4.png", "dist/kaspire-icon.png");
await cp("../mobile_flutter/assets/branding/hub21_wordmark.png", "dist/hub21-wordmark.png");
for (const [entry, outfile] of Object.entries({ "src/background/index.ts": "dist/background.js", "src/content/index.ts": "dist/content.js", "src/inpage/provider.ts": "dist/inpage.js", "src/ui/popup.ts": "dist/popup.js", "src/ui/wallet.ts": "dist/wallet.js", "src/ui/sidePanelEntry.ts":"dist/sidepanel.js", "src/ui/approval.ts":"dist/approval.js", "src/offscreen/session.ts":"dist/session.js" })) {
  await build({ entryPoints: [entry], outfile, bundle: true, format: "esm", target: "chrome120", sourcemap: true, alias: { "kaspire-wasm": resolve("generated/wasm/kaspa_secure_core.js"),'kaspire-trestly-wasm':resolve('generated/trestly/trestly_web_core.js') },define:{KASPIRE_TRESTLY_WASM_SHA256:JSON.stringify(nativeSha)} });
}
