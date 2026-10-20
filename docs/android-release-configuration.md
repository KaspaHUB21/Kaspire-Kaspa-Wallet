# Android public client configuration

All Android release builds require `KASPAROCKET_API_KEY` containing the
**publishable Android TN10 key** issued for Kaspire. This is a domain-bound
client identifier, not a server secret. It is intentionally included in the
compiled APK, but local build settings are kept outside this repository.
Do not substitute the separately registered browser-extension key. Never put
a secret `kr_live_` key into an APK or pass key values on a shell command line.

The release machine uses the owner-readable file
`/srv/kaspire/release-signing/android-public-clients.json` with exactly one JSON
property, `KASPAROCKET_API_KEY`. Distributors can set
`KASPIRE_ANDROID_CLIENT_CONFIGURATION` to their approved file's absolute path.

Build through:

```sh
bash scripts/build_android_release.sh --build-name=0.11.54 --build-number=192
```

The wrapper validates the configuration, supplies Flutter's
`--dart-define-from-file`, and inspects both ARM APK slices after compilation.
It verifies the actual compiled key, pinned WalletConnect project ID and Rust
core presence without printing key values. Gradle independently rejects a
release with a missing or non-publishable TN10 key, including direct Flutter
builds and Play bundles. F-Droid/distributor builds must supply their approved
publishable configuration through the same Flutter flag; release signing is
unchanged and remains independent of client configuration.

For one-time recovery on the release machine only, the helper can retrieve the
public Android identifier from a locally held, previously verified working APK:

```sh
python3 scripts/android_release_config.py bootstrap --apk /absolute/reference.apk
```

Bootstrap never prints the key, creates the settings with mode 0600, refuses
an output inside the checkout and never overwrites existing settings. The
reference used for this release was the original Android KaspaRocket build 115;
its public client identity was checked against the provider's read-only
`/protocol` endpoint, which reported `testnet-10`.

Mainnet requires separately confirmed endpoints, client authorization and
network/signing validation. This configuration fix does not enable Mainnet swaps.
