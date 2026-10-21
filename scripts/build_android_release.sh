#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client_configuration="${KASPIRE_ANDROID_CLIENT_CONFIGURATION:-/srv/kaspire/release-signing/android-public-clients.json}"
flutter_binary="${KASPIRE_FLUTTER_BINARY:-/srv/kaspire/toolchains/flutter/bin/flutter}"

python3 "$project_root/scripts/android_release_config.py" check --configuration "$client_configuration"
python3 "$project_root/scripts/android_release_config.py" check-mainnet
cd "$project_root/apps/mobile_flutter"
"$flutter_binary" build apk --release --no-pub \
    --target-platform android-arm,android-arm64 \
    --dart-define-from-file="$client_configuration" "$@"
python3 "$project_root/scripts/android_release_config.py" verify-apk \
    --configuration "$client_configuration" \
    --apk "$project_root/apps/mobile_flutter/build/app/outputs/flutter-apk/app-release.apk"
