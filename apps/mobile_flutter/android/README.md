# Android setup

1. Install Flutter 3.24+ and Android SDK 35.
2. Run `flutter pub get` in the parent directory.
3. Replace the debug release signing configuration before distribution.
4. Host the completed `assetlinks.json` at `https://kaspire.kaslab.space/.well-known/assetlinks.json`.
5. Keep Android backups disabled and verify the final merged manifest in CI.

The production hostname is `kaspire.kaslab.space`; keep the application ID and signing certificate aligned with its `assetlinks.json`.
