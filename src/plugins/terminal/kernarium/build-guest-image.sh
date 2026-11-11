#!/usr/bin/env bash
# Builds the Kernarium guest image for Acode's iOS terminal prototype.
#
# Output: a read-only ext4 filesystem image (not a partitioned disk) holding an
# Alpine aarch64 minirootfs plus the acode-vsock-pty agent, started by BusyBox
# init. Kernarium mounts it read-only beneath a throwaway overlay and boots its
# /sbin/init.
#
# Runs on any Linux host without root or emulation: the agent is
# cross-compiled with clang against Alpine's musl, and mke2fs -d populates the
# image directly.
#
# usage: build-guest-image.sh [--output FILE] [--size-mib N] [--work DIR]
#
# Requires: curl, tar, clang, ld.lld, mke2fs (e2fsprogs 1.43 or newer), and
# root or fakeroot.
set -euo pipefail

ALPINE_BRANCH=v3.24
ALPINE_VERSION=3.24.4
MINIROOTFS=alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz
MINIROOTFS_SHA256=4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de
MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
AGENT_PORT=7000

here=$(cd "$(dirname "$0")" && pwd)
output=$here/build/acode-kernarium-rootfs.ext4
work=$here/build/work
size_mib=256

while [ $# -gt 0 ]; do
	case $1 in
	--output) output=$2; shift 2 ;;
	--size-mib) size_mib=$2; shift 2 ;;
	--work) work=$2; shift 2 ;;
	-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

case $output in
*.ext4) ;;
*) echo "the output must end in .ext4; Kernarium selects the filesystem by extension" >&2; exit 2 ;;
esac

# mke2fs -d records each file's owner as it is on disk, so the root must be
# unpacked by uid 0 for the guest's files to belong to root.
if [ "$(id -u)" != 0 ]; then
	command -v fakeroot >/dev/null || { echo "run as root or install fakeroot" >&2; exit 1; }
	exec fakeroot -- "$0" "$@"
fi

for tool in curl tar clang ld.lld mke2fs; do
	command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$work/downloads"
downloads=$work/downloads

fetch() {
	local url=$1 file=$2
	[ -s "$file" ] && return 0
	curl -fsSL --retry 3 -o "$file.part" "$url"
	mv "$file.part" "$file"
}

# 1. The pinned minirootfs.
fetch "$MIRROR/$ALPINE_BRANCH/releases/aarch64/$MINIROOTFS" "$downloads/$MINIROOTFS"
echo "$MINIROOTFS_SHA256  $downloads/$MINIROOTFS" | sha256sum -c --quiet -

# 2. A musl sysroot for the cross-compile. Only libc.a, libgcc.a and headers
#    are taken from it, statically into the agent; the index resolves the
#    current build of each package.
fetch "$MIRROR/$ALPINE_BRANCH/main/aarch64/APKINDEX.tar.gz" "$downloads/APKINDEX.tar.gz"
tar -xzf "$downloads/APKINDEX.tar.gz" -C "$downloads" APKINDEX
package_version() {
	awk -v want="P:$1" '$0 == want { found = 1; next } found && /^V:/ { print substr($0, 3); exit }' "$downloads/APKINDEX"
}
sysroot=$work/sysroot
rm -rf "$sysroot"
mkdir -p "$sysroot"
for package in musl musl-dev linux-headers libgcc-static; do
	version=$(package_version "$package")
	[ -n "$version" ] || { echo "cannot resolve $package in the index" >&2; exit 1; }
	file=$downloads/$package-$version.apk
	fetch "$MIRROR/$ALPINE_BRANCH/main/aarch64/$package-$version.apk" "$file"
	tar -xzf "$file" -C "$sysroot" --exclude='.*' 2>/dev/null
done

# 3. The agent, static so it does not depend on the image's libraries. libgcc
#    supplies the long double helpers musl's printf needs on aarch64.
libgcc=$(find "$sysroot/usr/lib/gcc" -name libgcc.a | head -n 1)
[ -n "$libgcc" ] || { echo "libgcc.a missing from libgcc-static" >&2; exit 1; }
agent=$work/acode-vsock-pty
clang --target=aarch64-linux-musl --sysroot="$sysroot" -fuse-ld=lld \
	-static -nostdlib -s -O2 -std=c11 -Wall -Wextra -Werror \
	-isystem "$sysroot/usr/include" \
	"$sysroot/usr/lib/crt1.o" "$sysroot/usr/lib/crti.o" \
	"$here/guest/acode-vsock-pty.c" \
	-L"$sysroot/usr/lib" -lc "$libgcc" \
	"$sysroot/usr/lib/crtn.o" \
	-o "$agent"

# 4. The root.
root=$work/root
rm -rf "$root"
mkdir -p "$root"
tar -xzf "$downloads/$MINIROOTFS" -C "$root" 2>/dev/null
install -D -m 0755 "$agent" "$root/usr/local/sbin/acode-vsock-pty"

cat > "$root/etc/inittab" <<EOF
::sysinit:/etc/acode/boot
::respawn:/usr/local/sbin/acode-vsock-pty -p $AGENT_PORT
ttyS0::respawn:/sbin/getty -n -l /etc/acode/autologin 115200 ttyS0 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/sync
::shutdown:/bin/umount -a -r
EOF

mkdir -p "$root/etc/acode"
cat > "$root/etc/acode/boot" <<'EOF'
#!/bin/sh
# One-time guest setup at boot; the root is a fresh overlay every launch.
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm /run /tmp
mountpoint -q /dev/pts || mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs -o mode=1777 tmpfs /dev/shm
mountpoint -q /run || mount -t tmpfs -o mode=0755 tmpfs /run
chmod 1777 /tmp
hostname -F /etc/hostname
ip link set lo up
# Kernarium's SLiRP network serves DHCP on eth0.
ip link set eth0 up 2>/dev/null && udhcpc -i eth0 -b -q -s /usr/share/udhcpc/default.script >/dev/null 2>&1
mkdir -p /root/workspace
EOF
chmod 0755 "$root/etc/acode/boot"

cat > "$root/etc/acode/autologin" <<'EOF'
#!/bin/sh
exec /bin/login -f root
EOF
chmod 0755 "$root/etc/acode/autologin"

echo acode > "$root/etc/hostname"
cat > "$root/etc/resolv.conf" <<'EOF'
nameserver 10.0.2.3
EOF
grep -qx ttyS0 "$root/etc/securetty" 2>/dev/null || echo ttyS0 >> "$root/etc/securetty"
# Passwordless root: the guest is reachable only from Acode's own process.
sed -i 's/^root:[^:]*:/root::/' "$root/etc/shadow"

cat > "$root/etc/profile.d/acode.sh" <<'EOF'
export PS1='\w \$ '
[ -d /root/workspace ] && [ "$PWD" = "$HOME" ] && cd /root/workspace
EOF

# 5. The image. Kernarium refuses a writable .ext4 root, so it ships 0444.
mkdir -p "$(dirname "$output")"
rm -f "$output"
mke2fs -q -t ext4 -L acode -E root_owner=0:0 -d "$root" "$output" "${size_mib}M"
chmod 0444 "$output"
echo "built $output ($(du -h --apparent-size "$output" | cut -f1) apparent, agent on vsock port $AGENT_PORT)"
