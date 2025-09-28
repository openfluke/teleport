#!/usr/bin/env bash
# scripts/build_simple.sh
# Build Paragon C-ABI for Linux and Windows x86_64 only

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
REL="${ROOT}/release"
mkdir -p "$REL"

# ------------- helpers -------------
has() { command -v "$1" >/dev/null 2>&1; }
clean_dir() { rm -rf "$1" && mkdir -p "$1"; }

echo "Building Paragon C-ABI for Linux and Windows x64..."
echo "Build root: $ROOT"
echo "Artifacts : $REL"

# ---------------- Linux amd64 ----------------
echo ""
echo "==> Building Linux x86_64..."
clean_dir "${REL}/linux_amd64"

if has gcc; then
    echo "Building Go shared library..."
    CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC=gcc \
        go build -buildmode=c-shared -o "${REL}/linux_amd64/teleport_amd64_linux.so" "${ROOT}/main.go"
    
    # Copy header for the bench
    cp "${REL}/linux_amd64/teleport_amd64_linux.h" "${REL}/linux_amd64/teleport.h"
    
    echo "Building C benchmark..."
    gcc -std=c11 "${ROOT}/simple_bench.c" \
        -I"${REL}/linux_amd64" -L"${REL}/linux_amd64" \
        -Wl,-rpath,'$ORIGIN' \
        -l:"teleport_amd64_linux.so" -ldl -lm -lpthread \
        -o "${REL}/linux_amd64/simple_bench_linux_amd64"
    
    echo "✓ Linux build complete!"
else
    echo "✗ gcc not found - skipping Linux build"
fi

# ---------------- Windows amd64 ----------------
echo ""
echo "==> Building Windows x86_64..."
clean_dir "${REL}/windows_amd64"

if has x86_64-w64-mingw32-gcc; then
    echo "Building Go shared library..."
    CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc \
        go build -buildmode=c-shared -o "${REL}/windows_amd64/teleport_amd64_windows.dll" "${ROOT}/main.go"
    
    # Copy header for the bench
    cp "${REL}/windows_amd64/teleport_amd64_windows.h" "${REL}/windows_amd64/teleport.h"
    
    echo "Building C benchmark..."
    x86_64-w64-mingw32-gcc -std=c11 "${ROOT}/simple_bench.c" \
        -I"${REL}/windows_amd64" -L"${REL}/windows_amd64" \
        -l:"teleport_amd64_windows.dll" \
        -o "${REL}/windows_amd64/simple_bench_windows_amd64.exe"
    
    echo "✓ Windows build complete!"
else
    echo "✗ x86_64-w64-mingw32-gcc not found - skipping Windows build"
    echo "  Install with: sudo dnf install mingw64-gcc"
fi

echo ""
echo "Build summary:"
echo "=============="
if [[ -f "${REL}/linux_amd64/teleport_amd64_linux.so" ]]; then
    echo "✓ Linux x86_64: ${REL}/linux_amd64/"
    ls -la "${REL}/linux_amd64/"
else
    echo "✗ Linux x86_64: not built"
fi

if [[ -f "${REL}/windows_amd64/teleport_amd64_windows.dll" ]]; then
    echo "✓ Windows x86_64: ${REL}/windows_amd64/"
    ls -la "${REL}/windows_amd64/"
else
    echo "✗ Windows x86_64: not built"
fi

echo ""
echo "To test Linux build:"
echo "  cd ${REL}/linux_amd64 && ./simple_bench_linux_amd64"
echo ""
echo "To test Windows build (with Wine):"
echo "  cd ${REL}/windows_amd64 && wine simple_bench_windows_amd64.exe"