import { copyFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { prepareApkDownload } from "./prepare-apk-download.mjs";

const client = new URL("../dist/client/", import.meta.url).pathname;
const routes = [
  "developers",
  "developers/extension",
  "privacy",
  "security/inside-kaspire",
];

for (const route of routes) {
  const target = join(client, route);
  await mkdir(target, { recursive: true });
  await copyFile(join(client, `${route}.html`), join(target, "index.html"));
  await copyFile(join(client, `${route}.rsc`), join(target, "index.rsc"));
}

const apk = await prepareApkDownload(join(client, "downloads"), join(client, "updates/android.json"));
console.log(`Public APK: ${apk.version}; excluded ${apk.retired.length} historical/duplicate APKs from build output.`);
