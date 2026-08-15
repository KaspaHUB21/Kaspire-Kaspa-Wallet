#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 VERSION BUILD MINIMUM_BUILD PUBLISHED_AT SHA256 OUTPUT" >&2
  exit 2
fi

version=$1
build=$2
minimum_build=$3
published_at=$4
sha256=$5
output=$6

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $build =~ ^[0-9]+$ ]]
[[ $minimum_build =~ ^[0-9]+$ ]]
[[ $published_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
[[ $sha256 =~ ^[0-9a-f]{64}$ ]]

signing_dir=/srv/kaspire/release-signing
p12="$signing_dir/kaspire-android-release-v1.p12"
password_file="$signing_dir/kaspire-android-release-v1.password"
payload_file=$(mktemp)
signature_file=$(mktemp)
private_key_file=$(mktemp)
trap 'rm -f "$payload_file" "$signature_file" "$private_key_file"' EXIT
chmod 600 "$private_key_file"

apk_url="https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v$version.apk"
notes_url="https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/v$version"

printf '{"version":"%s","build":%s,"minimumBuild":%s,"critical":false,"publishedAt":"%s","apkUrl":"%s","sha256":"%s","releaseNotesUrl":"%s"}' \
  "$version" "$build" "$minimum_build" "$published_at" "$apk_url" "$sha256" "$notes_url" \
  > "$payload_file"

openssl pkcs12 -in "$p12" -nocerts -nodes \
  -passin "file:$password_file" -out "$private_key_file" >/dev/null 2>&1
openssl dgst -sha256 -sign "$private_key_file" \
  -out "$signature_file" "$payload_file"

payload=$(base64 -w0 "$payload_file")
signature=$(base64 -w0 "$signature_file")
printf '{"payload":"%s","signature":"%s"}\n' "$payload" "$signature" > "$output"
