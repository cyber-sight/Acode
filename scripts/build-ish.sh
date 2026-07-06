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
MESON_DEPS="$OUTPUT_DIR/Release-iphoneos/meson/deps"
AUTOCONF_SOURCE="$LINUX_BUILD/include/config/auto.conf"
AUTOCONF_HEADER="$LINUX_BUILD/include/generated/autoconf.h"

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

echo "==> Copying kernel headers for Xcode include paths..."
mkdir -p "$MESON_DEPS/linux/arch/ish/include/generated"
mkdir -p "$MESON_DEPS/linux/arch/ish/include/generated/uapi"
mkdir -p "$MESON_DEPS/linux/arch/x86"
mkdir -p "$OUTPUT_DIR/Release-iphoneos/meson/deps/arch/x86"
mkdir -p "$MESON_DEPS/linux/include"
mkdir -p "$MESON_DEPS/linux/include/generated"
mkdir -p "$MESON_DEPS/linux/include/generated/uapi"

rm -rf "$MESON_DEPS/linux/arch/ish/include/generated/asm"
rm -rf "$MESON_DEPS/linux/arch/ish/include/generated/uapi/asm"
rm -rf "$MESON_DEPS/linux/arch/x86/include"
rm -rf "$OUTPUT_DIR/Release-iphoneos/meson/deps/arch/x86/include"
rm -f "$MESON_DEPS/linux/include/generated/autoconf.h"
rm -f "$MESON_DEPS/linux/include/utsrelease.h"
rm -f "$MESON_DEPS/linux/include/bounds.h"
rm -f "$MESON_DEPS/linux/include/timeconst.h"
rm -f "$MESON_DEPS/linux/include/asm-offsets.h"
rm -rf "$MESON_DEPS/linux/include/generated/uapi/linux"

cp -R "$LINUX_BUILD/arch/ish/include/generated/asm" "$MESON_DEPS/linux/arch/ish/include/generated/asm"
cp -R "$LINUX_BUILD/arch/ish/include/generated/uapi/asm" "$MESON_DEPS/linux/arch/ish/include/generated/uapi/asm"
cp -R "$LINUX_SRC/arch/x86/include" "$MESON_DEPS/linux/arch/x86/include"
cp -R "$LINUX_SRC/arch/x86/include" "$OUTPUT_DIR/Release-iphoneos/meson/deps/arch/x86/include"
cp "$LINUX_BUILD/include/generated/autoconf.h" "$MESON_DEPS/linux/include/generated/autoconf.h"
cp "$LINUX_BUILD/include/generated/utsrelease.h" "$MESON_DEPS/linux/include/utsrelease.h"
cp "$LINUX_BUILD/include/generated/bounds.h" "$MESON_DEPS/linux/include/bounds.h"
cp "$LINUX_BUILD/include/generated/timeconst.h" "$MESON_DEPS/linux/include/timeconst.h"
cp "$LINUX_BUILD/include/generated/asm-offsets.h" "$MESON_DEPS/linux/include/asm-offsets.h"
cp -R "$LINUX_BUILD/include/generated/uapi/linux" "$MESON_DEPS/linux/include/generated/uapi/linux"

echo "==> Building libiSHLinux..."
xcodebuild \
  -project "$ISH_DIR/iSH.xcodeproj" \
  -target libiSHLinux \
  -configuration Release \
  -sdk iphoneos \
  IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  BUILD_DIR="$OUTPUT_DIR" \
  build

LIB_PATH="$OUTPUT_DIR/Release-iphoneos/libiSHLinux.a"
if [[ -f "$LIB_PATH" ]]; then
  echo "==> Build succeeded: $LIB_PATH"
  echo "    Size: $(du -h "$LIB_PATH" | cut -f1)"
else
  echo "ERROR: libiSHLinux.a not found after build"
  exit 1
fi
