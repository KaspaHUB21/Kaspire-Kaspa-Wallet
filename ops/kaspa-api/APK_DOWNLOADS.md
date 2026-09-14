# Latest-only website APK distribution

The website and WalletConnect installation page link to
`/downloads/Kaspire-Android-mainnet-latest.apk`. Only this APK is served by
the website. Nginx redirects other `.apk` URLs (including historical
versioned update URLs) to that endpoint with a non-cacheable 302 response.
Historical GitHub releases are not changed by this website policy.

The stable endpoint supplies an explicit filename and `no-store` headers.
Range requests are disabled: after replacing the latest binary, resuming a
partial older APK must not append bytes from the new version. Downloads
restart as complete responses instead. The server cannot cancel existing
browser download jobs, erase device caches, or deduplicate user-started jobs.

## Publishing the next release

1. Build, sign and verify the APK with the existing signing lineage.
2. Replace `website/public/downloads/Kaspire-Android-mainnet-latest.apk`
   with that verified APK and update release metadata and the signed manifest.
3. Run `node --test website/scripts/prepare-apk-download.test.mjs` and build
   the website. The build checks the latest binary against the manifest's
   SHA-256 and removes other APKs from **generated build output only**.
4. Deploy the built client directory. Use atomic file replacement (e.g.
   normal rsync, not `--inplace`) so clients cannot read a half-written APK.
5. Verify the public binary's hash and the old versioned links' redirects.

The signed manifest can keep its versioned APK URL for compatibility with
installed apps' URL validation. It redirects to the latest APK. A historical
manifest's hash therefore does not describe a newer redirected binary:
clients must fetch the fresh signed manifest and compare its hash.

No per-release nginx version edit is needed. The latest-only configuration
is maintained in `nginx-kaspire.conf`. Retired deployment binaries are kept
outside the public document root in `/var/www/kaspire/retired-apks.*` for
recovery; source/build archives are not public website downloads.
