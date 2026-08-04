# F-Droid packaging

Kaspire is prepared for a source-only F-Droid build. The packaging recipe must
delete every committed Android `.so` file before building, compile
`kaspa_secure_core` from the pinned `Cargo.lock`, and let F-Droid sign the
unsigned release APK.

## Publication workflow

1. Publish the complete source tree.
2. Add an immutable release tag matching `apps/mobile_flutter/pubspec.yaml`.
3. Add the matching version-code changelog under
   `fastlane/metadata/android/en-US/changelogs/`.
4. Submit `space.kaspire.wallet.yml` to `fdroid/fdroiddata`.

The current recipe targets Kaspire 0.11.15 (version code 73) at tag
`v0.11.15`. The recipe removes generated JNI libraries and the Rust target
directory before rebuilding the native security core from source.

IzzyOnDroid reads the app description, icon, screenshots and version-code
changelogs from `fastlane/metadata/android/en-US/` in this repository.

F-Droid signs its APK with a different certificate from Google Play. Android
does not permit an in-place upgrade between those distributions. Users must
back up their recovery phrase and uninstall one distribution before installing
the other.
