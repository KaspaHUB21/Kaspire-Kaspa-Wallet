# Latest-only website APK distribution

The website and WalletConnect installation page link to
`/downloads/Kaspire-Android-mainnet-latest.apk`. Only this APK is served by
the website. Nginx redirects other `.apk` URLs (including historical
versioned update URLs) to that endpoint with a non-cacheable 302 response.
Historical GitHub releases are not changed by this website policy.

The active production nginx configuration aliases that endpoint to
`/var/www/kaspire/releases/Kaspire-Android-mainnet-latest.apk`, outside the
website document root. Updating the website's `downloads` directory alone
does not publish a new APK. Confirm the active alias before deployment; the
checked-in base nginx template may not include production-only locations.

The stable endpoint supplies an explicit filename and `no-store` headers.
Range requests are disabled: after replacing the latest binary, resuming a
partial older APK must not append bytes from the new version. Downloads
restart as complete responses instead. The server cannot cancel existing
browser download jobs, erase device caches, or deduplicate user-started jobs.

## Publishing the next release

1. Build with `bash scripts/build_android_release.sh`, which validates the
   publishable Android client configuration and inspects both compiled APK
   slices. Gradle also rejects release builds missing that configuration.
   Sign and verify the APK with the existing signing lineage.
2. Replace `website/public/downloads/Kaspire-Android-mainnet-latest.apk`
   with that verified APK and update release metadata and the signed manifest.
3. Run `node --test website/scripts/prepare-apk-download.test.mjs` and build
   the website. The build checks the latest binary against the manifest's
   SHA-256 and removes other APKs from **generated build output only**.
4. Back up the active release APK and manifest. Atomically replace the
   verified APK at the active nginx alias above, then publish the matching
   signed update manifest and website files. Preserve unrelated downloads
   and update channels. Use atomic file replacement (e.g. normal rsync,
   not `--inplace`) so clients cannot read a half-written APK.
5. Verify the public binary's hash and the old versioned links' redirects.

The signed manifest can keep its versioned APK URL for compatibility with
installed apps' URL validation. It redirects to the latest APK. A historical
manifest's hash therefore does not describe a newer redirected binary:
clients must fetch the fresh signed manifest and compare its hash.

No per-release nginx version edit is needed. The latest-only configuration
is maintained in `nginx-kaspire.conf`. Retired deployment binaries are kept
outside the public document root in `/var/www/kaspire/retired-apks.*` for
recovery; source/build archives are not public website downloads.

## Internal Android updates (0.11.68+)

The in-app GitHub option uses the same trusted signed Android manifest, never
GitHub's mixed-platform Latest release as its authority. It derives the exact
asset URL `.../releases/download/vVERSION/Kaspire-Android-mainnet-vVERSION.apk`.
Publish that GitHub release and APK asset **before** advertising the version in
the public signed update manifest, so a newly offered internal update cannot
point at a private draft or a missing asset. Preserve the old website route.

Native Android code bounds HTTPS redirects/download size/time, verifies the
signed terms again, hashes the complete APK and checks package, build/version
and installed signing identity/rotation history. Only its private updater cache
is exposed to Android's installer through a non-exported, scoped FileProvider.
Unknown-source permission and installation confirmation remain Android's job;
opening the installer is not proof of a successful installation. Test an actual
upgrade on a physical device after a subsequent newer release becomes available.
