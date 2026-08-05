import { mkdir, readFile, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";

execFileSync("node", ["scripts/build.mjs"], { stdio: "inherit" });
await mkdir("artifacts", { recursive: true });
const manifest = JSON.parse(await readFile("manifest.json", "utf8"));
const output = `artifacts/kaspire-extension-${manifest.version}.zip`;
await rm(output, { force: true });
execFileSync("zip", ["-qr", `../${output}`, ".", "-x", "*.map"], { cwd: "dist", stdio: "inherit" });
console.log(output);
