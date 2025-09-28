#!/usr/bin/env bash
# scripts/build_all.sh
# Build Paragon C-ABI ("teleport") + C bench for multiple OS/ARCH targets.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
REL="${ROOT}/release"
mkdir -p "$REL"

# ------------- tiny helpers -------------
has() { command -v "$1" >/dev/null 2>&1; }
clean_dir() { rm -rf "$1" && mkdir -p "$1"; }

# build Go shared lib: emits teleport_<arch>_<os>.<ext> and teleport_<arch>_<os>.h
# args: goos goarch outdir cc ext
build_go_cshared () {
  local goos="$1" goarch="$2" outdir="$3" cc="$4" ext="$5"
  echo "==> Go c-shared ${goos}/${goarch} → ${outdir}"
  clean_dir "$outdir"

  CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" CC="$cc" \
    go build -buildmode=c-shared -o "${outdir}/teleport_${goarch}_${goos}.${ext}" "${ROOT}/main.go"

  # Canonical header for the bench
  cp "${outdir}/teleport_${goarch}_${goos}.h" "${outdir}/teleport.h"
}

# link C bench against the just-built lib (Linux)
# args: outdir libfilename exe
build_c_bench_linux () {
  local outdir="$1" libfile="$2" exe="$3"
  echo "==> gcc bench (Linux) → ${outdir}/${exe}"
  gcc -std=c11 "${ROOT}/simple_bench.c" -I"$outdir" -L"$outdir" \
      -Wl,-rpath,'$ORIGIN' \
      -l:"$libfile" -ldl -lm -lpthread -o "${outdir}/${exe}"
}

# link C bench (macOS)
build_c_bench_macos () {
  local outdir="$1" libfile="$2" exe="$3"
  echo "==> clang bench (macOS) → ${outdir}/${exe}"
  clang -std=c11 "${ROOT}/simple_bench.c" -I"$outdir" -L"$outdir" \
        -Wl,-rpath,@loader_path \
        -l:"$libfile" -o "${outdir}/${exe}"
}

# link C bench with MinGW cross-compiler (Windows)
# args: outdir libfile exe triplet
build_c_bench_mingw () {
  local outdir="$1" libfile="$2" exe="$3" triplet="$4"
  echo "==> ${triplet}-gcc bench (Windows) → ${outdir}/${exe}"
  ${triplet}-gcc -std=c11 "${ROOT}/simple_bench.c" -I"$outdir" -L"$outdir" \
      -l:"$libfile" -o "${outdir}/${exe}"
}

echo "Build root: $ROOT"
echo "Artifacts : $REL"

# ---------------- Linux amd64 ----------------
if has gcc; then
  build_go_cshared linux amd64 "${REL}/linux_amd64" gcc so
  build_c_bench_linux "${REL}/linux_amd64" "teleport_amd64_linux.so" "simple_bench_linux_amd64"
else
  echo "SKIP linux/amd64 C bench (gcc not found)"; fi

# ---------------- Linux arm64 ----------------
if has aarch64-linux-gnu-gcc; then
  build_go_cshared linux arm64 "${REL}/linux_arm64" aarch64-linux-gnu-gcc so
  echo "NOTE: linux/arm64 C bench usually built on an arm64 host."
  # If you *do* have an arm64 sysroot + cross libs, uncomment below:
  # aarch64-linux-gnu-gcc -std=c11 "${ROOT}/simple_bench.c" -I"${REL}/linux_arm64" -L"${REL}/linux_arm64" \
  #   -Wl,-rpath,'$ORIGIN' -l:"teleport_arm64_linux.so" -ldl -lm -lpthread \
  #   -o "${REL}/linux_arm64/simple_bench_linux_arm64"
else
  echo "SKIP linux/arm64 (aarch64-linux-gnu-gcc not found)"; fi

# ---------------- macOS builds (run on macOS) ----------------
if [[ "${OSTYPE:-}" == darwin* ]]; then
  if has clang; then
    build_go_cshared darwin amd64 "${REL}/darwin_amd64" clang dylib
    build_c_bench_macos "${REL}/darwin_amd64" "teleport_amd64_darwin.dylib" "simple_bench_darwin_amd64"

    build_go_cshared darwin arm64 "${REL}/darwin_arm64" clang dylib
    build_c_bench_macos "${REL}/darwin_arm64" "teleport_arm64_darwin.dylib" "simple_bench_darwin_arm64"
  else
    echo "SKIP darwin builds (clang not found)"; fi
else
  echo "TIP: build macOS dylibs on macOS (or via osxcross)."
fi

# ---------------- Windows builds (cross via MinGW) ----------------
if has x86_64-w64-mingw32-gcc; then
  build_go_cshared windows amd64 "${REL}/windows_amd64" x86_64-w64-mingw32-gcc dll
  build_c_bench_mingw "${REL}/windows_amd64" "teleport_amd64_windows.dll" "simple_bench_windows_amd64.exe" x86_64-w64-mingw32
else
  echo "SKIP windows/amd64 (x86_64-w64-mingw32-gcc not found)"; fi

if has aarch64-w64-mingw32-gcc; then
  build_go_cshared windows arm64 "${REL}/windows_arm64" aarch64-w64-mingw32-gcc dll
  build_c_bench_mingw "${REL}/windows_arm64" "teleport_arm64_windows.dll" "simple_bench_windows_arm64.exe" aarch64-w64-mingw32
else
  echo "SKIP windows/arm64 (aarch64-w64-mingw32-gcc not found)"; fi

echo "All done. See ${REL}"
