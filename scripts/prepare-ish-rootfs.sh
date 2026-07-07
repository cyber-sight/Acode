#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="$ROOT_DIR/third_party/ish"
DEST="$ROOT_DIR/src/plugins/terminal/src/ios/ish-rootfs"
ARCHIVE="${1:-}"

if [[ -z "$ARCHIVE" ]]; then
  echo "Usage: $0 /path/to/alpine-rootfs.tar.gz"
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive not found: $ARCHIVE"
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"

if [[ ! -x "$ISH_DIR/build/Release/fakefsify" ]]; then
  echo "fakefsify not found at $ISH_DIR/build/Release/fakefsify"
  echo "Build the native iSH helper first:"
  echo "  cd $ISH_DIR && meson setup build/Release --buildtype=debugoptimized && meson compile -C build/Release fakefsify"
  exit 1
fi

"$ISH_DIR/build/Release/fakefsify" "$ARCHIVE" "$DEST"

echo "Rootfs imported to $DEST"
