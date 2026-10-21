import { mkdir, readFile, rm, readdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";

const expected = JSON.parse(await readFile('manifest.json','utf8'));
const protocol = await (await fetch('https://kaspire.kaslab.space/api/kasparocket/pro-api/protocol',
  {signal: AbortSignal.timeout(15000)})).json();
if (protocol?.network !== 'mainnet' || protocol?.token?.decimals !== 3 ||
    !['read','trade'].every(scope => protocol?.partner?.scopes?.includes(scope)))
  throw Error('KaspaRocket Mainnet read/trade gateway is not ready; refusing store package.');
execFileSync("node", ["scripts/build.mjs"], { stdio: "inherit" });
await mkdir("artifacts", { recursive: true });
const manifest = JSON.parse(await readFile("dist/manifest.json", "utf8"));
if (manifest.version !== expected.version || manifest.name !== expected.name ||
    /\btest\b/i.test(manifest.name + ' ' + manifest.version_name)) throw Error('Unexpected store package identity.');
for (const name of await readdir('dist')) {
  if (name.endsWith('.js') && /kr_(?:live|test)_[A-Za-z0-9_-]{16,}/.test(await readFile('dist/'+name,'utf8')))
    throw Error('Server-only provider credential detected; refusing store package.');
}
const output = `artifacts/kaspire-extension-${manifest.version}.zip`;
await rm(output, { force: true });
execFileSync("zip", ["-qr", `../${output}`, ".", "-x", "*.map"], { cwd: "dist", stdio: "inherit" });
console.log(output);
