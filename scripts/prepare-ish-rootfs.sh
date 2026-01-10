#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/src/ios/ish-rootfs"
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
mkdir -p "$DEST"

tar -xzf "$ARCHIVE" -C "$DEST"

echo "Rootfs extracted to $DEST"
