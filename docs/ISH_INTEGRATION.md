# iSH arm64 integration

## Architecture and source layout

Acode's iOS terminal runs an Alpine **aarch64 guest** through the OpenMinis iSH arm64 userspace emulator. The iOS host is arm64 too, but host and guest architecture are separate build inputs; every supported build path explicitly selects the guest with `ISH_GUEST_ARCH=arm64`.

Two iSH checkouts intentionally coexist:

- `third_party/ish` is the preserved x86 implementation and porting/rollback reference. Do not reset, clean, repoint, or build over its working tree as part of arm64 work.
- `third_party/ish-arm64` is the registered arm64 submodule used by default by the build, header-sync, rootfs, and Cordova integration scripts.

The arm64 port is based on OpenMinis commit `8932511fa0ab6abf77d5ead19503476d8b816f4f`. The current Acode port tip is `5483be0` on `acode-arm64`. Its pinned nested dependencies are:

- `deps/libapps`: `b8cacae35e5b11d64bb736a053921c16ca7faf9e`
- `deps/libarchive`: `fc6563f5130d8a7ee1fc27c0e55baef35119f26c`
- `deps/linux`: `8ec9bf17f89c6dba818f3ed2427de4223e78644a`

## Runtime bridge

The Cordova terminal plugin owns the Acode/iSH bridge:

- `IshBridge` starts the kernel and sessions, routes input and resize events, selects the rootfs, reconciles fakefs files, and reports process-group exit status.
- `IshTerminalBridge` implements the platform callbacks required by the iSH runtime.
- `Executor.start` returns a session UUID and retains its Cordova callback for streamed events.
- `Executor.write`, `Executor.resize`, and `Executor.stop` operate on that session.
- `Executor.execute` uses an exit-status marker and resolves with command output or rejects on nonzero status.
- `IshRootfs` and `RootfsManager` provide the bundled/default root and imported-root lifecycle.

The port preserves Acode's session-exit callback (`LinuxSessionExitBlock` and `linux_set_session_exit_handler()`), fakefs symlink storage, host-file reconciliation, `/tmp` bootstrap, root initialization, and interoperability helpers. Architecture-sensitive syscall and futex changes were reconciled with the fork's separate x86 and arm64 syscall tables rather than copied wholesale.

## Build and rootfs tools

The scripts default to `third_party/ish-arm64` and an arm64 guest. Both can be selected explicitly for diagnostic or rollback builds:

```bash
ISH_SOURCE_DIR="$PWD/third_party/ish-arm64" ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh
ISH_SOURCE_DIR="$PWD/third_party/ish-arm64" ISH_GUEST_ARCH=arm64 ./scripts/sync-ish-headers.sh
ISH_SOURCE_DIR="$PWD/third_party/ish-arm64" ISH_GUEST_ARCH=arm64 ./scripts/prepare-ish-rootfs.sh <alpine-aarch64-minirootfs.tar.gz> --sha256 <digest>
```

`build-ish.sh` produces separate device and simulator artifacts in architecture-qualified directories:

- `third_party/ish-arm64/build/ReleaseLinux-arm64-iphoneos`
- `third_party/ish-arm64/build/ReleaseLinux-arm64-iphonesimulator`

The terminal plugin hook links the archives from the selected source and guest architecture. After changing a plugin hook, refresh the installed Cordova plugin and run `bunx cordova prepare ios`; the generated `plugins/` copy is not the source of truth.

`prepare-ish-rootfs.sh` builds matching arm64-guest host tools, imports a pinned Alpine aarch64 minirootfs, checks `uname -m` for `aarch64`, installs `scripts/ish-rootfs-packages.txt`, runs `acode doctor`, verifies SQLite integrity, and records the archive/architecture metadata in `/etc/acode-rootfs-release` before replacing the bundled root.

## Verification status

Completed locally:

- The clean OpenMinis arm64 baseline configures and builds.
- The patched arm64 Meson build and the arm64-guest host `ish` and `fakefsify` targets compile.
- Device and simulator archive sets build; the six primary archives are arm64 and export the required Acode bridge symbols.
- Shell-script syntax checks and Cordova iOS prepare complete.
- The iOS device archive/export completes.

Still requires physical-device/runtime verification:

- Confirm `uname -m` returns `aarch64` and Node.js reports `process.arch === 'arm64'` in the bundled rootfs.
- Exercise start, streaming I/O, resize, success/nonzero/signal exit, explicit stop, and concurrent sessions.
- Exercise rootfs import, rejection, activation/relaunch, listing, rename, deletion, default-root protection, and reconciliation.
- Verify DNS/package-manager access and characterize shell, Node.js, Python, and filesystem performance.

The upstream Meson end-to-end test is not currently a reliable automated gate in an alternate build directory: its script hardcodes `./build/ish` and downloads an x86 Alpine rootfs. Record this limitation when reporting test results; do not report the test as passed without correcting or replacing those assumptions.

## Rollback

Set `ISH_SOURCE_DIR` to `third_party/ish`, select `ISH_GUEST_ARCH=x86`, rebuild the x86 artifacts and rootfs, then refresh the Cordova project. The preserved x86 checkout is the rollback source of truth and must remain untouched by arm64 cleanup.
