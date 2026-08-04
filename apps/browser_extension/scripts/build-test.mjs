import { build } from "esbuild";
import { mkdir, rename, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";

await rm("tests/generated", { recursive: true, force: true });
await mkdir("tests/generated/wasm", { recursive: true });
await build({entryPoints:["src/shared/protocol.ts"],outfile:"tests/generated/protocol.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
await build({entryPoints:["src/background/api.ts"],outfile:"tests/generated/api.mjs",bundle:true,format:"esm",platform:"node",target:"node20"});
execFileSync("cargo",["build","--locked","--release","-p","kaspa_secure_core","--target","wasm32-unknown-unknown"],{cwd:"../..",stdio:"inherit"});
execFileSync("/root/.cargo/bin/wasm-bindgen",["../../target/wasm32-unknown-unknown/release/kaspa_secure_core.wasm","--target","web","--out-dir","tests/generated/wasm","--no-typescript"],{stdio:"inherit"});
await rename("tests/generated/wasm/kaspa_secure_core.js","tests/generated/wasm/kaspa_secure_core.mjs");
