# iSH Integration Plan

Goal: provide an iSH-style x86 Alpine environment on iOS and bridge it to the existing Terminal/Executor JS API.

## Current status

- iSH is vendored in `third_party/ish`.
- `IshBridge` and `Executor` are wired to iSH headers when available.
- Output streaming is hooked by swizzling `Terminal sendOutput:length:` and forwarding to Cordova callbacks.
- Rootfs bootstrap copies `ish-rootfs` from app bundle to `Documents/ish-rootfs` if present.
- Rootfs path is provided via `DefaultRootPath()` (weak symbol in `IshRootfs.c`).
- Hooks copy `src/ios/ish-rootfs` into the iOS app bundle after prepare.
- iOS one-shot commands use an exit-status marker so `Executor.execute()` resolves with command output or rejects on a non-zero status, matching the Android-facing JS contract.
- Each shell process receives a stable `HOME=/home/acode`, a standard Alpine `PATH`, and an initialized `/workspace` directory.
- iSH process-group exits are reported through `LinuxSessionExitBlock`, allowing interactive terminal sessions to emit a final `exit:<code>` event and release their callback.
- The fakefs `meta.db` is authoritative. `IshBridge` reconciles host-copied files under `ish-rootfs/data` before each new session, so files added outside the guest become visible without rebuilding the rootfs.
- Developer rootfs images include `acode doctor`, which reports the installed baseline tools and the most recent iSH kernel diagnostics.
- iOS Terminal Settings includes **Root Filesystems**. It manages the bundled default root and named imported roots, accepts `.tar.gz`, `.tgz`, `.zip`, or a local rootfs folder, and applies a selected root after Acode relaunches.

## Key iSH entry points

- `third_party/ish/app/LinuxInterop.h`
  - `linux_start_session(...)`
  - `actuate_kernel(...)`
- `third_party/ish/app/LinuxPTY.c`
  - Output is written via `Terminal_sendOutput_length(...)`
- `third_party/ish/app/Terminal.m`
  - `sendOutput:length:` is called for PTY output
  - `sendInput:` sends keyboard input

## Integration steps

1) Kernel + rootfs bootstrap
   - Import or unpack Alpine rootfs into app sandbox.
   - Ensure `/bin/sh` exists in the iSH root.
   - Call `actuate_kernel("")` once (see `IshBridge startKernelIfNeeded`).

2) Start sessions
   - `IshBridge startWithCommand:` calls `linux_start_session` with `/bin/sh -lc <command>`.
   - Session id is the `Terminal` UUID.

3) I/O bridge
   - Output: `Terminal sendOutput:length:` is swizzled to call `IshBridge` event handler.
   - Input: `Terminal sendInput:` called from `IshBridge writeToSession:`.

4) Cordova glue
   - `Executor.start` returns session id and keeps callback for streaming.
   - `Executor.write` sends input to iSH.
   - `Executor.stop` destroys the terminal.
   - `Executor.execute` waits for the command's exit marker and returns stdout instead of returning a session id.

## Build notes

- iSH has its own Xcode project (`third_party/ish/iSH.xcodeproj`) and is linked into Cordova as static archives by the terminal plugin's iOS hook.
Scripts:
- `scripts/build-ish.sh` for building iSH (macOS + Xcode).
- `scripts/sync-ish-headers.sh` for syncing required headers.
- `scripts/prepare-ish-rootfs.sh` to import an i386 Alpine rootfs, install the tracked developer package manifest, and write it into `src/plugins/terminal/src/ios/ish-rootfs`. It stages the image before replacing the bundled rootfs. Pass `--sha256` in release builds to pin the archive; `libarchive` is required to build the host import utility.
- `scripts/build-ish.sh` builds iSH's vendored `libarchive.a` alongside the runtime archives because the on-device rootfs importer uses it for ZIP and TAR support.

## Next TODOs

- Map Acode project and app-storage directories into the guest under `/workspace` and `/mnt/acode`; the current `/workspace` is an isolated guest directory.
- Expand iSH compatibility based on observed diagnostics: futex operations, socket calls, clone flags, `/proc`, and unsupported syscalls.
