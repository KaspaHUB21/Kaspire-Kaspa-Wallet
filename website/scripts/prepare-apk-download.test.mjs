import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, writeFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { prepareApkDownload, latestApk } from "./prepare-apk-download.mjs";

test("website output contains only the latest APK; extension ZIP is preserved", async () => {
  const dir = await mkdtemp(join(tmpdir(), "kaspire-download-test-"));
  try {
    const body = Buffer.from("release fixture");
    const payload = { version: "0.11.29", sha256: createHash("sha256").update(body).digest("hex") };
    await writeFile(join(dir, latestApk), body);
    await writeFile(join(dir, "old.apk"), "old");
    await writeFile(join(dir, "old.APK"), "old");
    await writeFile(join(dir, "extension.zip"), "extension");
    const payloadBytes = Buffer.from(JSON.stringify(payload));
    const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
    const publicKeyDer = publicKey.export({ format: "der", type: "spki" }).toString("base64");
    await writeFile(join(dir, "manifest.json"), JSON.stringify({
      payload: payloadBytes.toString("base64"),
      signature: sign("RSA-SHA256", payloadBytes, privateKey).toString("base64"),
    }));
    const result = await prepareApkDownload(dir, join(dir, "manifest.json"), publicKeyDer);
    assert.equal(result.retired.length, 2);
    assert.deepEqual((await readdir(dir)).sort(), [latestApk, "extension.zip", "manifest.json"].sort());
    await writeFile(join(dir, latestApk), "wrong release");
    await assert.rejects(prepareApkDownload(dir, join(dir, "manifest.json"), publicKeyDer), /does not match/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
