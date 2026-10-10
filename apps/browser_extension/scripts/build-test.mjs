import { build } from "esbuild";
import { mkdir, rename, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const cargoTargetDir = process.env.CARGO_TARGET_DIR
  ? resolve(process.env.CARGO_TARGET_DIR)
  : resolve("../../target");

await rm("tests/generated", { recursive: true, force: true });
await mkdir("tests/generated/wasm", { recursive: true });
await build({entryPoints:["src/background/kronHoldings.ts"],outfile:"tests/generated/kronHoldings.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/background/nexus.ts"],outfile:"tests/generated/nexus.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/background/dotk.ts"],outfile:"tests/generated/dotk.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/shared/assetPresentation.ts"],outfile:"tests/generated/assetPresentation.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/shared/protocol.ts"],outfile:"tests/generated/protocol.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/shared/tokenAmount.ts"],outfile:"tests/generated/tokenAmount.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/background/api.ts"],outfile:"tests/generated/api.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/background/krc721Reads.ts"],outfile:"tests/generated/krc721Reads.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/background/kasparocket.ts"],outfile:"tests/generated/kasparocket.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
execFileSync("cargo",["build","--locked","--release","-p","kaspa_secure_core","--target","wasm32-unknown-unknown"],{cwd:"../..",stdio:"inherit"});
execFileSync("/root/.cargo/bin/wasm-bindgen",[resolve(cargoTargetDir,"wasm32-unknown-unknown/release/kaspa_secure_core.wasm"),"--target","web","--out-dir","tests/generated/wasm","--no-typescript"],{stdio:"inherit"});
await rename("tests/generated/wasm/kaspa_secure_core.js","tests/generated/wasm/kaspa_secure_core.mjs");
await build({entryPoints:["src/background/nftMarket.ts"],outfile:"tests/generated/nftMarket.mjs",bundle:true,format:"esm",platform:"node",target:"node20",alias:{"kaspire-wasm":resolve("tests/generated/wasm/kaspa_secure_core.mjs")}});
