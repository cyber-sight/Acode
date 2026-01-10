#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-third_party/ish}"

if [ -e "$DEST" ]; then
  echo "Destination already exists: $DEST"
  exit 1
fi

git clone https://github.com/ish-app/ish "$DEST"
