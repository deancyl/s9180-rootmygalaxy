#!/usr/bin/env bash
# =============================================================================
# Build the Samsung-patched KernelSU v3.3.0 ksud for aarch64-android,
# with the dm3q S9180ZHS8FZG1 v3.3.0 module embedded as the late-load asset.
#
# Requirements: Android NDK r29 (r27+ works), rustup with target
# aarch64-linux-android, python3.
#
# Usage:
#   export ANDROID_NDK_HOME=/path/to/android-ndk-r29
#   ./02-build-ksud.sh
#
# Output:
#   out/ksud-dm3q-S9180ZHS8FZG1-330-kdp
# =============================================================================
set -euo pipefail

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your NDK path, e.g. /opt/android-ndk-r29}"

KSU_DIR="KernelSU"
OUT_DIR="out"
MOD="out/android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko"
ASSET_NAME="android13-5.15_kernelsu.ko"   # KMI auto-detected on device = android13-5.15
API=29
TARGET=aarch64-linux-android

[ -f "${MOD}" ] || { echo "ERROR: ${MOD} missing - run 01-build-module.sh first"; exit 1; }

echo "== [1/4] place module as the rust_embed late-load asset"
# rust_embed folder for aarch64 android builds: userspace/ksud/bin/aarch64
mkdir -p "${KSU_DIR}/userspace/ksud/bin/aarch64"
cp "${MOD}" "${KSU_DIR}/userspace/ksud/bin/aarch64/${ASSET_NAME}"
ls -l "${KSU_DIR}/userspace/ksud/bin/aarch64/"

echo "== [2/4] rustup target + NDK linker config"
rustup target add "${TARGET}" >/dev/null
LD="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}${API}-clang"
[ -f "${LD}" ] || LD="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}-clang"
[ -f "${LD}" ] || { echo "ERROR: NDK clang driver not found under ${ANDROID_NDK_HOME}"; exit 1; }

mkdir -p "${KSU_DIR}/userspace/ksud/.cargo"
cat > "${KSU_DIR}/userspace/ksud/.cargo/config.toml" <<EOF
[target.${TARGET}]
linker = "${LD}"
rustflags = ["-C", "link-arg=-landroid"]
EOF

echo "== [3/4] cargo build (release, aarch64-linux-android)"
cd "${KSU_DIR}/userspace/ksud"
cargo build --release --target "${TARGET}"
cd ../../..

echo "== [4/4] collect output"
mkdir -p "${OUT_DIR}"
cp "${KSU_DIR}/userspace/ksud/target/${TARGET}/release/ksud" \
   "${OUT_DIR}/ksud-dm3q-S9180ZHS8FZG1-330-kdp"
ls -l "${OUT_DIR}"
md5sum "${OUT_DIR}/ksud-dm3q-S9180ZHS8FZG1-330-kdp"
sha256sum "${OUT_DIR}/ksud-dm3q-S9180ZHS8FZG1-330-kdp"

echo ""
echo "IMPORTANT: verify the embedded asset really is the v3.3.0 module:"
echo "  python3 03-audit-module.sh   (runs extract + verify inside out/)"
