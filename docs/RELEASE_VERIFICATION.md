# Kaspire release verification

Starting with v0.10.9, Kaspire release tags are signed with the dedicated
Ed25519 key in `docs/release-signing-key.pub`.

Key fingerprint:

```text
SHA256:L9FG+NoKRUmKQ51zl32/P1KQ1LseLjDYJqfvPqhT46o
```

Verify a release tag without changing global Git or SSH configuration:

```sh
git config gpg.format ssh
git config user.signingkey docs/release-signing-key.pub
printf '%s %s\n' \
  'kaspire-release@kaslab.space' \
  "$(cat docs/release-signing-key.pub)" > /tmp/kaspire-allowed-signers
git config gpg.ssh.allowedSignersFile /tmp/kaspire-allowed-signers
git verify-tag v0.10.9
```

Each GitHub release publishes the installable APK, its SHA-256 checksum and
the exact source commit. The Android package metadata and signing-certificate
fingerprint are included in the release notes. A release tag proves source
provenance; the APK checksum binds the downloadable binary to those notes.

Starting with v0.10.12, website-distributed APKs are signed by the dedicated
4096-bit RSA certificate:

```text
Subject: CN=Kaspire Android Release, OU=HUB21, O=Kaspa HUB21
SHA-256: 0E:61:95:B9:3A:39:D6:8D:99:AE:6B:95:19:22:0B:46:F2:D2:B6:0A:E4:16:BF:A8:B8:ED:57:13:F1:ED:6C:3D
```

The private key, password and binary signing lineage are stored outside the
repository with owner-only filesystem permissions and require separate offline
backup. The APK embeds an Android signing-certificate lineage from the legacy
certificate (`89:B3:08:6B:C3:1A:73:34:53:C4:D4:91:5B:1C:8B:29:4C:F0:29:DC:86:73:19:5A:19:02:8A:B3:1E:83:85:BB`)
to the dedicated certificate so supported Android 11+ website installations can
upgrade through the controlled rotation. Android release signing remains
separate from the Git release-signing key.
