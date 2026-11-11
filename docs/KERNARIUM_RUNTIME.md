# Kernarium terminal runtime (prototype)

Status: **prototype, not yet run on a device.** The guest agent and image
builder are tested on Linux; the native bridge is type-checked but has not
been built in Xcode or booted.

This is an opt-in alternative to the iSH runtime for the iOS terminal. Instead
of emulating Linux system calls, it runs a real Linux 6.18 kernel through a
[Kernarium](https://github.com/imxieyi/Kernarium) runtime framework embedded in
the app (User-mode Linux compiled for iOS, with guest userspace on Kernarium's
gadget engine). The terminal UI, `Executor.js` and the loopback WebSocket are
unchanged; only the native backend behind them differs.

## How it fits together

```text
xterm.js ── WebSocket ── IshWebSocketServer ── id<AcodeTerminalEndpoint>
                                                    │
               iSH: AcodeIshTerminal (PTY in iSH)   │   Kernarium: KernariumTerminal
                                                    │
                                     vsock stream (framed) to port 7000
                                                    │
                                Linux guest: acode-vsock-pty → forkpty → shell
```

- `src/ios/AcodeTerminalBackend.{h,m}`: the two protocols `Executor` and the
  WebSocket server now use, and the once-per-process backend choice.
- `src/ios/KernariumBridge.{h,m}`: loads `KRuntime_6_18_4K.framework` with
  `dlopen`, boots the guest on the `uml-launcher` thread at the first session,
  and opens one vsock connection per session with the runtime's
  `connect_vsock`. It also quiesces the guest when the app is backgrounded
  and resumes it on return.
- `kernarium/guest/acode-vsock-pty.c`: the guest agent. Its header defines
  the wire format (open, data, resize, kill, exit).
- `kernarium/build-guest-image.sh`: builds the guest image, an Alpine aarch64
  minirootfs with the agent started by BusyBox init. It runs on any Linux host
  and needs no root and no emulator.
- `hooks/ios/add-kernarium-runtime.js` and `kernarium-embed.sh`: the Xcode
  wiring. The hook only acts when it is given a Kernarium build.

## Build

1. Build and package Kernarium's iOS frameworks on a Mac
   (`Kernarium/scripts/package-ios-frameworks.sh`; see Kernarium's
   `docs/testing.md`). Acode needs `KRuntime_6_18_4K`, `MesaEGL`,
   `MesaGallium` and, for devices, `KosmicKrisp`.
2. Build the guest image (Linux, or macOS with clang, lld and e2fsprogs):

   ```sh
   src/plugins/terminal/kernarium/build-guest-image.sh
   ```

3. Prepare the iOS platform with the Kernarium inputs:

   ```sh
   KERNARIUM_DIR=/path/to/Kernarium \
   KERNARIUM_XCFRAMEWORKS=/path/to/Kernarium/.build/kernarium-xcframeworks \
   bunx cordova prepare ios
   ```

   This adds the runtime header path, an "Embed Kernarium runtime" build
   phase, and the `extended-virtual-addressing` and `increased-memory-limit`
   entitlements. The provisioning profile must allow both entitlements. The
   build phase also sets `AcodeTerminalRuntime=kernarium` in the built
   `Info.plist`.

Without those variables the hook does nothing, `KernariumBridge` compiles to a
stub and the terminal uses iSH as before.

## Settings

The user defaults are read at the first session:

- `AcodeTerminalRuntime`: `kernarium` or `ish`. It overrides the Info.plist
  value and takes effect at the next launch.
- `AcodeKernariumMemoryMiB`: guest RAM, 512–4096 in 64 MiB steps. Default 1024.
- `AcodeKernariumProcessors`: vCPUs. Default 2, at most the host's core count.

A file at `Documents/kernarium/rootfs.ext4` replaces the bundled image.

## Testing

`python3 src/plugins/terminal/kernarium/guest/test_agent.py` builds the agent
for the host and checks the protocol over loopback TCP: output and exit
status, resize, Ctrl-C, and hang-up when the host closes the stream.

On a device, the first terminal waits for the guest to boot, then expect:

```sh
uname -r      # a 6.18 kernel, not iSH
nproc         # the configured vCPUs
stty size     # follows the terminal size
apk add git   # networking over Kernarium's SLiRP
```

The guest's serial console is written to the device log as
`[Kernarium guest]` lines.

## Limits of this prototype

- **Nothing outside the image persists.** Kernarium mounts the image read-only
  under an overlay that its boot `/init` formats on every launch. A persistent
  home needs a Kernarium change: a boot mode that keeps the upper layer, or a
  second writable disk.
- One guest per app process. If it powers off or fails, the terminal is
  unavailable until the app is relaunched.
- The rootfs manager UI still manages iSH roots.
- The runtime needs a Metal view even for this headless guest; the bridge
  passes one that is never shown. This has not been confirmed on a device.
- The runtime and GPU frameworks are large, and guest RAM counts against the
  app's memory limit.
