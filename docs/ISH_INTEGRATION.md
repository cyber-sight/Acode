# iSH ARM64 integration

## Supported architecture

Acode's iOS terminal uses OpenMinis iSH with its userspace kernel:

- Meson `kernel=ish`
- Meson `guest_arch=arm64`
- ARM64 iOS host targets for device and simulator
- Alpine aarch64 guest rootfs

This is not the fork's experimental `ReleaseLinux` configuration. That path embeds a modified Linux 5.16 kernel and is incomplete for an ARM64 guest ABI, including signal-frame and `rt_sigreturn` behavior. It is not linked into Acode.

Two source trees intentionally remain:

- `third_party/ish` is the untouched x86 reference checkout.
- `third_party/ish-arm64` is the registered OpenMinis checkout used by the supported build.

The active fork branch is `acode-arm64` at `5483be0`. The abandoned experiment is preserved locally as `archive/acode-release-linux-arm64` at `4946324`; its nested Linux work is preserved at `cc0802716`. No Git bundle is required.

## Runtime flow

`IshBridge` owns a serialized native control queue and boots the kernel once:

1. Validate the selected `meta.db` + `data/` fakefs, its SQLite integrity, `/bin/sh`, and ARM64 ELF machine.
2. Mount `data/` with `fakefs`.
3. Create PID 1, required device nodes, `/proc`, and `/dev/pts`.
4. Start `/sbin/init`.
5. Create terminal children with `become_new_init_child`, an Acode PTY driver, `create_stdio`, `do_execve`, and `task_start`.

`AcodeIshTerminal` is the narrow native adapter. It sends input with `tty_input`, applies window sizes with `tty_set_winsize`, forwards PTY output to Cordova, and hangs up sessions safely. Process completion comes from the standard iSH `exit_hook`; no LinuxInterop API or Objective-C method swizzling is used.

The JavaScript API remains `start`, `write`, `resize`, `stop`, and `exec`. The executor buffers output or exit events that arrive before Cordova registers the session callback.

Guest CPU pthreads use Apple's utility QoS. Long-running package installs and builds therefore yield scheduler priority to the app UI and other foreground work while continuing to make progress. The iOS guest advertises two CPUs by default to prevent language runtimes from creating a host-sized worker pool; host CLI tests can override this with `ISH_GUEST_CPU_COUNT`.

This does not grant unrestricted background execution. The guest is linked into
the Acode process, and iOS may suspend, expire, or terminate that process after
the app leaves the foreground. The native terminal can retain a session across
a short WebSocket or WebView interruption, but it cannot reconnect after the
app process or guest task has been killed. Keep important work checkpointed and
use a remote or CI host for jobs that must continue unattended. See
[`ISH_RUNTIME.md`](ISH_RUNTIME.md#10-background-and-lifecycle-boundaries) for
the lifecycle contract and [`LOCAL_DEVELOPMENT.md`](LOCAL_DEVELOPMENT.md#92-apple-lifecycle-restrictions-and-terminal-disconnects) for device troubleshooting.

## Build

Build both supported SDK archive sets:

```bash
ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh
```

Outputs:

- `third_party/ish-arm64/build/Release-arm64-iphoneos`
- `third_party/ish-arm64/build/Release-arm64-iphonesimulator`

Each contains `meson/libish.a`, `meson/libish_emu.a`, `meson/libfakefs.a`, and `libarchive.a`. The build checks ARM64 slices and required kernel, process, PTY, and fakefs-import symbols. It does not build kernel headers, `libiSHLinux`, `liblinux_user`, section archives, or a renamed Linux kernel entry point.

The terminal hook adds the fork root to Xcode header search paths, selects archives per SDK, and removes obsolete ReleaseLinux linker flags. After changing the plugin, refresh its generated Cordova copy before building:

```bash
bunx cordova plugin remove com.foxdebug.acode.rk.exec.terminal
bunx cordova plugin add src/plugins/terminal
bunx cordova prepare ios
```

## Root filesystem

Generate the bundled root from a pinned Alpine aarch64 minirootfs:

```bash
ISH_GUEST_ARCH=arm64 ./scripts/prepare-ish-rootfs.sh <alpine-aarch64.tar.gz> --sha256 <digest>
```

The script uses the standard ARM64 host `ish` and `fakefsify`, installs the tracked developer packages, verifies `uname -m`, checks required commands and SQLite integrity, checkpoints metadata, and removes `meta.db-shm`/`meta.db-wal` before promotion.

`meta.db` is authoritative. Files and directories must enter imported roots through `fakefs_import` or `fakefs_import_directory`; moving host files directly into `data/` is unsupported. Startup does not manufacture SQLite path records or rewrite fakefs symlinks. Bundled-root installation uses staging and rollback, while valid installed roots are preserved.

## Verification

For long commands, redirect output to `/private/tmp` and inspect the tail. The required checks are:

1. Build both archive sets with `scripts/build-ish.sh`.
2. Regenerate the rootfs and verify `aarch64`, required commands, SQLite integrity, and no sidecars.
3. Refresh the Cordova plugin and ensure the generated project contains no `ReleaseLinux`, `libiSHLinux`, or `liblinux-acode` references.
4. Build simulator and device configurations.
5. Install and launch on the existing simulator.
6. Manually verify prompt, input/Enter, `pwd`, `ls -la /`, `uname -m`, resize, Ctrl-C, exit, stop, concurrent terminals, and one-shot execution.
7. Inspect app logs for host crashes, guest page faults, invalid-directory failures, hung sessions, or dropped input.

The fork documents a 223-case compatibility result, but its bundled benchmark runner requires both its own x86 and ARM64 build/root directory names and rewrites benchmark reports. Do not claim a fresh 223/223 run unless that full fixture is provisioned; Acode's generated root is instead validated directly with the standard ARM64 CLI and app runtime flow.

For ARM64 host builds, `meson test -C third_party/ish-arm64/build-host-arm64` runs a focused LDXP/STXP and LDNP/STNP regression. This covers the pair atomics and non-temporal stores used by JavaScriptCore. Bun 1.3.14 is also used as a CLI compatibility workload: a local `bun add` must complete, write its lockfile, and execute the installed module. With `ISH_GUEST_CPU_COUNT=2`, four concurrent Bun workers must also start, exchange messages, and exit. A live registry install additionally requires working host network access and DNS.
