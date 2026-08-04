import { copyFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";

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
