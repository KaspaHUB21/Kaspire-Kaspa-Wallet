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

The website-distributed APK continues to use the existing Android certificate
so installed website builds can update in place. That Android certificate is
separate from the Git release-signing key.
