# Local Development

This document is the reproducible local workflow for the current Acode checkout,
including the iOS port, the ARM64 iSH runtime, and the native WebSocket terminal
transport.

The Android build remains the primary project workflow. The iOS path has extra
requirements because it builds native Objective-C code, links a guest runtime,
packages a FakeFS root, and then launches through Xcode or Cordova.

## 1. Clone the Correct Code

The iOS terminal work was developed on `feat/ios-terminal-ws-streaming`. Use the
branch that contains that work when cloning from a remote that has it:

```sh
git clone --branch feat/ios-terminal-ws-streaming --recurse-submodules \
  git@github.com:cyber-sight/Acode.git Acode
cd Acode
git status
```

The HTTPS equivalent is:

```sh
git clone --branch feat/ios-terminal-ws-streaming --recurse-submodules \
  https://github.com/cyber-sight/Acode.git Acode
```

If the branch has already been published as `main`, clone `main` instead:

```sh
git clone --branch main --recurse-submodules \
  git@github.com:cyber-sight/Acode.git Acode
cd Acode
git status
```

In the current checkout, `origin` is `Acode-Foundation/Acode` and `upstream` is
`cyber-sight/Acode`. The iOS feature branch is available from the latter. If a
fresh clone of `origin/main` does not contain the merge yet, use the feature
branch command above or fetch the development remote explicitly.

The merge into `main` may exist only in a local checkout until it is pushed. If
`main` is absent from the remote, fetch the feature branch and inspect it:

```sh
git fetch origin main feat/ios-terminal-ws-streaming
git switch --detach feat/ios-terminal-ws-streaming
```

Always initialize the ARM64 iSH source after cloning, even if the clone command
used `--recurse-submodules`:

```sh
git submodule update --init --recursive -- third_party/ish-arm64
git submodule status -- third_party/ish-arm64
test -f third_party/ish-arm64/meson.build
```

The supported iOS runtime is in `third_party/ish-arm64`. The historical
`third_party/ish` reference is not required for the ARM64 iOS build. In some
checkouts it is still a tracked historical gitlink but is not declared in the
current `.gitmodules`; do not use its absence as a reason to skip the ARM64
checkout.

## 2. Install Host Prerequisites

The iOS and iSH build scripts require macOS, Xcode, and an Apple SDK. The
following commands install the tools used by the repository scripts:

```sh
xcode-select --install
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
sudo xcodebuild -license accept
```

Install Homebrew if it is not already installed, then install Bun and the native
build tools:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew update
brew install bun meson ninja pkg-config xz cocoapods ios-deploy
source "$HOME/.zshrc"
```

Check the versions before starting a long build:

```sh
bun --version
git --version
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
meson --version
ninja --version
pod --version
```

The repository's iOS setup script also checks CocoaPods and `ios-deploy`:

```sh
./setup-ios.sh
```

`setup-ios.sh` is a host-preparation helper. It does not replace the explicit
Cordova platform and iSH steps below.

## 3. Install JavaScript Dependencies

Use Bun for the workspace dependency install:

```sh
bun install
```

The repository contains older scripts that invoke `node`, `npm`, or `npx`
internally. That is an implementation detail of those scripts; the supported
developer-facing entry point is still `bun`, `bun run`, or `bunx`.

For a fresh checkout, run the repository setup script once:

```sh
bun run setup
```

The setup script installs the baseline Cordova plugins and creates the Android
platform. Add iOS explicitly because iOS is not the default platform of that
script:

```sh
bunx cordova platform add ios
bunx cordova prepare ios
```

If the platform already exists, use `prepare` rather than adding it again:

```sh
bunx cordova prepare ios
```

## 4. Build the ARM64 iSH Libraries

The iOS plugin does not run the host `ish` executable. It links static ARM64
archives into the iOS app. Build those archives before building Cordova:

```sh
ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh
```

The script builds both SDK variants:

```text
third_party/ish-arm64/build/Release-arm64-iphoneos/
third_party/ish-arm64/build/Release-arm64-iphonesimulator/
```

Each SDK directory contains the native archives consumed by the iOS plugin
hook, including the iSH kernel/emulator archive, FakeFS, and libarchive.

The iOS path intentionally rejects non-ARM64 guest builds. It uses the supported
ARM64 fork with `kernel=ish` and `guest_arch=arm64`; it is not the old
ReleaseLinux integration.

To inspect the output after a successful build:

```sh
find third_party/ish-arm64/build \
  -maxdepth 3 \
  -type f \
  \( -name 'libish*.a' -o -name 'libfakefs.a' -o -name 'libarchive.a' \) \
  -print
```

The iOS hook fails early if either SDK is missing an archive or if the archives
do not contain the required iSH symbols. This is preferable to producing an app
that fails later during launch.

## 5. Build the Host ARM64 Runtime

The rootfs preparation script uses a host-built ARM64 `ish` executable and the
`fakefsify` tool. Build them in the directory expected by that script:

```sh
meson setup third_party/ish-arm64/build-host-arm64 \
  third_party/ish-arm64 \
  -Dguest_arch=arm64 \
  --buildtype=release
meson compile -C third_party/ish-arm64/build-host-arm64
```

For an existing build directory, reconfigure it instead of running `meson
setup` again:

```sh
meson setup --reconfigure \
  third_party/ish-arm64/build-host-arm64 \
  third_party/ish-arm64 \
  -Dguest_arch=arm64 \
  --buildtype=release
meson compile -C third_party/ish-arm64/build-host-arm64
```

Verify the two tools that the rootfs script will call:

```sh
test -x third_party/ish-arm64/build-host-arm64/ish
test -x third_party/ish-arm64/build-host-arm64/tools/fakefsify
```

## 6. Generate the iSH Rootfs

The app rootfs is not a normal directory copied directly from an Alpine
archive. It is a FakeFS image consisting of a SQLite metadata database and a
`data/` backing tree. Generate it with the repository script.

First download a pinned Alpine **aarch64** minirootfs archive from an
authoritative Alpine mirror. Keep the exact URL and SHA-256 digest with your
build record. The repository intentionally does not silently choose a moving
latest archive.

```sh
mkdir -p "$HOME/Downloads/acode-rootfs"
export ALPINE_ARCHIVE="$HOME/Downloads/acode-rootfs/alpine-aarch64.tar.gz"
export ALPINE_URL='<pinned-Alpine-aarch64-minirootfs-url>'
curl -fL "$ALPINE_URL" -o "$ALPINE_ARCHIVE"
export ALPINE_SHA256="$(shasum -a 256 "$ALPINE_ARCHIVE" | awk '{print $1}')"
printf 'archive=%s\nsha256=%s\n' "$ALPINE_ARCHIVE" "$ALPINE_SHA256"
```

Run the rootfs generator from the repository root:

```sh
ISH_GUEST_ARCH=arm64 ./scripts/prepare-ish-rootfs.sh \
  "$ALPINE_ARCHIVE" \
  --sha256 "$ALPINE_SHA256"
```

The script performs the following work:

1. Verifies the archive digest when `--sha256` is supplied.
2. Converts the archive through the ARM64 host `fakefsify` tool.
3. Boots the converted filesystem under the ARM64 guest emulator.
4. Installs the packages listed in `scripts/ish-rootfs-packages.txt`.
5. Creates the `acode` home, workspace mount points, profile, and doctor command.
6. Confirms that the guest reports `aarch64` and that required commands exist.
7. Runs SQLite integrity checks and truncates the WAL before promotion.
8. Removes `meta.db-shm` and `meta.db-wal` sidecars.
9. Replaces the app rootfs transactionally only after all checks pass.

The generated canonical rootfs is placed at:

```text
src/plugins/terminal/src/ios/ish-rootfs/
```

The expected shape is:

```text
ish-rootfs/
  meta.db
  data/
    bin/
    etc/
    home/
    root/
    tmp/
    ...
```

Do not commit or package `meta.db-shm` or `meta.db-wal`. They are live SQLite
sidecars and can make a copied rootfs appear corrupt or incomplete.

## 7. Refresh the Cordova Plugin Copy

Cordova maintains generated copies under `plugins/` and `platforms/`. The
canonical implementation is under `src/plugins/terminal/`. After changing the
plugin source, rebuild the generated copy:

```sh
bunx cordova plugin remove com.foxdebug.acode.rk.exec.terminal
bunx cordova plugin add ./src/plugins/terminal
bunx cordova prepare ios
```

The iOS hooks then perform two important packaging operations:

```text
add-ish-lib.js    -> injects ARM64 iSH archives and linker flags into Xcode
add-ish-rootfs.js -> copies the validated rootfs into the iOS app bundle
```

If the source code is correct but the app still runs old behavior, compare the
canonical source with these generated locations before debugging runtime logic:

```sh
diff -ru \
  src/plugins/terminal/src/ios \
  plugins/com.foxdebug.acode.rk.exec.terminal/src/ios

find platforms/ios -path '*ish-rootfs*' -maxdepth 6 -print
```

## 8. Build and Run on the iOS Simulator

List available simulator devices:

```sh
xcrun simctl list devices available
```

Boot Simulator manually if needed:

```sh
open -a Simulator
xcrun simctl boot 'iPhone 16e' 2>/dev/null || true
```

Build for an Apple Silicon simulator without signing:

```sh
ARCHS=arm64 \
ONLY_ACTIVE_ARCH=YES \
CODE_SIGNING_ALLOWED=NO \
bunx cordova build ios --debug
```

Install and launch on a named simulator:

```sh
bunx cordova run ios --debug --target='iPhone-16e'
```

For the watcher-driven development loop, use the repository dev runner:

```sh
bun run dev:ios -- --emulator --target='iPhone-16e'
```

The dev runner starts the frontend asset watcher and a local development server,
then launches Cordova. Changes to JavaScript/CSS are fast to iterate. Changes
to Objective-C, the iSH static archives, the rootfs, or `plugin.xml` require a
native prepare/build cycle.

## 9. Build and Run on a Physical iPhone

The device build requires an Apple development team, a provisioned signing
identity, and a trusted connected device. Confirm the device is visible:

```sh
xcrun devicectl list devices
```

Build and run through Cordova:

```sh
bunx cordova build ios --debug --device
bunx cordova run ios --debug --device
```

If Cordova completes the archive but does not launch the app, install and launch
the generated application with `devicectl`:

```sh
export DEVICE_UDID='<device-udid>'
export APP_PATH='platforms/ios/App.xcarchive/Products/Applications/Acode.app'
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"
xcrun devicectl device process launch \
  --device "$DEVICE_UDID" \
  --terminate-existing \
  com.foxdebug.acodeios
```

The iOS bundle identifier is `com.foxdebug.acodeios`; the Android/Cordova
widget identifier is different.

## 10. Android Development

Android does not use the iSH runtime described in this document. Start the
Android development loop with:

```sh
bun run dev:android -- --emulator
```

For an explicit Android build, use the repository's existing build script:

```sh
bun run build
```

`bun run build` is Android-oriented. It is not the iOS build command; use the
Cordova iOS commands above for iOS.

## 11. Run a Prebuilt iSH Binary from the CLI

The host build produces a standalone ARM64 iSH executable. You can use that
prebuilt binary to boot the same kind of FakeFS root that the iOS app embeds.
This is the fastest way to check the guest architecture, shell startup, package
set, and rootfs contents without launching Cordova.

Set explicit paths first:

```sh
export ISH_BIN="$PWD/third_party/ish-arm64/build-host-arm64/ish"
export ISH_ROOT="$PWD/src/plugins/terminal/src/ios/ish-rootfs"
test -x "$ISH_BIN"
test -f "$ISH_ROOT/meta.db"
test -d "$ISH_ROOT/data"
"$ISH_BIN" -f "$ISH_ROOT" /bin/sh -c 'test -d /home/acode'
```

The `-f` option means FakeFS. The value is the root directory containing
`meta.db` and `data/`; the binary mounts the `data/` subdirectory internally.
The command after the options is the guest executable and its arguments.

If the `/home/acode` check succeeds, start an interactive shell in that guest
directory:

```sh
"$ISH_BIN" \
  -f "$ISH_ROOT" \
  -d /home/acode \
  /bin/sh -i
```

Once the prompt appears, run the basic smoke test manually:

```sh
uname -m
pwd
printf 'guest-ok\n'
ls -la
command -v bash git node npm python3 pip3 curl
exit
```

The expected architecture is `aarch64`. The shell is a guest process; its
filesystem, `/proc`, `/dev`, and `/dev/pts` are provided by iSH rather than by
the host shell.

If the check fails, the rootfs was not generated through the Acode preparation
script yet. You can still boot it at `/` to diagnose the lower runtime, but
rerun the rootfs generation before treating it as an app-ready root:

```sh
"$ISH_BIN" -f "$ISH_ROOT" /bin/sh -i
```

Run a one-shot command without entering an interactive prompt. This form starts
at `/` and therefore also works with a partially prepared root:

```sh
"$ISH_BIN" \
  -f "$ISH_ROOT" \
  /bin/sh -c 'uname -m; pwd; printf "one-shot-ok\\n"'
```

Run a small scripted diagnostic and preserve its exit status:

```sh
"$ISH_BIN" \
  -f "$ISH_ROOT" \
  /bin/sh -c '
    set -eu
    printf "arch=%s\\n" "$(uname -m)"
    printf "cwd=%s\\n" "$PWD"
    test -x /bin/sh
    printf "rootfs-ok\\n"
  '
```

For an app-ready root, add the guest home and workspace checks:

```sh
"$ISH_BIN" -f "$ISH_ROOT" /bin/sh -c \
  'test -d /home/acode && test -d /workspace && printf "acode-root-ok\\n"'
```

The CLI parser in this iSH fork uses short options. The supported options are:

```text
-f PATH  mount PATH as FakeFS; PATH must contain meta.db and data/
-r PATH  mount PATH as a real filesystem instead of FakeFS
-d PATH  set the guest working directory
-c PATH  choose the guest console device; default is /dev/tty1
-n NAME  register a native-offload module, when the build supports it
```

There is no reliable `--help` interface in the prebuilt binary. Use the short
options above and always provide a guest command. For the Acode rootfs, use
`-f`, not `-r`:

```sh
"$ISH_BIN" -f "$ISH_ROOT" -d /home/acode /bin/sh
```

If the expected build path does not exist, locate another prebuilt binary:

```sh
find third_party/ish-arm64 \
  -type f \
  -path '*/ish' \
  -perm -111 \
  -print
```

The repository's upstream example uses `build-arm64-release/ish` with an
`alpine-arm64-fakefs` directory. The Acode integration uses the generated root
at `src/plugins/terminal/src/ios/ish-rootfs/` instead. If you need to recreate
the upstream-style fixture, first build `fakefsify` and convert a pinned Alpine
aarch64 archive; do not point the ARM64 binary at an x86 rootfs.

The CLI path does **not** exercise:

```text
IshBridge kernelQueue serialization
Objective-C session and PID maps
AcodeIshTerminal's iOS TTY adapter
IshWebSocketServer handshake and reconnect behavior
Cordova Executor.spawnStream/reconnectStream
xterm.js or AttachAddon
```

It does exercise the lower runtime boundary shared by the app: ARM64 guest
execution, FakeFS mounting, guest init/exec, shell startup, and guest-side
filesystem behavior. Use it before an iOS build when the suspected problem is
the rootfs or guest ABI rather than the UI or transport.

## 12. Focused Verification

Run source-level checks before a native build:

```sh
git diff --check
git status --short
rg -n 'ReleaseLinux|LinuxInterop|guest_arch|ISH_KERNEL|ISH_GUEST_ARCH' \
  scripts src/plugins/terminal third_party/ish-arm64
```

Verify rootfs integrity:

```sh
test -f src/plugins/terminal/src/ios/ish-rootfs/meta.db
test -d src/plugins/terminal/src/ios/ish-rootfs/data
test ! -e src/plugins/terminal/src/ios/ish-rootfs/meta.db-shm
test ! -e src/plugins/terminal/src/ios/ish-rootfs/meta.db-wal
sqlite3 src/plugins/terminal/src/ios/ish-rootfs/meta.db \
  'pragma integrity_check;'
```

Run the host ARM64 test suite when changing the iSH integration:

```sh
meson test -C third_party/ish-arm64/build-host-arm64
```

Manual iOS acceptance checks should cover all of these paths:

```text
launch -> shell prompt
type and receive input
pwd, ls, uname -m
resize the terminal
Ctrl-C an active command
exit the shell
stop a session from the UI
disconnect/reconnect the WebSocket
launch a second session concurrently
run a one-shot command
```

When a check fails, collect the native console output and record whether the
failure occurred during rootfs promotion, kernel boot, PTY creation, WebSocket
handshake, or frontend attachment. Those are separate boundaries with separate
diagnostics; the runtime guide explains them in detail.

## 13. Common Failure Modes

### Missing iSH archives

`add-ish-lib.js` reports a missing archive when `scripts/build-ish.sh` has not
completed for both SDKs. Re-run the iSH build and verify both output directories.

### Wrong architecture

An x86 or generic Linux rootfs is not valid for this integration. Recreate it
from an Alpine aarch64 archive and confirm the guest prints `aarch64`.

### Stale generated plugin

If native source changes are not visible in the app, refresh the local plugin
copy and run `bunx cordova prepare ios`. The app builds from generated Cordova
files, not directly from every file under `src/plugins/terminal/`.

### Rootfs database sidecars

Never copy a rootfs while SQLite is holding a WAL. Stop the generator, run the
integrity check, checkpoint the database, and ensure the two sidecar files are
absent before packaging.

### WebSocket connects but no output appears

Check that the native session was created, that the frontend received a `port`
and `sessionId`, and that the xterm `AttachAddon` is attached to the returned
socket. A successful Cordova `spawn` callback alone does not prove that PTY
bytes reached the terminal.

### Device launch fails after a successful build

Treat signing, installation, and launch as separate steps. Use `devicectl` to
install the generated `.app`, then launch bundle identifier
`com.foxdebug.acodeios` explicitly.
