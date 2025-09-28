#!/usr/bin/env bash
# scripts/build_mac.sh
# Build Paragon C-ABI for macOS only (both Intel and Apple Silicon)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
REL="${ROOT}/release"
mkdir -p "$REL"

# ------------- helpers -------------
has() { command -v "$1" >/dev/null 2>&1; }
clean_dir() { rm -rf "$1" && mkdir -p "$1"; }

echo "Building Paragon C-ABI for macOS..."
echo "Build root: $ROOT"
echo "Artifacts : $REL"

# Check if we're actually on macOS
if [[ "${OSTYPE:-}" != darwin* ]]; then
    echo "ERROR: This script must be run on macOS"
    echo "Current OS: ${OSTYPE:-unknown}"
    exit 1
fi

# Check for required tools
if ! has clang; then
    echo "ERROR: clang not found. Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

if ! has go; then
    echo "ERROR: Go not found. Please install Go from https://golang.org/dl/"
    exit 1
fi

# ---------------- macOS Intel (x86_64) ----------------
echo ""
echo "==> Building macOS Intel (x86_64)..."
clean_dir "${REL}/darwin_amd64"

echo "Building Go shared library..."
CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 CC=clang \
    go build -buildmode=c-shared -o "${REL}/darwin_amd64/teleport_amd64_darwin.dylib" "${ROOT}/main.go"

# Copy header for the bench
cp "${REL}/darwin_amd64/teleport_amd64_darwin.h" "${REL}/darwin_amd64/teleport.h"

echo "Building C benchmark..."
clang -std=c11 -target x86_64-apple-macos10.15 "${ROOT}/simple_bench.c" \
    -I"${REL}/darwin_amd64" \
    -Wl,-rpath,@loader_path \
    "${REL}/darwin_amd64/teleport_amd64_darwin.dylib" \
    -o "${REL}/darwin_amd64/simple_bench_darwin_amd64"

echo "✓ macOS Intel build complete!"

# ---------------- macOS Apple Silicon (arm64) ----------------
echo ""
echo "==> Building macOS Apple Silicon (arm64)..."
clean_dir "${REL}/darwin_arm64"

echo "Building Go shared library..."
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 CC=clang \
    go build -buildmode=c-shared -o "${REL}/darwin_arm64/teleport_arm64_darwin.dylib" "${ROOT}/main.go"

# Copy header for the bench
cp "${REL}/darwin_arm64/teleport_arm64_darwin.h" "${REL}/darwin_arm64/teleport.h"

echo "Building C benchmark..."
clang -std=c11 -target arm64-apple-macos11.0 "${ROOT}/simple_bench.c" \
    -I"${REL}/darwin_arm64" \
    -Wl,-rpath,@loader_path \
    "${REL}/darwin_arm64/teleport_arm64_darwin.dylib" \
    -o "${REL}/darwin_arm64/simple_bench_darwin_arm64"

echo "✓ macOS Apple Silicon build complete!"

# ---------------- Universal Binary (optional) ----------------
echo ""
echo "==> Creating Universal Binary..."
clean_dir "${REL}/darwin_universal"

# Create universal dylib using lipo
lipo -create \
    "${REL}/darwin_amd64/teleport_amd64_darwin.dylib" \
    "${REL}/darwin_arm64/teleport_arm64_darwin.dylib" \
    -output "${REL}/darwin_universal/teleport_universal_darwin.dylib"

# Use arm64 header (they should be identical)
cp "${REL}/darwin_arm64/teleport.h" "${REL}/darwin_universal/teleport.h"

# Create universal benchmark binary
lipo -create \
    "${REL}/darwin_amd64/simple_bench_darwin_amd64" \
    "${REL}/darwin_arm64/simple_bench_darwin_arm64" \
    -output "${REL}/darwin_universal/simple_bench_darwin_universal"

echo "✓ Universal Binary created!"

echo ""
echo "Build summary:"
echo "=============="
echo "✓ macOS Intel (x86_64): ${REL}/darwin_amd64/"
ls -la "${REL}/darwin_amd64/"

echo ""
echo "✓ macOS Apple Silicon (arm64): ${REL}/darwin_arm64/"
ls -la "${REL}/darwin_arm64/"

echo ""
echo "✓ macOS Universal Binary: ${REL}/darwin_universal/"
ls -la "${REL}/darwin_universal/"

# Detect current architecture and suggest appropriate test
CURRENT_ARCH=$(uname -m)
echo ""
echo "Testing suggestions:"
echo "==================="
if [[ "$CURRENT_ARCH" == "x86_64" ]]; then
    echo "Current machine: Intel Mac"
    echo "  Test native: cd ${REL}/darwin_amd64 && ./simple_bench_darwin_amd64"
    echo "  Test universal: cd ${REL}/darwin_universal && ./simple_bench_darwin_universal"
elif [[ "$CURRENT_ARCH" == "arm64" ]]; then
    echo "Current machine: Apple Silicon Mac"
    echo "  Test native: cd ${REL}/darwin_arm64 && ./simple_bench_darwin_arm64"
    echo "  Test universal: cd ${REL}/darwin_universal && ./simple_bench_darwin_universal"
fi

echo "  Test Intel on Apple Silicon: cd ${REL}/darwin_amd64 && arch -x86_64 ./simple_bench_darwin_amd64"
echo "  Check architectures: file ${REL}/darwin_universal/teleport_universal_darwin.dylib"
echo ""
echo "All macOS builds complete! 🍎"