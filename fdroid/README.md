# F-Droid packaging

Kaspire is prepared for a source-only F-Droid build. The packaging recipe must
delete every committed Android `.so` file before building, compile
`kaspa_secure_core` from the pinned `Cargo.lock`, and let F-Droid sign the
unsigned release APK.

## Publication workflow

1. Publish the complete source tree.
2. Add an immutable `v0.10.7` tag to the reviewed release commit.
3. Submit `space.kasvault.wallet.yml` to `fdroid/fdroiddata`.

F-Droid signs its APK with a different certificate from Google Play. Android
does not permit an in-place upgrade between those distributions. Users must
back up their recovery phrase and uninstall one distribution before installing
the other.
