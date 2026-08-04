import { mkdir, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";

execFileSync("node", ["scripts/build.mjs"], { stdio: "inherit" });
await mkdir("artifacts", { recursive: true });
const output = "artifacts/kaspire-extension-0.3.14.zip";
await rm(output, { force: true });
execFileSync("zip", ["-qr", `../${output}`, ".", "-x", "*.map"], { cwd: "dist", stdio: "inherit" });
console.log(output);
