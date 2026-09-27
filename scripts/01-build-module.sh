#!/usr/bin/env bash
# =============================================================================
# Build the KernelSU v3.3.0 Samsung KDP/RKP/DEFEX kernel module for
# dm3q / SM-S9180 / S9180ZHS8FZG1 (android13-5.15 KMI).
#
# Run on a machine with docker + git. Produces:
#   out/android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko
#
# Usage:
#   ./01-build-module.sh
#
# Override via env:
#   DDK_IMAGE=ghcr.io/ylarod/ddk-min:android13-5.15-<date-tag>
#   TARGET_RELEASE=5.15.189-android13-8-33413713-abS9180ZHS8FZG1
#   KSU_VERSION=32601
# =============================================================================
set -euo pipefail

KSU_TAG="v3.3.0"
KSU_VERSION="${KSU_VERSION:-32601}"
TARGET_RELEASE="${TARGET_RELEASE:-5.15.189-android13-8-33413713-abS9180ZHS8FZG1}"
DDK_IMAGE="${DDK_IMAGE:-ghcr.io/ylarod/ddk-min:android13-5.15-latest}"
PATCH="patch/KernelSU-v3.3.0-samsung-kdp-rkp-defex.patch"
OUT_DIR="out"
KSU_DIR="KernelSU"

echo "== [1/5] checkout KernelSU ${KSU_TAG} (full clone: version = 30000 + git rev count = 32601)"
if [ ! -d "${KSU_DIR}" ]; then
    git clone --branch "${KSU_TAG}" https://github.com/tiann/KernelSU "${KSU_DIR}"
fi

echo "== [2/5] apply Samsung KDP/RKP/DEFEX patch (v3.3.0 port)"
cd "${KSU_DIR}"
git reset --hard >/dev/null
git clean -fd kernel/ userspace/ksud/bin/ >/dev/null 2>&1 || true
git apply --check "${PATCH}"
git apply "${PATCH}"
echo "   patch applied cleanly"

echo "== [3/5] docker DDK build (${DDK_IMAGE})"
docker run --rm \
    -v "$(pwd):/workspace" \
    -w /workspace/kernel \
    -e TARGET_RELEASE="${TARGET_RELEASE}" \
    -e KSU_VERSION="${KSU_VERSION}" \
    "${DDK_IMAGE}" \
    bash -lc '
      set -euo pipefail
      echo "container KDIR=$KDIR"
      # Override the DDK generated release so vermagic carries the exact
      # target string. The late-load manual-relocation loader re-stamps
      # vermagic from kmsg anyway, but keep it exact for audits.
      if [ -n "${KDIR:-}" ]; then
        sed -i "s/^#define UTS_RELEASE.*/#define UTS_RELEASE \"${TARGET_RELEASE}\"/" \
          "$KDIR/include/generated/utsrelease.h" 2>/dev/null || true
        echo "${TARGET_RELEASE}" > "$KDIR/include/config/kernel.release" 2>/dev/null || true
      fi
      make clean || true
      make KDIR="$KDIR" \
           KSU_VERSION="${KSU_VERSION}" \
           CONFIG_KSU=m \
           CONFIG_KSU_SAMSUNG_KDP=y \
           CONFIG_KSU_SAMSUNG_RKP=y \
           CONFIG_KSU_SAMSUNG_DEFEX=y \
           CC=clang LLVM=1 -j"$(nproc)"
      modinfo ./kernelsu.ko || true
    '

echo "== [4/5] strip debug info only (KEEP symtab: the late-load loader reads it)"
if command -v llvm-strip >/dev/null 2>&1; then
    llvm-strip -d kernel/kernelsu.ko
elif docker image inspect "${DDK_IMAGE}" >/dev/null 2>&1; then
    docker run --rm -v "$(pwd):/workspace" -w /workspace/kernel \
        "${DDK_IMAGE}" llvm-strip -d kernelsu.ko
else
    echo "   WARN: llvm-strip not found, shipping unstripped (larger but functional) module"
fi

echo "== [5/5] collect output"
cd ..
mkdir -p "${OUT_DIR}"
cp "${KSU_DIR}/kernel/kernelsu.ko" "${OUT_DIR}/android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko"
ls -l "${OUT_DIR}"
md5sum "${OUT_DIR}/"*.ko
sha256sum "${OUT_DIR}/"*.ko

echo ""
echo "NEXT: run ./03-audit-module.sh against the recovered FZG1 vmlinux.elf"
echo "      then run ./02-build-ksud.sh to embed this module into ksud."
