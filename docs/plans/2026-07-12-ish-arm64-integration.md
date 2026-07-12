# Plan: Integrate OpenMinis/ish-arm64 into Acode

**Date:** 2026-07-12  
**Status:** Revised draft — pending approval before implementation  
**Goal:** Keep Acode's current `third_party/ish` checkout intact as the known-good x86 implementation and porting reference, add a pinned OpenMinis/ish-arm64 checkout at `third_party/ish-arm64`, build an arm64 Linux guest consistently from the new checkout, and ship an Alpine aarch64 rootfs without regressing the existing terminal and rootfs features.

## 1. Validated Current State

### 1.1 Parent and nested repository state

The parent repository tracks `third_party/ish` as a Git gitlink, but the checkout has no `.gitmodules` entry for it.

- Parent-recorded iSH commit: `b7a226e3392b3377eb8c5da5d56be04cf16a3414`
- Current nested iSH HEAD: `a079aa5` (`Auto-register orphaned files in fakefs`)
- Current nested branch: `fix-fakefs-opencode`
- Current nested remote: `git@github.com:ish-app/ish.git`
- Current uncommitted nested change: `linux/fakefs.c`

The nested checkout will remain in place throughout this integration. It must not be reset, cleaned, have its remote changed, or be repointed. Because it remains the live reference and rollback source, no Git bundle or external repository backup is required.

### 1.2 Acode changes that must be preserved

The committed iSH delta from the available upstream base through `a079aa5` affects approximately 22 paths, with an additional uncommitted change. The transfer inventory must be generated from Git rather than maintained only as a handwritten file list.

Known functional areas include:

- `app/LinuxInterop.h/.c`: session lifecycle, session-exit callback, hostname and VFS helpers
- `app/LinuxPTY.c`: PTY/session integration
- `app/LinuxRoot.c`: fakefs/procfs root initialization and `FsInitialize()`
- `app/xcode-meson.sh` and `iSH.xcodeproj/project.pbxproj`: Xcode/Meson integration
- `fs/fake.c`, `fs/fake-db.c`, `linux/fakefs.c`: fakefs behavior, symlinks, and orphan reconciliation
- `kernel/calls.c/.h`, `kernel/futex.c`: syscall and futex behavior
- `tools/fakefs.c/.h`, `tools/fakefsify-log.c`, `tools/meson.build`, `meson.build`: on-device rootfs import and library targets
- `deps/linux`: nested Linux source pointer

Generated or accidental files such as `.DS_Store` and Xcode caches must be classified and excluded rather than ported blindly.

### 1.3 Acode-side integration surface

These files remain part of the compatibility and regression scope:

- `src/plugins/terminal/src/ios/IshBridge.h/.m`
- `src/plugins/terminal/src/ios/IshTerminalBridge.m`
- `src/plugins/terminal/src/ios/IshRootfs.h/.c`
- `src/plugins/terminal/src/ios/RootfsManager.h/.m`
- `src/plugins/terminal/src/ios/Executor.h/.m`
- `src/plugins/terminal/www/Executor.js`
- `src/plugins/terminal/hooks/ios/add-ish-lib.js`
- `src/plugins/terminal/hooks/ios/add-ish-rootfs.js`
- `scripts/build-ish.sh`
- `scripts/prepare-ish-rootfs.sh`
- `scripts/ish-rootfs-packages.txt`
- `scripts/sync-ish-headers.sh`
- `docs/ISH_INTEGRATION.md`

## 2. Validated OpenMinis Fork Behavior

The OpenMinis fork inspected for this plan was:

- Repository: `https://github.com/OpenMinis/ish-arm64.git`
- Validated commit: `8932511fa0ab6abf77d5ead19503476d8b816f4f`
- Commit date: 2026-07-07

Revalidate the remote immediately before implementation and deliberately update the pinned commit if a newer revision is chosen.

### 2.1 Guest architecture model

The fork supports both `x86` and `arm64` Linux guests, selected at compile time through Meson:

```bash
-Dguest_arch=x86
-Dguest_arch=arm64
```

The default is `x86`. Host architecture and guest architecture are separate concerns: compiling an iOS binary for `arm64-apple-ios15.0` does not select the arm64 Linux guest.

The arm64 guest still runs through iSH's userspace emulation and syscall translation. It enables use of Alpine aarch64 packages, but it must not be described as unrestricted native Linux execution. Performance improvements must be measured rather than assumed.

### 2.2 API compatibility

The fork already contains the main Acode-facing API, including:

- `actuate_kernel()`
- `linux_start_session()`
- `linux_sethostname()` and the file helpers
- `struct linux_tty` and its output/input/resize/hangup callbacks
- terminal, pasteboard, dispatch, logging, root-path, panic, and ObjC bridge declarations

The fork does **not** contain Acode's `LinuxSessionExitBlock` and `linux_set_session_exit_handler()`. Those additions and their implementation must be ported.

### 2.3 Build structure

The fork retains the `ReleaseLinux` configuration and `libiSHLinux` target. Its Meson build still produces `libish_emu` and `libfakefs`, with architecture-specific emulator, VDSO, and syscall sources selected by `guest_arch`.

Library names and paths must still be verified from actual build output before changing the Cordova link hook.

## 3. Decisions Required Before Implementation

Only two choices are required before work begins:

1. **Canonical iSH repository:** use OpenMinis directly at a pinned commit, or create an Acode-owned fork that will contain the ported commits. An Acode-owned fork is recommended because Acode already carries a durable native patch series.
2. **Initial compatibility target:** ship arm64 guest only, or produce separate x86 and arm64 guest builds. Arm64-only is recommended for the first integration. Supporting both requires separate native artifact sets and an explicit build/package selection strategy; bundling two rootfs directories alone is insufficient.

The test scope is not optional: run the fork's registered tests for the selected guest architecture plus Acode's device-level integration and regression checks.

## 4. Implementation Plan

### Phase 0: Record and inventory the current iSH checkout

`third_party/ish` is the known-good reference implementation. Do not modify or remove it during any phase of this plan.

1. Record parent and nested status:

   ```bash
   git status --short
   git ls-files -s third_party/ish
   git -C third_party/ish status --short --branch
   git -C third_party/ish log --oneline --decorate -20
   ```

2. Record the exact reference state in the plan's implementation notes or migration commit description:

   ```bash
   git ls-files -s third_party/ish
   git -C third_party/ish rev-parse HEAD
   git -C third_party/ish branch --show-current
   git -C third_party/ish status --short
   ```

3. Generate the authoritative transfer inventory directly from the unchanged reference checkout:

   ```bash
   git -C third_party/ish diff --stat 5534d5a..HEAD
   git -C third_party/ish diff --name-status 5534d5a..HEAD
   git -C third_party/ish diff --name-status
   ```

4. Classify every changed path as functional code, build configuration, dependency pointer, or generated noise. Exclude generated Xcode caches and `.DS_Store` files.

**Gate:** do not continue until the committed delta, uncommitted delta, and transfer inventory have been inspected successfully. Leave `third_party/ish` at its current branch, HEAD, and working-tree state.

### Phase 1: Clone and register `third_party/ish-arm64`

1. Create or select the canonical Acode arm64 iSH fork.
2. Confirm `third_party/ish-arm64` does not already contain user work.
3. Add the new repository as a separate, properly registered submodule while leaving `third_party/ish` untouched:

   ```bash
   git submodule add <acode-ish-arm64-fork-url> third_party/ish-arm64
   git -C third_party/ish-arm64 checkout 8932511fa0ab6abf77d5ead19503476d8b816f4f
   ```

   If the chosen Acode-owned fork does not contain that exact OpenMinis commit yet, first create a port branch from the equivalent pinned upstream commit and record both hashes.

4. Initialize the new checkout's nested dependencies:

   ```bash
   git -C third_party/ish-arm64 submodule update --init --recursive
   ```

5. Verify `.gitmodules` contains a valid entry for `third_party/ish-arm64`. Do not repair or rewrite the existing `third_party/ish` metadata as part of this integration unless that is approved separately.
6. Record exact nested dependency revisions, especially `deps/linux` and `deps/libarchive`.
7. Confirm clean baseline builds in `third_party/ish-arm64` for both `guest_arch=x86` and `guest_arch=arm64` where supported. This separates upstream failures from Acode porting failures.
8. Keep all port commits on a dedicated branch in `third_party/ish-arm64`, for example `acode-arm64`.

**Gate:** the pinned clean `third_party/ish-arm64` checkout must configure and compile for the arm64 guest before Acode patches are introduced. `third_party/ish` must remain unchanged.

### Phase 2: Port Acode changes as a reviewable commit series

Use `third_party/ish` as the read-only source and `third_party/ish-arm64` as the only porting destination. Port changes in dependency order. For each current Acode commit:

1. Inspect the full patch and its intent.
2. Compare the `third_party/ish` implementation against the corresponding `third_party/ish-arm64` implementation.
3. Generate a patch from the unchanged reference checkout and apply it inside `third_party/ish-arm64` with `git am -3` when structurally compatible; otherwise port it manually there.
4. Resolve architecture-sensitive code deliberately rather than accepting textual conflict resolutions.
5. Build or run focused checks after each functional group.
6. Preserve provenance in the new commit message, including the original commit hash.

Recommended port order:

1. Root initialization and build scaffolding
2. Linux interoperability helpers
3. PTY/session lifecycle
4. `LinuxSessionExitBlock` and `linux_set_session_exit_handler()`
5. fakefs database, symlink, import, and orphan-reconciliation changes
6. syscall and futex changes
7. dependency-pointer and Xcode project changes
8. the current uncommitted `linux/fakefs.c` patch, only after its behavior is understood and tested

Special review requirements:

- Compare syscall changes against both `kernel/arch/x86/calls.c` and `kernel/arch/arm64/calls.c`.
- Check all affected structures for guest word-size and ABI assumptions.
- Do not copy `app/xcode-meson.sh`, project files, or Meson changes “as-is” until compared with the fork's current build system.
- Keep Acode's session-exit callback compatible with the fork's `linux_start_session()` cleanup path.
- Merge fakefs behavior based on invariants and tests, not only matching file names.

**Gate:** the patched fork must still build and pass focused tests after each group, with no unclassified patches remaining.

### Phase 3: Make guest architecture explicit end to end

Introduce one build input, for example:

```bash
ISH_GUEST_ARCH="${ISH_GUEST_ARCH:-arm64}"
```

Validate it strictly as `x86` or `arm64`, then propagate it consistently to every native build path:

- Xcode's `libiSHLinux` build and its Meson invocation
- `libish_emu.a`
- kernel architecture-specific sources
- the manually compiled `liblinux_user.a`
- host `ish` CLI used during rootfs preparation
- test build directories and commands

For an arm64 guest, manual compilation must receive `-DGUEST_ARM64=1`; for x86, `-DGUEST_X86=1`. Do not rely on the iOS host target triple to select the guest.

Update `scripts/build-ish.sh` so arm64 builds use `third_party/ish-arm64`, while preserving an explicit way to build the existing `third_party/ish` implementation if it is still needed. Prefer a source selector such as:

```bash
ISH_SOURCE_DIR="${ISH_SOURCE_DIR:-$ROOT_DIR/third_party/ish-arm64}"
```

Then update the script to:

1. derive every source, dependency, and output path from `ISH_SOURCE_DIR` rather than hardcoding `third_party/ish`;
2. use architecture-specific build directories such as `ReleaseLinux-arm64-iphoneos` and `ReleaseLinux-arm64-iphonesimulator`, or otherwise guarantee stale x86 outputs cannot be reused;
3. pass `-Dguest_arch=$ISH_GUEST_ARCH` to every Meson configuration;
4. propagate the matching preprocessor definition to manually compiled sources;
5. clean or reconfigure Meson when the guest architecture changes;
6. verify archive members and required symbols after building;
7. retain separate host targets for `iphoneos` and `iphonesimulator`;
8. fail if built artifacts do not match the requested guest architecture.

Update `src/plugins/terminal/hooks/ios/add-ish-lib.js` only after inspecting produced artifacts. Its arm64 artifact root must point to `third_party/ish-arm64`, never `third_party/ish`. Prefer preserving existing library names. If architecture-specific output directories are introduced, make the hook select the configured artifact set explicitly.

**Gate:** all linked archives must come from the same guest-architecture build, and both device and simulator native builds must link successfully.

### Phase 4: Verify the Acode bridge against the patched fork

1. Run `scripts/sync-ish-headers.sh` and inspect the copied headers for drift.
2. Verify `IshBridge.m` against the actual patched signatures:
   - kernel startup
   - session start
   - session exit handler
   - root selection
   - file reconciliation
3. Verify `IshTerminalBridge.m` implements every host callback required by the linked fork exactly once.
4. Check for duplicate symbols from the fork's `Terminal.m`, `IOSCalls.m`, or other iOS application objects. Acode's bridge and upstream app implementations must not both be linked accidentally.
5. Verify `IshRootfs.c` continues providing the Acode-selected `DefaultRootPath()` and panic behavior.
6. Verify resize, output backpressure, input, hangup, ObjC retain/release, workqueue dispatch, and initramfs stubs against the fork's current declarations.

**Gate:** compile and link the Cordova iOS project before rootfs migration. This isolates bridge/linker failures from guest-rootfs failures.

### Phase 5: Build and validate an arm64 guest CLI

`scripts/prepare-ish-rootfs.sh` executes guest binaries while preparing the filesystem, so it requires an `ish` host CLI compiled for the arm64 guest.

1. Add an explicit host-tools build for `guest_arch=arm64`.
2. Place the binary in an architecture-specific location such as `third_party/ish-arm64/build/host-arm64/ish`.
3. Build `fakefsify` from the same patched `third_party/ish-arm64` source tree.
4. Make `prepare-ish-rootfs.sh` accept or derive the selected guest architecture and select the matching CLI.
5. Fail early if the requested CLI is missing or was built for a different guest architecture.

**Gate:** before installing packages, import a minimal Alpine aarch64 archive and successfully execute `/bin/sh -c 'uname -m'`, expecting `aarch64`.

### Phase 6: Create the bundled Alpine aarch64 rootfs

1. Pin a specific Alpine aarch64 minirootfs version and SHA-256 digest. Do not use an unverified floating download.
2. Update the usage text in `scripts/prepare-ish-rootfs.sh` so it does not claim i386-only input.
3. Import the archive with the patched `fakefsify`.
4. Run the existing package setup with the arm64-guest CLI.
5. Verify every package in `scripts/ish-rootfs-packages.txt` is available for the selected Alpine release before treating the list as unchanged.
6. Preserve the archive version, architecture, SHA-256, and package list in `/etc/acode-rootfs-release`.
7. Run `acode doctor` and architecture checks inside the prepared filesystem.

Validate fakefs structurally using:

- a readable `meta.db` with a successful SQLite integrity check;
- a populated `data/` directory;
- metadata resolving `/bin/sh` correctly;
- the resolved executable being an aarch64 ELF where applicable;
- successful guest execution of `/bin/sh` and `uname -m`.

Do not require `data/bin/sh` itself to be an ELF: in fakefs it can contain a symlink target such as `/bin/busybox`.

**Gate:** package installation and all command-presence checks in `prepare-ish-rootfs.sh` must pass using the staged rootfs before it replaces the bundled rootfs.

### Phase 7: Tests and device validation

#### 7.1 Fork tests

Use separate build directories and select the guest explicitly:

```bash
meson setup build-test-arm64 -Dguest_arch=arm64
meson compile -C build-test-arm64
meson test -C build-test-arm64 --print-errorlogs
```

If x86 compatibility remains in scope, run the equivalent suite in `build-test-x86` with `-Dguest_arch=x86`.

Report registered tests and actual pass counts from the test runner. Do not use an unverified fixed count as a success criterion.

#### 7.2 Native build validation

1. Run the iSH build for arm64 guest/device host.
2. Run the iSH build for arm64 guest/simulator host.
3. Prepare the Cordova iOS project.
4. Build or archive the iOS application.
5. Inspect linker output for duplicate or missing symbols.
6. Confirm all linked archives came from the intended guest-architecture directory.

#### 7.3 Terminal integration

Validate the real Cordova bridge contract:

1. Start a shell and receive a session UUID.
2. Stream input and observe stdout/stderr framing.
3. Resize a running terminal and verify the guest PTY dimensions.
4. Run `uname -m` and expect `aarch64`.
5. Run Node.js and expect `process.arch === 'arm64'`.
6. Verify exit status propagation for success, nonzero exit, signal termination, and explicit stop.
7. Verify concurrent sessions and session cleanup.
8. Verify DNS and package-manager access.

#### 7.4 Rootfs manager regression

1. Import a valid aarch64 `.tar.gz` rootfs.
2. Reject an incompatible or malformed rootfs with a useful error.
3. Activate a root and verify restart behavior.
4. List, rename, and delete imported roots.
5. Verify default-root protection.
6. Verify iCloud/archive staging paths.
7. Verify fakefs reconciliation and symlink materialization.

#### 7.5 Existing Acode regression

Verify:

- terminal streaming and output backpressure;
- native resize handling;
- one-shot execution marker parsing;
- stop and `stopService` behavior;
- multiple sessions;
- rootfs selection persistence;
- filesystem reconciliation;
- application relaunch with the bundled rootfs.

#### 7.6 Performance characterization

Measure shell, Node.js, Python, and representative filesystem operations. Compare against a recorded x86 baseline only if the baseline can be reproduced on the same device and build configuration. Performance improvement is informational unless an explicit threshold is approved.

## 5. Rollback Plan

Because the existing checkout remains in place, rollback is a source-selection change rather than reconstruction of the old repository.

1. Stop using artifacts from `third_party/ish-arm64` in the build script and Cordova link hook.
2. Point `ISH_SOURCE_DIR` and the link hook back to the existing `third_party/ish` build outputs.
3. Restore the previous i386 rootfs artifact or regenerate it with the known-good x86 guest CLI and pinned archive.
4. Rebuild the original native libraries and rerun the existing terminal smoke tests.
5. Remove the `third_party/ish-arm64` gitlink and its `.gitmodules` entry only if the arm64 integration is being abandoned permanently and its port branch has already been pushed to its canonical remote.

Do not reset or clean `third_party/ish` during rollback. Its preserved branch, HEAD, and uncommitted `linux/fakefs.c` change are the rollback source of truth.

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| Current nested work is modified accidentally | Low | Critical | Treat `third_party/ish` as read-only and verify its status at every phase gate |
| Build scripts silently mix the two source trees | Medium | Critical | Centralize `ISH_SOURCE_DIR` and log resolved source/output paths |
| Host arm64 is confused with guest arm64 | High | Critical | One validated `ISH_GUEST_ARCH` propagated through every build |
| Acode patches conflict with arm64 ABI changes | High | High | Patch-by-patch port with architecture-aware review |
| Mixed x86 and arm64 archives are linked | Medium | High | Architecture-specific output directories and link checks |
| Rootfs builder uses an x86 guest CLI on aarch64 binaries | High without changes | High | Build and smoke-test an arm64 guest CLI first |
| Duplicate iOS bridge symbols are linked | Medium | High | Audit linked objects and compile bridge before rootfs work |
| fakefs behavior or format regresses | Medium | High | Integrity checks, import tests, reconciliation regression suite |
| Fork baseline is unstable | Medium | High | Pin a commit, build clean baseline, track Acode-owned patch branch |
| Performance is worse than expected | Medium | Medium | Benchmark on the same device; avoid unsupported claims |

## 7. Success Criteria

The integration is complete only when:

- [ ] `third_party/ish` remains at its original branch, HEAD, and working-tree state.
- [ ] `third_party/ish-arm64` has a valid `.gitmodules` entry and pinned gitlink.
- [ ] Every current Acode iSH change is ported, superseded with evidence, or explicitly excluded as generated noise.
- [ ] The selected OpenMinis base commit, `third_party/ish-arm64` port branch, and nested dependency revisions are documented.
- [ ] Guest architecture is explicitly set to `arm64` throughout Xcode, Meson, manual compilation, host tools, and tests.
- [ ] Device and simulator builds produce and link all required archives from the same arm64 guest build.
- [ ] The arm64 guest CLI runs the staged Alpine aarch64 rootfs and reports `aarch64`.
- [ ] The bundled rootfs passes metadata integrity, command-presence, package, and `acode doctor` checks.
- [ ] The Cordova iOS app builds and runs on a physical device.
- [ ] Terminal start, write, resize, stop, streaming, exit-status, and concurrent-session behavior pass.
- [ ] Node.js reports `process.arch === 'arm64'` and executes a smoke program.
- [ ] Rootfs import, validation, activation, listing, rename, deletion, and reconciliation pass.
- [ ] All tests registered by the selected fork configuration pass, or any exception is documented and approved.
- [ ] Rollback successfully rebuilds from the still-present `third_party/ish` checkout without reconstructing it.

## 8. Estimated Effort

| Phase | Estimate |
|---|---:|
| Record and inventory current state | 30–60 minutes |
| Establish and baseline the pinned fork | 2–4 hours |
| Port and review Acode patch series | 6–12 hours |
| Make guest architecture explicit across builds | 4–8 hours |
| Bridge/linker compatibility | 2–4 hours |
| Arm64 host tools and rootfs preparation | 3–6 hours |
| Device integration and regression testing | 6–10 hours |
| Documentation and rollback verification | 1–2 hours |
| **Total** | **25–48 hours** |

The range is wider than the original estimate because the current checkout has unrecorded repository metadata, an uncommitted native change, compile-time guest selection across multiple build systems, and device-only validation requirements.
