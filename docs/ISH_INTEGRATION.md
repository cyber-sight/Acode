# iSH Integration Plan

Goal: provide an iSH-style x86 Alpine environment on iOS and bridge it to the existing Terminal/Executor JS API.

## Current status

- iSH is vendored in `third_party/ish`.
- `IshBridge` and `Executor` are wired to iSH headers when available.
- Output streaming is hooked by swizzling `Terminal sendOutput:length:` and forwarding to Cordova callbacks.
- Rootfs bootstrap copies `ish-rootfs` from app bundle to `Documents/ish-rootfs` if present.
- Rootfs path is provided via `DefaultRootPath()` (weak symbol in `IshRootfs.c`).
- Hooks copy `src/ios/ish-rootfs` into the iOS app bundle after prepare.

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

## Build notes

- iSH has its own Xcode project (`third_party/ish/iSH.xcodeproj`).
- For Cordova, you’ll need to either:
  - Build iSH as a static library and link it into the Cordova iOS app, or
  - Add required iSH sources to the Cordova build (large change).
Scripts:
- `scripts/build-ish.sh` for building iSH (macOS + Xcode).
- `scripts/sync-ish-headers.sh` for syncing required headers.
- `scripts/prepare-ish-rootfs.sh` to extract an Alpine rootfs into `src/ios/ish-rootfs`.
Scripts:
- `scripts/build-ish.sh` for building iSH (macOS + Xcode).
- `scripts/sync-ish-headers.sh` for syncing required headers.

## Next TODOs

- Bundle Alpine rootfs under `ish-rootfs` and validate `/bin/sh`.
- Link iSH static lib into Cordova build (hooks added, requires `xcode` npm package).
- Add exit event callbacks when sessions terminate.
