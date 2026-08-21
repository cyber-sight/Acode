# Void Linux rootfs (glibc, aarch64)

This document describes the Void Linux–based guest rootfs for Acode's iOS
terminal and the opencode integration. It complements
[`ISH_INTEGRATION.md`](ISH_INTEGRATION.md) and [`ISH_RUNTIME.md`](ISH_RUNTIME.md),
which cover the runtime itself.

## Why Void

- Ships an official **aarch64 glibc** ROOTFS tarball (and musl variants).
- The opencode2 CLI ships GNU builds; a glibc base runs them natively.
- xbps + runit are familiar tooling; `/sbin/init` exists as the app expects.

## Building

```sh
# one-time: host iSH tools
meson setup third_party/ish-arm64/build-host-arm64 third_party/ish-arm64 -Dguest_arch=arm64
meson compile -C third_party/ish-arm64/build-host-arm64

scripts/prepare-void-glibc-rootfs.sh 0.0.0-beta-17823 [workdir]
```

Outputs (under `build/void-glibc/`):

- `void-rootfs/` — FakeFS image (`meta.db` + `data/`) for host CLI testing
- `void-glibc-oc2-<ver>.tar.gz` — same content as an Acode-importable archive

The builder is idempotent: downloads are cached in the workdir.

## What is baked in

| Component | Path | Purpose |
|---|---|---|
| opencode2 (GNU) | `/opt/oc/package/bin/opencode2` + wrapper on PATH | AI coding agent |
| busybox (static) | `/usr/local/bin/busybox` + ~30 applet wrappers | core tools without xbps |
| musl loader | `/usr/lib/ld-musl-aarch64.so.1` | run musl-linked binaries |
| musl libstdc++/libgcc | `/opt/musl-compat/` | C++ runtime for those binaries |
| DNS | `/etc/resolv.conf` | 1.1.1.1 / 8.8.8.8 |

Dual-libc isolation: musl-linked binaries resolve `libstdc++.so.6` from
`/opt/musl-compat` first via `/etc/ld-musl-aarch64.path`, so they never see
glibc's incompatible copies. Glibc binaries are unaffected.

## Kernel-level runtime workarounds (in third_party/ish-arm64)

Injected into every execve by `kernel/exec.c` (`mode=0`: user env wins):

| Variable | Why |
|---|---|
| `JSC_useJIT=false` | Bun/JSC deadlocks or corrupts state under emulation |
| `OPENSSL_armcap=0` | OpenSSL 3.x armcap probing executes SVE-region opcodes → SIGILL |

Plus existing injections: Node `--jitless` suite, `GODEBUG=asyncpreemptoff=1`,
`GOMAXPROCS=2`, `PYTHONMALLOC=malloc`, etc.

**Single guest CPU on iOS**: `platform/darwin.c` advertises 1 CPU — concurrent
guest threads trip futex wait/wake races that hang Bun/Go binaries in permanent
spins. Override with `ISH_GUEST_CPU_COUNT` if you accept the flakiness.

## Testing with the host CLI

```sh
ISH_BIN=third_party/ish-arm64/build-host-arm64/ish
R=build/void-glibc/void-rootfs
mkdir -p $R-data 2>/dev/null # n/a
"$ISH_BIN" -f "$R" /bin/sh -c 'mkdir -p /home/acode'
perl -e 'alarm 120; exec @ARGV' -- env ISH_GUEST_CPU_COUNT=1 \
  "$ISH_BIN" -f "$R" -d /home/acode /bin/sh -c '
    export HOME=/home/acode TERM=xterm PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    opencode --version   # v1 (if baked)
    opencode2 --version  # v2 canary (see status below)
  '
```

Rules learned the hard way:

- Never run two `ish` processes against the same FakeFS root (SQLite lock
  deadlock). One root per concurrent process.
- Guest-side `timeout(1)` is broken (`timer_create` unsupported) — use host-side
  watchdogs.
- Booting or sqlite3-ing a root dirties `meta.db` (+WAL sidecars); restore with
  `git checkout` before committing anything under
  `src/plugins/terminal/src/ios/ish-rootfs/`.

## Importing into the iOS app

1. Build the iOS archives with the patched submodule in place:
   `ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh`
2. AirDrop/copy `void-glibc-oc2-<ver>.tar.gz` to the device.
3. In Acode: Terminal → rootfs menu → **Import** → pick the tarball.
4. Activate it (validation checks meta.db integrity + ARM64 `/bin/sh`).
5. Init stays at `/sbin/init` (runit). First boot mounts procfs/devpts as usual.

## Status matrix (as of this document)

| Binary | Flavor | State under iSH-A64 |
|---|---|---|
| bun 1.3.14 / 1.4.0 stable | musl | ✅ full JS, fetch, crypto |
| OpenCode v1.18.x (`opencode`) | musl | ✅ boots, `--version`, `--help`; network commands OK at 1 CPU |
| OpenCode v2 beta (`opencode2`) | GNU | ❌ subprocess probe segfaults (Bun 1.4.0-canary) |
| OpenCode v2 beta (`opencode2`) | musl | ⚠️ boots to JS, dies in module-define recursion |

v2 uses a Bun *canary*. Re-test new betas periodically — when 2.0 ships on
stable Bun it should inherit the working baseline. The builder takes any npm
version so re-baking is one command.

## Known emulator gaps hit during this work

- `clone3` stubbed (glibc falls back), `futex_waitv` missing, io_uring/memfd/
  rseq silently stubbed, `process_vm_readv` stubbed (Bun crash dumper)
- epoll: repeated `EPOLL_CTL_ADD` of an already-registered fd returns EEXIST;
  some Bun-Linux code paths re-add without DEL (investigation ongoing,
  diagnostics left in `kernel/epoll.c`)
- vendored libarchive cannot import non-ASCII tar entry names (builder sanitizes)
