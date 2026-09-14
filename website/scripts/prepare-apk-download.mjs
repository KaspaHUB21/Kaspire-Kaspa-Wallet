import { createHash } from "node:crypto";
import { readFile, readdir, unlink } from "node:fs/promises";
import { join } from "node:path";

export const latestApk = "Kaspire-Android-mainnet-latest.apk";

// Only call on generated build output, never the source or a live docroot.
export async function prepareApkDownload(downloads, manifestPath) {
  const envelope = JSON.parse(await readFile(manifestPath, "utf8"));
  const release = JSON.parse(Buffer.from(envelope.payload, "base64").toString("utf8"));
  if (!/^[a-f0-9]{64}$/.test(release.sha256 ?? "")) {
    throw new Error("Missing release APK checksum");
  }
  const digest = createHash("sha256").update(await readFile(join(downloads, latestApk))).digest("hex");
  if (digest !== release.sha256) {
    throw new Error("Latest APK does not match the signed update manifest; refusing website build");
  }
  const retired = [];
  for (const entry of await readdir(downloads, { withFileTypes: true })) {
    if (entry.isFile() && /\.apk$/i.test(entry.name) && entry.name !== latestApk) {
      await unlink(join(downloads, entry.name));
      retired.push(entry.name);
    }
  }
  return { version: release.version, sha256: digest, retired };
}
