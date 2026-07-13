# Plan: integrate OpenMinis iSH ARM64 into Acode

**Date:** 2026-07-12
**Corrected:** 2026-07-13
**Status:** Implemented and verified in the simulator; the signed device archive also succeeds

## Decision

Keep `third_party/ish` unchanged and use `third_party/ish-arm64` as a separate registered checkout. Run an Alpine aarch64 guest through OpenMinis' supported userspace iSH kernel (`kernel=ish`, `guest_arch=arm64`).

The earlier plan incorrectly selected the fork's experimental `ReleaseLinux` target because the configuration and LinuxInterop interfaces existed. Runtime testing demonstrated that the Linux port's ARM64 guest ABI is incomplete: basic filesystem operations failed and the shell faulted through x86-specific signal handling. Presence of the target was not evidence that it was the fork's supported ARM64 runtime.

## Implementation record

- Preserved the nested experimental Linux work on `archive/acode-release-linux-arm64` at `cc0802716`.
- Preserved the corresponding outer fork work on the same archive branch at `4946324`.
- Restored active `third_party/ish-arm64/acode-arm64` to `5483be0` and retained its pinned dependencies.
- Replaced the ReleaseLinux build with device and simulator userspace-iSH archives.
- Replaced LinuxInterop session creation with standard iSH task, exec, fakefs, and PTY APIs.
- Added an explicit Acode TTY adapter and standard process-exit routing.
- Removed runtime metadata synthesis and symlink materialization.
- Made bundled-root promotion transactional and root validation architecture-aware.
- Checkpointed the bundled database and excluded SQLite sidecars.
- Preserved the Cordova JavaScript executor and root-management interfaces.

## Acceptance gates

- Both SDK archive sets build and export the required standard iSH symbols.
- The pinned Alpine root reports `aarch64`, contains all tracked developer tools, and passes SQLite integrity validation.
- Cordova prepare produces no ReleaseLinux archive or linker references.
- Simulator and device app builds succeed.
- The installed simulator app launches without crashing.
- Manual simulator testing confirms that terminal creation and interactive shell input work. The remaining detailed command, signal, concurrency, and one-shot checks are the release acceptance checklist.
- Final nested and parent branches are pushed to their configured upstream remotes.

See `docs/ISH_INTEGRATION.md` for current architecture, commands, and operational constraints.
