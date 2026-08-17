#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="${ISH_SOURCE_DIR:-$ROOT_DIR/third_party/ish-arm64}"
ISH_GUEST_ARCH="${ISH_GUEST_ARCH:-arm64}"
case "$ISH_GUEST_ARCH" in
  x86|arm64) ;;
  *) echo "ISH_GUEST_ARCH must be x86 or arm64 (got: $ISH_GUEST_ARCH)" >&2; exit 64 ;;
esac
HOST_BUILD_DIR="${ISH_HOST_BUILD_DIR:-$ISH_DIR/build-host-$ISH_GUEST_ARCH}"
ISH_CLI="$HOST_BUILD_DIR/ish"
FAKEFSIFY="$HOST_BUILD_DIR/tools/fakefsify"
DEST="${ISH_ROOTFS_DEST:-$ROOT_DIR/src/plugins/terminal/src/ios/ish-rootfs}"
STAGING_DEST=""
PACKAGES_FILE="$ROOT_DIR/scripts/ish-rootfs-packages.txt"
ARCHIVE=""
EXPECTED_SHA256=""

usage() {
  echo "Usage: $0 /path/to/alpine-minirootfs-ARCH.tar.gz [--sha256 <digest>]"
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

if [[ ! -x "$ISH_CLI" || ! -x "$FAKEFSIFY" ]]; then
  echo "Building $ISH_GUEST_ARCH guest host tools in $HOST_BUILD_DIR..."
  if [[ -f "$HOST_BUILD_DIR/meson-private/coredata.dat" ]]; then
    meson setup "$HOST_BUILD_DIR" --reconfigure "-Dguest_arch=$ISH_GUEST_ARCH"
  else
    meson setup "$HOST_BUILD_DIR" "$ISH_DIR" "-Dguest_arch=$ISH_GUEST_ARCH"
  fi
  meson compile -C "$HOST_BUILD_DIR" ./ish:executable tools/fakefsify
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

"$FAKEFSIFY" "$ARCHIVE" "$STAGING_DEST"

EXPECTED_UNAME="i686"
[[ "$ISH_GUEST_ARCH" == "arm64" ]] && EXPECTED_UNAME="aarch64"
ACTUAL_UNAME="$("$ISH_CLI" -f "$STAGING_DEST" /bin/sh -lc 'uname -m')"
if [[ "$ACTUAL_UNAME" != "$EXPECTED_UNAME" ]]; then
  echo "Guest architecture mismatch: expected $EXPECTED_UNAME, got $ACTUAL_UNAME" >&2
  exit 1
fi

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
export PATH=/home/acode/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

vite() {
	command vite --host 0.0.0.0 "\$@"
}
PROFILE
{
  printf '%s\n' '#!/bin/sh' ''
  printf '%s\n' 'case "\${1:-doctor}" in'
  printf '%s\n' '  doctor)'
  printf '%s\n' "    printf '%s\\n' 'Acode iSH environment'"
  printf '%s\n' '    for command in sh bash git node npm python3 pip3 curl; do'
  printf '%s\n' '      if command -v "\$command" >/dev/null 2>&1; then'
  printf '%s\n' "        printf '%s: %s\\n' \"\\\$command\" \"\\\$(command -v \"\\\$command\")\""
  printf '%s\n' '      else'
  printf '%s\n' "        printf '%s: missing\\n' \"\\\$command\""
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
	printf '%s\\n' 'guest_arch=$ISH_GUEST_ARCH' >> /etc/acode-rootfs-release
	printf '%s\\n' 'uname_machine=$EXPECTED_UNAME' >> /etc/acode-rootfs-release
	printf '%s\\n' 'archive_name=$(basename "$ARCHIVE")' >> /etc/acode-rootfs-release
	printf '%s\\n' 'packages=$PACKAGE_ARGS' >> /etc/acode-rootfs-release
rm -rf /var/cache/apk/*
EOF
)

"$ISH_CLI" -f "$STAGING_DEST" /bin/sh -lc "$GUEST_SETUP"

for command in bash git node npm python3 pip3 curl; do
  "$ISH_CLI" -f "$STAGING_DEST" /bin/sh -lc "command -v $command >/dev/null"
done

"$ISH_CLI" -f "$STAGING_DEST" /usr/local/bin/acode doctor
sqlite3 "$STAGING_DEST/meta.db" 'pragma wal_checkpoint(truncate);' >/dev/null
sqlite3 "$STAGING_DEST/meta.db" 'pragma integrity_check;' | rg -qx 'ok'
rm -f "$STAGING_DEST/meta.db-shm" "$STAGING_DEST/meta.db-wal"

rm -rf "$DEST"
mv "$STAGING_DEST" "$DEST"
STAGING_DEST=""

echo "Developer rootfs imported to $DEST"
echo "Archive SHA-256: $ACTUAL_SHA256"
