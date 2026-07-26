#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"

if [[ -z "$ndk_root" ]]; then
  echo "ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) must point to an Android NDK." >&2
  exit 1
fi

toolchain="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64"
if [[ ! -d "$toolchain" ]]; then
  echo "Unsupported or missing Android NDK toolchain: $toolchain" >&2
  exit 1
fi

api=26
output="$project_root/apps/mobile_flutter/android/app/src/main/jniLibs"
rm -f \
  "$output/arm64-v8a/libkaspa_secure_core.so" \
  "$output/armeabi-v7a/libkaspa_secure_core.so"
mkdir -p "$output/arm64-v8a" "$output/armeabi-v7a"

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$toolchain/bin/aarch64-linux-android${api}-clang"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$toolchain/bin/armv7a-linux-androideabi${api}-clang"
export CC_aarch64_linux_android="$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"
export CC_armv7_linux_androideabi="$CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER"
export AR_aarch64_linux_android="$toolchain/bin/llvm-ar"
export AR_armv7_linux_androideabi="$toolchain/bin/llvm-ar"

cd "$project_root"
cargo build --locked --release --package kaspa_secure_core \
  --target aarch64-linux-android
cargo build --locked --release --package kaspa_secure_core \
  --target armv7-linux-androideabi

install -m 0644 \
  "$project_root/target/aarch64-linux-android/release/libkaspa_secure_core.so" \
  "$output/arm64-v8a/libkaspa_secure_core.so"
install -m 0644 \
  "$project_root/target/armv7-linux-androideabi/release/libkaspa_secure_core.so" \
  "$output/armeabi-v7a/libkaspa_secure_core.so"

echo "Built Kaspire's Rust security core for arm64-v8a and armeabi-v7a."
