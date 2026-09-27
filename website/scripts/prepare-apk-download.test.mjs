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
    const payload = {
      version: "0.11.29",
      apkUrl: "https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.29.apk",
      sha256: createHash("sha256").update(body).digest("hex"),
    };
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

    await writeFile(join(dir, latestApk), body);
    const incompatiblePayload = Buffer.from(JSON.stringify({
      ...payload,
      apkUrl: "https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.29/Kaspire-Android-mainnet-v0.11.29.apk",
    }));
    await writeFile(join(dir, "manifest.json"), JSON.stringify({
      payload: incompatiblePayload.toString("base64"),
      signature: sign("RSA-SHA256", incompatiblePayload, privateKey).toString("base64"),
    }));
    await assert.rejects(
      prepareApkDownload(dir, join(dir, "manifest.json"), publicKeyDer),
      /incompatible with installed Kaspire clients/,
    );
  } finally { await rm(dir, { recursive: true, force: true }); }
});
