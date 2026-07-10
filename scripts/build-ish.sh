#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS with Xcode installed."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode and Command Line Tools."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="$ROOT_DIR/third_party/ish"
OUTPUT_DIR="$ISH_DIR/build"
LINUX_SRC="$ISH_DIR/deps/linux"
LINUX_BUILD="$LINUX_SRC/build"
AUTOCONF_SOURCE="$LINUX_BUILD/include/config/auto.conf"
AUTOCONF_HEADER="$LINUX_BUILD/include/generated/autoconf.h"
LLVM_OBJCOPY="${LLVM_OBJCOPY:-$(command -v llvm-objcopy || true)}"

if [[ -z "$LLVM_OBJCOPY" && -x /opt/homebrew/opt/llvm/bin/llvm-objcopy ]]; then
  LLVM_OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
fi

if [[ -z "$LLVM_OBJCOPY" ]]; then
  echo "llvm-objcopy not found. Install LLVM (for example: brew install llvm) or set LLVM_OBJCOPY."
  exit 1
fi

if [[ ! -d "$ISH_DIR" ]]; then
  echo "iSH source not found at $ISH_DIR"
  exit 1
fi

if [[ ! -d "$LINUX_SRC" || -z "$(ls -A "$LINUX_SRC" 2>/dev/null)" ]]; then
  echo "deps/linux submodule not initialized. Run:"
  echo "  cd $ISH_DIR && git submodule update --init deps/linux"
  echo "Or clone manually:"
  echo "  git clone --depth=1 https://github.com/ish-app/linux $LINUX_SRC"
  exit 1
fi

echo "==> Generating kernel headers..."
mkdir -p "$LINUX_BUILD"
make -C "$LINUX_SRC" ARCH=ish O="$LINUX_BUILD" ish_defconfig
make -C "$LINUX_SRC" ARCH=ish O="$LINUX_BUILD" LLVM_IAS=1 prepare

if [[ ! -f "$AUTOCONF_HEADER" && -f "$AUTOCONF_SOURCE" ]]; then
  mkdir -p "$(dirname "$AUTOCONF_HEADER")"
  awk '
    /^CONFIG_[A-Za-z0-9_]+=/ {
      name = $0
      sub(/=.*/, "", name)
      value = $0
      sub(/^[^=]*=/, "", value)
      if (value == "y") {
        print "#define " name " 1"
      } else if (value == "m") {
        print "#define " name "_MODULE 1"
      } else if (value ~ /^"/) {
        print "#define " name " " value
      } else {
        print "#define " name " " value
      }
    }
  ' "$AUTOCONF_SOURCE" > "$AUTOCONF_HEADER"
fi

echo "==> Checking generated headers..."
for f in autoconf.h utsrelease.h bounds.h timeconst.h asm-offsets.h; do
  if [[ ! -f "$LINUX_BUILD/include/generated/$f" ]]; then
    echo "ERROR: Missing $LINUX_BUILD/include/generated/$f"
    exit 1
  fi
done
echo "    All generated headers found."

copy_kernel_headers() {
  local build_name="$1"
  local meson_deps="$OUTPUT_DIR/$build_name/meson/deps"

  echo "==> Copying kernel headers for $build_name..."
  mkdir -p "$meson_deps/linux/arch/ish/include/generated"
  mkdir -p "$meson_deps/linux/arch/ish/include/generated/uapi"
  mkdir -p "$meson_deps/linux/arch/x86"
  mkdir -p "$meson_deps/arch/x86"
  mkdir -p "$meson_deps/linux/include"
  mkdir -p "$meson_deps/linux/include/generated"
  mkdir -p "$meson_deps/linux/include/generated/uapi"

  rm -rf "$meson_deps/linux/arch/ish/include/generated/asm"
  rm -rf "$meson_deps/linux/arch/ish/include/generated/uapi/asm"
  rm -rf "$meson_deps/linux/arch/x86/include"
  rm -rf "$meson_deps/arch/x86/include"
  rm -f "$meson_deps/linux/include/generated/autoconf.h"
  rm -f "$meson_deps/linux/include/utsrelease.h"
  rm -f "$meson_deps/linux/include/bounds.h"
  rm -f "$meson_deps/linux/include/timeconst.h"
  rm -f "$meson_deps/linux/include/asm-offsets.h"
  rm -rf "$meson_deps/linux/include/generated/uapi/linux"

  cp -R "$LINUX_BUILD/arch/ish/include/generated/asm" "$meson_deps/linux/arch/ish/include/generated/asm"
  cp -R "$LINUX_BUILD/arch/ish/include/generated/uapi/asm" "$meson_deps/linux/arch/ish/include/generated/uapi/asm"
  cp -R "$LINUX_SRC/arch/x86/include" "$meson_deps/linux/arch/x86/include"
  cp -R "$LINUX_SRC/arch/x86/include" "$meson_deps/arch/x86/include"
  cp "$LINUX_BUILD/include/generated/autoconf.h" "$meson_deps/linux/include/generated/autoconf.h"
  cp "$LINUX_BUILD/include/generated/utsrelease.h" "$meson_deps/linux/include/utsrelease.h"
  cp "$LINUX_BUILD/include/generated/bounds.h" "$meson_deps/linux/include/bounds.h"
  cp "$LINUX_BUILD/include/generated/timeconst.h" "$meson_deps/linux/include/timeconst.h"
  cp "$LINUX_BUILD/include/generated/asm-offsets.h" "$meson_deps/linux/include/asm-offsets.h"
  cp -R "$LINUX_BUILD/include/generated/uapi/linux" "$meson_deps/linux/include/generated/uapi/linux"
}

build_linux_user_archive() {
  local sdk="$1"
  local target="$2"
  local build_name="ReleaseLinux-$sdk"
  local meson_dir="$OUTPUT_DIR/$build_name/meson"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  echo "==> Building liblinux_user.a for $sdk..."
  (
    cd "$meson_dir"
    rm -rf liblinux_user.a.p liblinux_user.a
    mkdir -p liblinux_user.a.p
    xcrun --sdk "$sdk" clang \
      -target "$target" \
      -isysroot "$sysroot" \
      -Iliblinux_user.a.p \
      -I. \
      -I../../.. \
      -Ideps/linux/arch/ish/include \
      -I../../../deps/linux/arch/ish/include \
      -Ideps/linux/include \
      -I../../../deps/linux/include \
      -Ideps \
      -fdiagnostics-color=always \
      -Wall \
      -Wextra \
      -std=gnu11 \
      -O0 \
      -g \
      -Wimplicit-fallthrough \
      -Wtautological-constant-in-range-compare \
      -DLOG_HANDLER_NSLOG=1 \
      -DENGINE_ASBESTOS=1 \
      -Wno-switch \
      -include user.h \
      -include linux/kconfig.h \
      -c ../../../linux/emu_asbestos.c \
      -o liblinux_user.a.p/linux_emu_asbestos.c.o
    xcrun --sdk "$sdk" libtool -static -o liblinux_user.a liblinux_user.a.p/linux_emu_asbestos.c.o
  )
}

# Compile tools/fakefs.c (which provides fakefs_import/fakefs_import_directory)
# and merge it into libfakefs.a. The meson build only includes fs/fake-db.c,
# fs/fake-migrate.c, and fs/fake-rebuild.c in libfakefs.a, but the Cordova
# terminal plugin needs the import functions from tools/fakefs.c.
build_fakefs_import() {
  local sdk="$1"
  local target="$2"
  local build_name="ReleaseLinux-$sdk"
  local meson_dir="$OUTPUT_DIR/$build_name/meson"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  echo "==> Building tools/fakefs.c and merging into libfakefs.a for $sdk..."
  (
    cd "$meson_dir"
    # A previous build may already contain these two generated members. Remove
    # them first so repeated invocations remain linkable.
    while xcrun --sdk "$sdk" ar -t libfakefs.a | rg -q '^(tools_fakefs\.c\.o|util_fchdir\.c\.o)$'; do
      xcrun --sdk "$sdk" ar -d libfakefs.a tools_fakefs.c.o util_fchdir.c.o
    done
    mkdir -p libfakefs_import.a.p
    xcrun --sdk "$sdk" clang \
      -target "$target" \
      -isysroot "$sysroot" \
      -Ilibfakefs_import.a.p \
      -I. \
      -I../../.. \
      -I"$ISH_DIR/deps/libarchive/libarchive" \
      -fdiagnostics-color=always \
      -Wall \
      -Wextra \
      -std=gnu11 \
      -O0 \
      -g \
      -Wimplicit-fallthrough \
      -DLOG_HANDLER_NSLOG=1 \
      -Wno-switch \
      -c ../../../tools/fakefs.c \
      -o libfakefs_import.a.p/tools_fakefs.c.o
    xcrun --sdk "$sdk" clang \
      -target "$target" \
      -isysroot "$sysroot" \
      -I. \
      -I../../.. \
      -fdiagnostics-color=always \
      -Wall \
      -Wextra \
      -std=gnu11 \
      -O0 \
      -g \
      -DLOG_HANDLER_NSLOG=1 \
      -c ../../../util/fchdir.c \
      -o libfakefs_import.a.p/util_fchdir.c.o
    xcrun --sdk "$sdk" libtool -static -o libfakefs_import.a \
      libfakefs_import.a.p/tools_fakefs.c.o \
      libfakefs_import.a.p/util_fchdir.c.o
    xcrun --sdk "$sdk" libtool -static -o libfakefs-merged.a libfakefs.a libfakefs_import.a
    mv libfakefs-merged.a libfakefs.a
    rm -rf libfakefs_import.a libfakefs_import.a.p
  )
}

build_sdk() {
  local sdk="$1"
  local target="$2"
  local build_name="ReleaseLinux-$sdk"
  shift 2

  copy_kernel_headers "$build_name"

  echo "==> Building iSH archives for $sdk..."
  xcodebuild \
    -project "$ISH_DIR/deps/libarchive.xcodeproj" \
    -target libarchive \
    -configuration Release \
    -sdk "$sdk" \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 \
    HEADER_SEARCH_PATHS="$(brew --prefix xz)/include" \
    GCC_PREPROCESSOR_DEFINITIONS="HAVE_CONFIG_H HAVE_LZMA_H=1" \
    CONFIGURATION_BUILD_DIR="$OUTPUT_DIR/$build_name" \
    "$@" \
    build

  xcodebuild \
    -project "$ISH_DIR/iSH.xcodeproj" \
    -target libiSHLinux \
    -configuration ReleaseLinux \
    -sdk "$sdk" \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 \
    BUILD_DIR="$OUTPUT_DIR" \
    "$@" \
    build

  "$LLVM_OBJCOPY" --redefine-sym _main=_ish_kernel_main \
    "$OUTPUT_DIR/$build_name/liblinux.a" \
    "$OUTPUT_DIR/$build_name/liblinux-acode.a"

  build_linux_user_archive "$sdk" "$target"

  build_fakefs_import "$sdk" "$target"

  for lib in libarchive.a libiSHLinux.a liblinux-acode.a meson/liblinux_user.a meson/libish_emu.a meson/libfakefs.a; do
    local lib_path="$OUTPUT_DIR/$build_name/$lib"
    if [[ ! -f "$lib_path" ]]; then
      echo "ERROR: $lib_path not found after build"
      exit 1
    fi
  done
}

build_sdk iphoneos arm64-apple-ios15.0
build_sdk iphonesimulator arm64-apple-ios15.0-simulator ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64

echo "==> iSH builds succeeded:"
for sdk in iphoneos iphonesimulator; do
  for lib in libiSHLinux.a liblinux-acode.a; do
    lib_path="$OUTPUT_DIR/ReleaseLinux-$sdk/$lib"
    echo "    $lib_path ($(du -h "$lib_path" | cut -f1))"
  done
done
