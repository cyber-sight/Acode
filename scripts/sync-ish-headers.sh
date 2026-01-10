#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="$ROOT_DIR/third_party/ish"
DEST_DIR="$ROOT_DIR/src/plugins/terminal/src/ios/ish/include"

mkdir -p "$DEST_DIR"

cp "$ISH_DIR/app/LinuxInterop.h" "$DEST_DIR/"
cp "$ISH_DIR/app/Terminal.h" "$DEST_DIR/"

