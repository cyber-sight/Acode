#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="$ROOT_DIR/third_party/ish"
DEST="${ISH_ROOTFS_DEST:-$ROOT_DIR/src/plugins/terminal/src/ios/ish-rootfs}"
STAGING_DEST=""
PACKAGES_FILE="$ROOT_DIR/scripts/ish-rootfs-packages.txt"
ARCHIVE=""
EXPECTED_SHA256=""

usage() {
  echo "Usage: $0 /path/to/alpine-minirootfs-i386.tar.gz [--sha256 <digest>]"
  echo "Imports Alpine, installs the tracked developer package set, and writes the bundled iSH rootfs."
}

cleanup() {
  if [[ -n "$STAGING_DEST" ]]; then
    rm -rf "$STAGING_DEST"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha256)
      EXPECTED_SHA256="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$ARCHIVE" ]]; then
        echo "Only one Alpine archive may be provided." >&2
        usage >&2
        exit 1
      fi
      ARCHIVE="$1"
      shift
      ;;
  esac
done

if [[ -z "$ARCHIVE" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive not found: $ARCHIVE"
  exit 1
fi

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "Package manifest not found: $PACKAGES_FILE"
  exit 1
fi

build_fakefsify() {
  local archive_prefix
  archive_prefix=""
  if command -v brew >/dev/null 2>&1; then
    archive_prefix="$(brew --prefix libarchive 2>/dev/null || true)"
  fi
  if [[ -z "$archive_prefix" && -f /opt/homebrew/opt/libarchive/include/archive.h ]]; then
    archive_prefix="/opt/homebrew/opt/libarchive"
  fi
  if [[ -z "$archive_prefix" && -f /usr/local/opt/libarchive/include/archive.h ]]; then
    archive_prefix="/usr/local/opt/libarchive"
  fi
  if [[ -z "$archive_prefix" || ! -f "$archive_prefix/include/archive.h" ]]; then
    echo "fakefsify requires Homebrew libarchive. Install it with: brew install libarchive" >&2
    return 1
  fi

  mkdir -p "$ISH_DIR/build/Release"
  xcrun clang \
    -I"$ISH_DIR" \
    -I"$archive_prefix/include" \
    "$ISH_DIR/tools/fakefsify.c" \
    "$ISH_DIR/tools/fakefs.c" \
    "$ISH_DIR/tools/fakefsify-log.c" \
    "$ISH_DIR/util/fchdir.c" \
    "$ISH_DIR/fs/fake-db.c" \
    "$ISH_DIR/fs/fake-migrate.c" \
    "$ISH_DIR/fs/fake-rebuild.c" \
    -L"$archive_prefix/lib" \
    -lsqlite3 \
    -larchive \
    -o "$ISH_DIR/build/Release/fakefsify"
}

if [[ ! -x "$ISH_DIR/build/Release/fakefsify" ]]; then
  echo "Building fakefsify..."
  build_fakefsify
fi

if [[ ! -x "$ISH_DIR/build/Release/ish" ]]; then
  echo "iSH CLI not found at $ISH_DIR/build/Release/ish"
  echo "Build it before preparing the developer rootfs."
  exit 1
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ -n "$EXPECTED_SHA256" && "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Archive checksum mismatch."
  echo "Expected: $EXPECTED_SHA256"
  echo "Actual:   $ACTUAL_SHA256"
  exit 1
fi

PACKAGES=()
while IFS= read -r package; do
  [[ -z "$package" || "$package" == \#* ]] && continue
  PACKAGES+=("$package")
done < "$PACKAGES_FILE"
if [[ ${#PACKAGES[@]} -eq 0 ]]; then
  echo "Package manifest contains no packages: $PACKAGES_FILE"
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
STAGING_DEST="${DEST}.tmp.$$"
rm -rf "$STAGING_DEST"

"$ISH_DIR/build/Release/fakefsify" "$ARCHIVE" "$STAGING_DEST"

PACKAGE_ARGS="${PACKAGES[*]}"
GUEST_SETUP=$(cat <<EOF
set -eu
mkdir -p /etc
printf '%s\\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > /etc/resolv.conf
attempt=1
until apk update; do
  if [ "\$attempt" -ge 3 ]; then
    exit 1
  fi
  sleep "\$attempt"
  attempt=\$((attempt + 1))
done
attempt=1
until apk add --no-cache $PACKAGE_ARGS; do
  if [ "\$attempt" -ge 3 ]; then
    exit 1
  fi
  sleep "\$attempt"
  attempt=\$((attempt + 1))
done
mkdir -p /home/acode /workspace /mnt/acode /etc/profile.d
cat > /etc/profile.d/acode.sh <<'PROFILE'
export HOME=/home/acode
export USER=acode
export LOGNAME=acode
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROFILE
{
  printf '%s\n' '#!/bin/sh' ''
  printf '%s\n' 'case "\${1:-doctor}" in'
  printf '%s\n' '  doctor)'
  printf '%s\n' "    printf '%s\\n' 'Acode iSH environment'"
  printf '%s\n' '    for command in sh bash git node npm python3 pip3 curl; do'
  printf '%s\n' '      if command -v "\$command" >/dev/null 2>&1; then'
  printf '%s\n' "        printf '%s: %s\\n' \"\$command\" \"\$(command -v \"\$command\")\""
  printf '%s\n' '      else'
  printf '%s\n' "        printf '%s: missing\\n' \"\$command\""
  printf '%s\n' '      fi'
  printf '%s\n' '    done'
  printf '%s\n' "    printf '%s\\n' 'Recent kernel diagnostics:'"
  printf '%s\n' '    dmesg 2>/dev/null | tail -n 30'
  printf '%s\n' '    ;;'
  printf '%s\n' '  *)'
  printf '%s\n' "    printf '%s\\n' 'Usage: acode doctor' >&2"
  printf '%s\n' '    exit 64'
  printf '%s\n' '    ;;'
  printf '%s\n' 'esac'
} > /usr/local/bin/acode
chmod 755 /usr/local/bin/acode
printf '%s\\n' 'archive_sha256=$ACTUAL_SHA256' > /etc/acode-rootfs-release
printf '%s\\n' 'packages=$PACKAGE_ARGS' >> /etc/acode-rootfs-release
rm -rf /var/cache/apk/*
EOF
)

"$ISH_DIR/build/Release/ish" -f "$STAGING_DEST" /bin/sh -lc "$GUEST_SETUP"

for command in bash git node npm python3 pip3 curl; do
  "$ISH_DIR/build/Release/ish" -f "$STAGING_DEST" /bin/sh -lc "command -v $command >/dev/null"
done

rm -rf "$DEST"
mv "$STAGING_DEST" "$DEST"
STAGING_DEST=""

echo "Developer rootfs imported to $DEST"
echo "Archive SHA-256: $ACTUAL_SHA256"
