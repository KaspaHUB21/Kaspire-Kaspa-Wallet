import { createHash, verify } from "node:crypto";
import { readFile, readdir, unlink } from "node:fs/promises";
import { join } from "node:path";

export const latestApk = "Kaspire-Android-mainnet-latest.apk";
export const updateManifestPublicKey =
  "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAmp4KFfshDFHNu8Cf2fZFdgocNGVDjGuXHD0LXcikROMVXumX18+wtL8n6tDA4EN2mKyIGMJFydCFXd8w1LoC2zs/SD10QF4yFmd9AxQ5y44nzQbyimLmLVYK3uHKzxRum8CU/KPwC/aBA1GnQWHsJqDQv55bmXsyEM3eWQ+a/PcPHdNqXpuRkHk8IP+mFxrBCTQ4Y7G299llcCQ5/IL5lOtJqpPb2vdiYrO5IaAE/6kw6bV3ur29Yy2gUWCzGlFhABaWjEzUOqrmCATTfsOhs0tiQY8P2Dvxc1/uHbjwPmOmBDUqZcGGWShbv6hmO2oorCZ5zHCR3LTPxndj0vL6EYuR3u5XYH4camhYieehnvYFJA5RClxlo/BlPzqZqT0K7sREfwfyVUE4GkX7Qq3JN75qHKi1jEVOdGTWg1AQnYRPoUIDmaZZ38Nf4ulZLDzki4/SU3mvstbHvprB8hK3mmsM48il+ihu+4JhO9FE9WT8eyTziD6ZYPqG5c1qr72460/YhMecjJq5GGI3NYl5l7UzR+giEx0hDfYMTW+PQRIYO5q3OBQlDIanX579TjrfrP2+9Jg8ebemZwlCTpxW8iJJBLQqag6GTdO+gtENHJSnaSll6JLzZWK+D+3gcvkLa+52H//YS2RUeVDzkbTkZi/tKh+67DzfCg0I/VcIYx0CAwEAAQ==";

// Only call on generated build output, never the source or a live docroot.
export async function prepareApkDownload(
  downloads,
  manifestPath,
  publicKeyDerBase64 = updateManifestPublicKey,
) {
  const envelope = JSON.parse(await readFile(manifestPath, "utf8"));
  const payload = Buffer.from(envelope.payload ?? "", "base64");
  const signature = Buffer.from(envelope.signature ?? "", "base64");
  if (!payload.length || !signature.length || !verify(
    "RSA-SHA256",
    payload,
    { key: Buffer.from(publicKeyDerBase64, "base64"), format: "der", type: "spki" },
    signature,
  )) {
    throw new Error("Invalid signed Android update manifest");
  }
  const release = JSON.parse(payload.toString("utf8"));
  if (!/^\d+\.\d+\.\d+$/.test(release.version ?? "")) {
    throw new Error("Invalid release version in signed Android update manifest");
  }
  const expectedApkUrl =
    `https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v${release.version}.apk`;
  if (release.apkUrl !== expectedApkUrl) {
    throw new Error(
      "Android update URL is incompatible with installed Kaspire clients",
    );
  }
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
