#!/usr/bin/env bash
# scripts/build_linux_multi.sh
# Cross-compile Paragon C-ABI for Linux:
#   - x86_64 (amd64)
#   - aarch64 (arm64)
#   - armv7 (armhf, GOARM=7)  <-- CPU-only by default (no WebGPU)
#
# Toolchains: Homebrew messense/macos-cross-toolchains (no Zig).
#   brew tap messense/macos-cross-toolchains
#   brew install x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu armv7-unknown-linux-gnueabihf
#
# Usage:
#   ./scripts/build_linux_multi.sh                # armv7 CPU-only (default)
#   ./scripts/build_linux_multi.sh --armv7-gpu    # armv7 try GPU (requires wgpu-native static lib)
#
# For --armv7-gpu, set:
#   export WGPU_ARMV7_INCLUDE="$ROOT/third_party/include"      # contains webgpu.h (and your headers)
#   export WGPU_ARMV7_LIB="$ROOT/third_party/armv7/lib"        # contains libwgpu_native.a (and deps)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
REL="${ROOT}/release"
mkdir -p "$REL"

has()       { command -v "$1" >/dev/null 2>&1; }
clean_dir() { rm -rf "$1" && mkdir -p "$1"; }
note()      { printf "\n%s\n" "$1"; }

ARMV7_GPU=0
if [[ "${1-}" == "--armv7-gpu" ]]; then
  ARMV7_GPU=1
fi

echo "Building Paragon C-ABI for Linux (amd64, arm64, armv7)"
echo "Build root: $ROOT"
echo "Artifacts : $REL"

# ----- sanity -----
if [[ "${OSTYPE:-}" != darwin* ]]; then
  echo "ERROR: Run this on macOS." >&2; exit 1
fi
if ! has go; then
  echo "ERROR: Go not found (install from https://go.dev/dl/)." >&2; exit 1
fi

X86_CC="x86_64-unknown-linux-gnu-gcc"
A64_CC="aarch64-unknown-linux-gnu-gcc"
A32_CC="armv7-unknown-linux-gnueabihf-gcc"

MISSING=0
for t in "$X86_CC" "$A64_CC" "$A32_CC"; do
  if ! has "$t"; then echo "WARN: Missing toolchain: $t"; MISSING=1; fi
done
if [[ $MISSING -eq 1 ]]; then
  echo "Install with:"
  echo "  brew tap messense/macos-cross-toolchains"
  echo "  brew install x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu armv7-unknown-linux-gnueabihf"
fi

# Common linker flags so the .so loads next to the bench
LDFLAGS_RPATH="-Wl,-rpath,'\$ORIGIN' -Wl,-z,origin -Wl,--as-needed"

# ---------- amd64 ----------
if has "$X86_CC"; then
  note "==> Building Linux AMD64 (x86_64)"
  OUT="${REL}/linux_amd64"
  clean_dir "$OUT"

  echo "Building Go shared library"
  CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC="$X86_CC" \
    go build -buildmode=c-shared -o "${OUT}/teleport_amd64_linux.so" "${ROOT}/main.go"

  cp "${OUT}/teleport_amd64_linux.h" "${OUT}/teleport.h"

  echo "Building C benchmark"
  "$X86_CC" -std=c11 "${ROOT}/simple_bench.c" \
    -I"$OUT" -L"$OUT" $LDFLAGS_RPATH \
    -l:"teleport_amd64_linux.so" -ldl -lm -lpthread \
    -o "${OUT}/simple_bench_linux_amd64"

  echo " AMD64 done."
else
  echo "✗ Skipping AMD64 (toolchain not installed)."
fi

# ---------- arm64 ----------
if has "$A64_CC"; then
  note "==> Building Linux ARM64 (aarch64)"
  OUT="${REL}/linux_arm64"
  clean_dir "$OUT"

  echo "Building Go shared library"
  CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC="$A64_CC" \
    go build -buildmode=c-shared -o "${OUT}/teleport_arm64_linux.so" "${ROOT}/main.go"

  cp "${OUT}/teleport_arm64_linux.h" "${OUT}/teleport.h"

  echo "Building C benchmark"
  "$A64_CC" -std=c11 "${ROOT}/simple_bench.c" \
    -I"$OUT" -L"$OUT" $LDFLAGS_RPATH \
    -l:"teleport_arm64_linux.so" -ldl -lm -lpthread \
    -o "${OUT}/simple_bench_linux_arm64"

  echo " ARM64 done."
else
  echo "✗ Skipping ARM64 (toolchain not installed)."
fi

# ---------- armv7 ----------
if has "$A32_CC"; then
  note "==> Building Linux ARMv7 (armhf, GOARM=7)"
  OUT="${REL}/linux_armv7"
  clean_dir "$OUT"

  if [[ "$ARMV7_GPU" -eq 1 ]]; then
    # Try GPU build: requires libwgpu_native.a + headers provided by env vars
    : "${WGPU_ARMV7_INCLUDE?Set WGPU_ARMV7_INCLUDE to the directory containing webgpu.h}"
    : "${WGPU_ARMV7_LIB?Set WGPU_ARMV7_LIB to the directory containing libwgpu_native.a}"

    export CGO_CFLAGS="-I${WGPU_ARMV7_INCLUDE}"
    export CGO_LDFLAGS="-L${WGPU_ARMV7_LIB} -lwgpu_native -ldl -lm -lpthread -lstdc++"

    echo "Building Go shared library (ARMv7 + GPU)"
    CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7 CC="$A32_CC" \
      go build -buildmode=c-shared -o "${OUT}/teleport_armv7_linux.so" "${ROOT}/main.go"
  else
    # CPU-only: compile with -tags nogpu to exclude WebGPU references
    echo "Building Go shared library (ARMv7 CPU-only, -tags nogpu)"
    CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7 CC="$A32_CC" \
      go build -tags nogpu -buildmode=c-shared -o "${OUT}/teleport_armv7_linux.so" "${ROOT}/main.go"
  fi

  # unify header name
  if [[ -f "${OUT}/teleport_armv7_linux.h" ]]; then
    cp "${OUT}/teleport_armv7_linux.h" "${OUT}/teleport.h"
  fi

  echo "Building C benchmark"
  "$A32_CC" -std=c11 "${ROOT}/simple_bench.c" \
    -I"$OUT" -L"$OUT" $LDFLAGS_RPATH \
    -l:"teleport_armv7_linux.so" -ldl -lm -lpthread \
    -o "${OUT}/simple_bench_linux_armv7" || {
      echo "Link failed for ARMv7 bench. If you attempted GPU on armv7, ensure libwgpu_native.a exists and deps are satisfied."
      exit 1
    }

  echo " ARMv7 done."
else
  echo "✗ Skipping ARMv7 (toolchain not installed)."
fi

# ---------- summary ----------
note "Build summary:"
for d in linux_amd64 linux_arm64 linux_armv7; do
  if [[ -d "${REL}/${d}" ]]; then
    echo "✓ ${d}: ${REL}/${d}/"
    ls -la "${REL}/${d}/"
  else
    echo "✗ ${d}: not built"
  fi
done

echo
echo "Notes:"
echo "- armv7 defaults to CPU-only (no WebGPU) to avoid missing wgpu link errors."
echo "- To try GPU on armv7: prepare libwgpu_native.a and run:"
echo "    export WGPU_ARMV7_INCLUDE=\"\$ROOT/third_party/include\""
echo "    export WGPU_ARMV7_LIB=\"\$ROOT/third_party/armv7/lib\""
echo "    ./scripts/build_linux_multi.sh --armv7-gpu"
echo "- Artifacts are Linux-only; verify with 'file' or test on target hardware."
