#!/usr/bin/env bash
# Build a Void Linux (aarch64 GLIBC) iSH rootfs with opencode2 baked in.
#
# Usage:
#   scripts/prepare-void-glibc-rootfs.sh <opencode2-version> [workdir]
#   e.g. scripts/prepare-void-glibc-rootfs.sh 0.0.0-beta-17823
#
# Output:
#   $WORK/void-rootfs/                 FakeFS image (meta.db + data/) for host CLI testing
#   $WORK/void-glibc-oc2-<ver>.tar.gz  same content as an Acode-importable archive
#
# Requirements: curl, python3, meson build of third_party/ish-arm64 (host tools),
#               perl (alarm-based watchdogs), macOS or Linux host.
set -euo pipefail

VER="${1:?usage: $0 <opencode2-version>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="$ROOT_DIR/third_party/ish-arm64"
FAKEFSIFY="$ISH_DIR/build-host-arm64/tools/fakefsify"
ISH_BIN="$ISH_DIR/build-host-arm64/ish"
WORK="${2:-$ROOT_DIR/build/void-glibc}"
mkdir -p "$WORK"
cd "$WORK"

[[ -x "$FAKEFSIFY" && -x "$ISH_BIN" ]] || {
  echo "host iSH tools missing; run:" >&2
  echo "  meson setup third_party/ish-arm64/build-host-arm64 third_party/ish-arm64 -Dguest_arch=arm64" >&2
  echo "  meson compile -C third_party/ish-arm64/build-host-arm64" >&2
  exit 1
}

VOID_SHA256="01a30f17ae06d4d5b322cd579ca971bc479e02cc284ec1e5a4255bea6bac3ce6"
VOID_URL="https://repo-default.voidlinux.org/live/current/void-aarch64-ROOTFS-20250202.tar.xz"

if [[ ! -f void-glibc-base.tar.gz ]]; then
  echo "== fetching Void aarch64 GLIBC ROOTFS =="
  curl -fL --retry 3 --max-time 900 -o void-glibc-ROOTFS.tar.xz "$VOID_URL"
  echo "$VOID_SHA256  void-glibc-ROOTFS.tar.xz" | shasum -a 256 -c -
  echo "== sanitizing (drop non-ASCII names/linknames; vendored libarchive limitation) =="
  python3 - <<'EOF'
import tarfile
def ok(m):
    return m.name.isascii() and (not m.linkname or m.linkname.isascii())
dropped = 0
with tarfile.open("void-glibc-ROOTFS.tar.xz", "r:xz") as fin, \
     tarfile.open("void-glibc-base.tar.gz", "w:gz") as fout:
    for m in fin:
        if not ok(m):
            dropped += 1
            continue
        m.pax_headers = {}
        if m.isreg():
            fout.addfile(m, fin.extractfile(m))
        else:
            fout.addfile(m)
print(f"dropped {dropped} entries")
EOF
fi

echo "== fetching opencode2 GNU artifact ($VER) =="
[[ -f "oc-gnu-$VER.tgz" ]] || curl -fL --max-time 900 -o "oc-gnu-$VER.tgz" \
  "https://registry.npmjs.org/@opencode-ai/cli-linux-arm64/-/cli-linux-arm64-$VER.tgz"
EXPECTED=$(curl -fsSL "https://registry.npmjs.org/@opencode-ai/cli-linux-arm64/$VER" |
           python3 -c 'import json,sys; print(json.load(sys.stdin)["dist"]["integrity"])')
ACTUAL="sha512-$(shasum -a 512 "oc-gnu-$VER.tgz" | awk '{print $1}' | xxd -r -p | base64)"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "opencode2 integrity mismatch"; exit 1; }

if [[ ! -f busybox.bin ]]; then
  echo "== fetching static busybox (Alpine busybox-static) =="
  curl -fL --max-time 300 -o busybox-static.apk \
    "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/busybox-static-1.37.0-r14.apk"
  python3 - <<'EOF'
import io, tarfile
data = open("busybox-static.apk", "rb").read()
# .apk concatenates several gzip'd tar streams; find the one with busybox.static
for off in range(len(data)):
    if data[off:off+3] == b"\x1f\x8b\x08":
        try:
            t = tarfile.open(fileobj=io.BytesIO(data[off:]), mode="r:gz")
        except Exception:
            continue
        for m in t.getmembers():
            if m.name.endswith("busybox.static"):
                open("busybox.bin", "wb").write(t.extractfile(m).read())
                print("extracted", m.name)
                raise SystemExit(0)
        break
raise SystemExit("busybox.static not found in apk")
EOF
fi

if [[ ! -f ld-musl-aarch64.so.1 ]]; then
  echo "== fetching musl loader (Alpine musl) for musl-binary compat =="
  MUSL_APK=$(curl -s --max-time 30 "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/" |
             grep -oE 'href="musl-[0-9][^"]*\.apk"' | grep -v static | head -1 | cut -d'"' -f2)
  [[ -n "$MUSL_APK" ]] || { echo "cannot find musl apk"; exit 1; }
  curl -fL --max-time 300 -o musl.apk "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/$MUSL_APK"
  python3 - <<'EOF'
import io, tarfile
data = open("musl.apk", "rb").read()
for off in range(len(data)):
    if data[off:off+3] == b"\x1f\x8b\x08":
        try:
            t = tarfile.open(fileobj=io.BytesIO(data[off:]), mode="r:gz")
        except Exception:
            continue
        for m in t.getmembers():
            if m.name.endswith("lib/ld-musl-aarch64.so.1"):
                open("ld-musl-aarch64.so.1", "wb").write(t.extractfile(m).read())
                print("extracted", m.name)
                raise SystemExit(0)
raise SystemExit("loader not found in apk")
EOF
fi

# musl-flavored C++ runtime: some musl builds (e.g. opencode2) still need
# libstdc++/libgcc_s; they must be the MUSL versions, kept separate from the
# glibc ones in /usr/lib. The musl loader searches /etc/ld-musl-aarch64.path,
# which lists /opt/musl-compat FIRST so it never picks up glibc copies.
for PKG in libgcc libstdc++; do
  if [[ ! -f "musl-$PKG.so" ]]; then
    echo "== fetching Alpine $PKG (musl) =="
    PKG_ENC=${PKG//+/%2B}
    APK=$(curl -s --max-time 30 "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/" |
          grep -oE "href=\"$PKG_ENC-[0-9][^\"]*\.apk\"" | grep -v -- -dev | tail -1 | cut -d'"' -f2)
    [[ -n "$APK" ]] || { echo "cannot find $PKG apk"; exit 1; }
    curl -fL --max-time 300 -o "$PKG.apk" \
      "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/$APK"
    python3 - "$PKG" <<'EOF'
import io, sys, tarfile
pkg = sys.argv[1]
data = open(f"{pkg}.apk", "rb").read()
if pkg == "libgcc":
    want = lambda n: n.endswith("lib/libgcc_s.so.1")     # real file
else:
    # libstdc++.so.6 is a symlink; take the real versioned file
    import re
    want = lambda n: re.search(r"libstdc\+\+\.so\.6(\.\d+)+$", n) is not None
for off in range(len(data)):
    if data[off:off+3] == b"\x1f\x8b\x08":
        try:
            t = tarfile.open(fileobj=io.BytesIO(data[off:]), mode="r:gz")
        except Exception:
            continue
        hit = False
        for m in t.getmembers():
            if m.isreg() and want(m.name):
                out = f"musl-{pkg}.so"
                open(out, "wb").write(t.extractfile(m).read())
                print("extracted", m.name, "->", out)
                hit = True
        if hit:
            raise SystemExit(0)
raise SystemExit(f"{pkg} libs not found in apk")
EOF
  fi
done

echo "== baking image =="
python3 - "$VER" <<'EOF'
import sys, io, tarfile
ver = sys.argv[1]

base = tarfile.open("void-glibc-base.tar.gz", "r:gz")
src  = tarfile.open("oc-gnu-%s.tgz" % ver, "r:gz")
out  = tarfile.open("void-glibc-oc2-%s.tar.gz" % ver, "w:gz")

def cp(m, fin):
    m.pax_headers = {}
    if m.isreg():
        out.addfile(m, fin.extractfile(m))
    else:
        out.addfile(m)

for m in base:
    cp(m, base)

for m in src:                       # opencode2 payload -> /opt/oc/package/**
    m.name = "./opt/oc/" + m.name.lstrip("./")
    cp(m, src)

def add(name, data, mode):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    out.addfile(ti, io.BytesIO(data))

# NOTE: JSC_useJIT=false and OPENSSL_armcap=0 are injected by the iSH kernel
# itself on every execve (third_party/ish-arm64 kernel/exec.c inject_envs), so
# no wrapper is required. The wrapper below only adds convenience.
add("./usr/local/bin/opencode2",
    b'#!/bin/sh\nexec /opt/oc/package/bin/opencode2 "$@"\n', 0o755)
add("./etc/profile.d/opencode2.sh",
    b'export PATH="/opt/oc/package/bin:$PATH"\n', 0o644)
add("./etc/resolv.conf", b"nameserver 1.1.1.1\nnameserver 8.8.8.8\n", 0o644)

bb = open("busybox.bin", "rb").read()
add("./usr/local/bin/busybox", bb, 0o755)

# musl compat loader: lets dynamically-musl-linked binaries (e.g. opencode2
# musl builds) run on this glibc base. The loader IS musl's libc.
# NOTE: must live under /usr/lib (a real directory) — Void's /lib is a
# symlink (merged-/usr), and fakefs cannot write *through* symlinked dirs at
# import time. Guest path resolution /lib/ld-musl-aarch64.so.1 still works.
ld = open("ld-musl-aarch64.so.1", "rb").read()
add("./usr/lib/ld-musl-aarch64.so.1", ld, 0o755)
ti = tarfile.TarInfo("./usr/lib/libc.musl-aarch64.so.1")
ti.type = tarfile.SYMTYPE
ti.linkname = "ld-musl-aarch64.so.1"
ti.mode = 0o777
out.addfile(ti)

# musl C++ runtime, isolated from glibc's copies: some musl builds (opencode2)
# need libstdc++/libgcc_s but MUST get the musl versions. The loader searches
# /etc/ld-musl-aarch64.path with /opt/musl-compat first.
add("./opt/musl-compat/libstdc++.so.6", open("musl-libstdc++.so", "rb").read(), 0o755)
add("./opt/musl-compat/libgcc_s.so.1",  open("musl-libgcc.so", "rb").read(),     0o755)
ti = tarfile.TarInfo("./etc/ld-musl-aarch64.path")
add("./etc/ld-musl-aarch64.path",
    b"/opt/musl-compat:/usr/local/lib:/usr/lib\n", 0o644)
APPLETS = ["ls", "cp", "mv", "rm", "mkdir", "rmdir", "cat",
           "grep", "sed", "awk", "find", "tar", "gzip", "gunzip", "zcat",
           "wget", "vi", "less", "ps", "kill", "chmod", "chown",
           "ln", "touch", "head", "tail", "wc", "sort", "uniq", "date"]
for a in APPLETS:
    add("./usr/local/bin/" + a,
        b'#!/bin/sh\nexec /usr/local/bin/busybox ' + a.encode() + b' "$@"\n', 0o755)

out.close(); src.close(); base.close()
print("packed void-glibc-oc2-%s.tar.gz" % ver)
EOF

echo "== converting to FakeFS =="
rm -rf void-rootfs
"$FAKEFSIFY" "void-glibc-oc2-$VER.tar.gz" void-rootfs

echo "== smoke test =="
perl -e 'alarm 90; exec @ARGV' -- env ISH_GUEST_CPU_COUNT=2 "$ISH_BIN" -f "$PWD/void-rootfs" /bin/sh -c '
set -e
test -x /bin/sh
test -x /opt/oc/package/bin/opencode2
test -x /usr/local/bin/opencode2
/usr/local/bin/busybox echo busybox-ok
uname -m
/bin/sh -c "env" | grep -E "^JSC_useJIT=|^OPENSSL_armcap="
'
echo "OK: $WORK/void-rootfs"
