#!/usr/bin/env bash
# scripts/build_android.sh
# Build Paragon C-ABI for Android (ARM64) on macOS

set -euo pipefail

has() { command -v "$1" >/dev/null 2>&1; }
clean_dir() { rm -rf "$1" && mkdir -p "$1"; }

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
REL="${ROOT}/release/android_arm64"
mkdir -p "$REL"

API="${API:-21}"  # Android 5.0+ (first 64-bit)
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/homebrew/share/android-ndk}"

echo "Building Paragon C-ABI for Android ARM64..."
echo "Root: $ROOT"
echo "Out : $REL"
echo "NDK : $ANDROID_NDK_HOME"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: run this on macOS." >&2; exit 1
fi
if ! has go; then
  echo "ERROR: Go not found." >&2; exit 1
fi
if [[ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]]; then
  echo "ERROR: ANDROID_NDK_HOME invalid: $ANDROID_NDK_HOME" >&2; exit 1
fi

# Prefer arm64 prebuilt on Apple Silicon; fall back to x86_64 if needed
if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
  PREBUILT_DIR="darwin-arm64"
elif [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
  PREBUILT_DIR="darwin-x86_64"
else
  echo "ERROR: NDK llvm prebuilt not found (darwin-arm64/x86_64)." >&2; exit 1
fi

LLVM_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$PREBUILT_DIR/bin"
SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$PREBUILT_DIR/sysroot"
CC_BIN="$LLVM_BIN/aarch64-linux-android${API}-clang"   # sets min SDK; defines __ANDROID_API__ itself
AR_BIN="$LLVM_BIN/llvm-ar"

echo "CC  : $CC_BIN"

clean_dir "$REL"

echo "==> go build (android/arm64)"
# No manual -D__ANDROID_API__ here; clang already sets it via the target triple
CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
  CC="$CC_BIN" \
  CGO_CFLAGS="--sysroot=$SYSROOT" \
  CGO_LDFLAGS="--sysroot=$SYSROOT" \
  go build -v -buildmode=c-shared -o "$REL/teleport_android_arm64.so" "$ROOT/main.go"

cp "$REL/teleport_android_arm64.h" "$REL/teleport.h"

echo "==> build C bench (links to .so)"
# No -D__ANDROID_API__ here either
"$CC_BIN" -std=c11 --sysroot="$SYSROOT" \
  -I"$REL" \
  "$ROOT/simple_bench.c" \
  -L"$REL" -l:teleport_android_arm64.so -lm \
  -o "$REL/simple_bench_android_arm64"

echo ""
echo "Build summary:"
echo "=============="
ls -la "$REL"

cat <<EOF

Run on device/emulator:
  adb push "$REL/teleport_android_arm64.so" /data/local/tmp/
  adb push "$REL/simple_bench_android_arm64" /data/local/tmp/
  adb shell "cd /data/local/tmp && chmod +x simple_bench_android_arm64 && LD_LIBRARY_PATH=. ./simple_bench_android_arm64"

Notes:
- If GPU paths via wgpu cause issues on some devices, run with your CPU-only flag/env.
EOF
