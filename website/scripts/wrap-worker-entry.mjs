import { rename, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const server = new URL("../dist/server/", import.meta.url);
const entry = fileURLToPath(new URL("index.js", server));
const handler = fileURLToPath(new URL("handler.js", server));
await rename(entry, handler);
await writeFile(
  entry,
  `import handler from "./handler.js";\n\nexport default {\n  fetch(request, env, ctx) {\n    return handler(request, env, ctx);\n  },\n};\n`,
);
