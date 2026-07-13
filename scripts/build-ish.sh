#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS with Xcode installed." >&2
  exit 1
fi

for command in xcodebuild xcrun meson; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command not found." >&2
    exit 1
  fi
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_SOURCE_DIR="${ISH_SOURCE_DIR:-$ROOT_DIR/third_party/ish-arm64}"
ISH_GUEST_ARCH="${ISH_GUEST_ARCH:-arm64}"

if [[ "$ISH_GUEST_ARCH" != "arm64" ]]; then
  echo "The supported Acode iOS runtime currently requires ISH_GUEST_ARCH=arm64." >&2
  exit 64
fi

ISH_DIR="$(cd "$ISH_SOURCE_DIR" 2>/dev/null && pwd || true)"
if [[ -z "$ISH_DIR" || ! -f "$ISH_DIR/meson.build" ]]; then
  echo "iSH source not found at $ISH_SOURCE_DIR" >&2
  exit 1
fi

OUTPUT_DIR="${ISH_OUTPUT_DIR:-$ISH_DIR/build}"

echo "==> iSH source: $ISH_DIR"
echo "==> Runtime: userspace iSH kernel, arm64 guest"
echo "==> Output directory: $OUTPUT_DIR"

build_fakefs_import() {
  local sdk="$1"
  local target="$2"
  local build_dir="$3"
  local meson_dir="$build_dir/meson"
  local sysroot
  local deployment_flag
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  deployment_flag="-miphoneos-version-min=15.0"
  [[ "$sdk" == "iphonesimulator" ]] && deployment_flag="-mios-simulator-version-min=15.0"

  echo "==> Adding fakefs import support for $sdk..."
  (
    cd "$meson_dir"
    while xcrun --sdk "$sdk" ar -t libfakefs.a | rg -q '^(tools_fakefs\.c\.o|util_fchdir\.c\.o)$'; do
      xcrun --sdk "$sdk" ar -d libfakefs.a tools_fakefs.c.o util_fchdir.c.o
    done

    rm -rf libfakefs_import.a.p libfakefs_import.a libfakefs-merged.a
    mkdir -p libfakefs_import.a.p

    xcrun --sdk "$sdk" clang \
      -target "$target" \
      -isysroot "$sysroot" \
      "$deployment_flag" \
      -I. \
      -I"$ISH_DIR" \
      -I"$ISH_DIR/deps/libarchive/libarchive" \
      -DLOG_HANDLER_NSLOG=1 \
      -DGUEST_ARM64=1 \
      -std=gnu11 \
      -O2 \
      -c "$ISH_DIR/tools/fakefs.c" \
      -o libfakefs_import.a.p/tools_fakefs.c.o

    xcrun --sdk "$sdk" libtool -static -o libfakefs_import.a \
      libfakefs_import.a.p/tools_fakefs.c.o
    xcrun --sdk "$sdk" libtool -static -o libfakefs-merged.a libfakefs.a libfakefs_import.a
    mv libfakefs-merged.a libfakefs.a
    rm -rf libfakefs_import.a.p libfakefs_import.a
  )
}

verify_archive() {
  local sdk="$1"
  local archive="$2"
  shift 2

  if [[ ! -f "$archive" ]]; then
    echo "ERROR: missing archive: $archive" >&2
    exit 1
  fi

  local architectures
  architectures="$(xcrun lipo -archs "$archive")"
  if [[ " $architectures " != *" arm64 "* ]]; then
    echo "ERROR: $archive does not contain arm64 (found: $architectures)" >&2
    exit 1
  fi

  local symbols
  symbols="$(xcrun --sdk "$sdk" nm -gU "$archive")"
  for symbol in "$@"; do
    if ! rg -q "[[:space:]]_$symbol$" <<<"$symbols"; then
      echo "ERROR: $archive is missing required symbol $symbol" >&2
      exit 1
    fi
  done
}

build_sdk() {
  local sdk="$1"
  local target="$2"
  shift 2
  local build_name="Release-arm64-$sdk"
  local build_dir="$OUTPUT_DIR/$build_name"

  echo "==> Building supported iSH ARM64 archives for $sdk..."
  xcodebuild \
    -project "$ISH_DIR/deps/libarchive.xcodeproj" \
    -target libarchive \
    -configuration Release \
    -sdk "$sdk" \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 \
    HEADER_SEARCH_PATHS="$(brew --prefix xz)/include" \
    GCC_PREPROCESSOR_DEFINITIONS="HAVE_CONFIG_H HAVE_LZMA_H=1" \
    CONFIGURATION_BUILD_DIR="$build_dir" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    build

  xcodebuild \
    -project "$ISH_DIR/iSH.xcodeproj" \
    -target iSH-ARM64 \
    -configuration Release \
    -sdk "$sdk" \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 \
    GUEST_ARCH=arm64 \
    ISH_KERNEL=ish \
    BUILD_DIR="$OUTPUT_DIR" \
    CONFIGURATION_BUILD_DIR="$build_dir" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    build

  build_fakefs_import "$sdk" "$target" "$build_dir"

  verify_archive "$sdk" "$build_dir/meson/libish.a" \
    mount_root become_first_process become_new_init_child create_stdio do_execve task_start pty_open_fake
  verify_archive "$sdk" "$build_dir/meson/libish_emu.a"
  verify_archive "$sdk" "$build_dir/meson/libfakefs.a" fakefs_import fakefs_import_directory
  verify_archive "$sdk" "$build_dir/libarchive.a"
}

build_sdk iphoneos arm64-apple-ios15.0
build_sdk iphonesimulator arm64-apple-ios15.0-simulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64

echo "==> Supported iSH ARM64 builds succeeded:"
for sdk in iphoneos iphonesimulator; do
  build_dir="$OUTPUT_DIR/Release-arm64-$sdk"
  for archive in meson/libish.a meson/libish_emu.a meson/libfakefs.a libarchive.a; do
    archive_path="$build_dir/$archive"
    echo "    $archive_path ($(du -h "$archive_path" | cut -f1))"
  done
done
