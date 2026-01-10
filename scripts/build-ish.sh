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
OUTPUT_DIR="$ROOT_DIR/third_party/ish/build"

if [[ ! -d "$ISH_DIR" ]]; then
  echo "iSH source not found at $ISH_DIR"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# NOTE: You need to identify the correct scheme/target from iSH.xcodeproj.
# Run: xcodebuild -list -project third_party/ish/iSH.xcodeproj
# Then update SCHEME below.
SCHEME="iSHLinux"

xcodebuild \
  -project "$ISH_DIR/iSH.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  BUILD_DIR="$OUTPUT_DIR" \
  build

echo "Build complete. Locate lib outputs under $OUTPUT_DIR"
