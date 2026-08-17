# Acode - Code Editor for Android and iOS

<p align="center">
  <img src='res/logo_1.png' width='250'>
</p>

[![](https://img.shields.io/endpoint?logo=telegram&label=Acode&style=flat&url=https%3A%2F%2Facode.app%2Fapi%2Ftelegram-members-count)](https://t.me/foxdebug_acode) [![](https://dcbadge.vercel.app/api/server/vVxVWYUAWD?style=flat)](https://discord.gg/vVxVWYUAWD)

## • Overview

Welcome to Acode Editor - a powerful and versatile code editing tool designed for mobile development. Android remains the primary product target, while this repository also contains the active iOS port and its native terminal runtime. Whether you're working on HTML, CSS, JavaScript, or other programming languages, Acode empowers you to code on-the-go with confidence.

## • Features

- Edit and create websites, and instantly preview them in a browser.
- Seamlessly modify source files for various languages like Python, Java, JavaScript, and more.
- Built-in javascript console
- Enjoy multi-language editing support with easy management tools.
- Enjoy a large collections of community plugins to enhance your coding experience.
- Use the integrated terminal on Android and the ARM64 iSH-backed terminal on iOS.

## • Installation

You can get Acode Editor from popular platforms:

[<img src="https://play.google.com/intl/en_us/badges/images/generic/en-play-badge.png" alt="Get it on Google Play" height="60">](https://play.google.com/store/apps/details?id=com.foxdebug.acodefree) [<img src="https://fdroid.gitlab.io/artwork/badge/get-it-on.png" alt="Get it on F-Droid" height="60"/>](https://www.f-droid.org/packages/com.foxdebug.acode/)

## • Project Structure

<pre>
Acode/
|
|- src/   - Core code and language files
|
|- src/plugins/terminal/ - Shared terminal API plus Android and iOS runtimes
|
|- www/   - Public documents, compiled files, and HTML templates
|
|- third_party/ish-arm64/ - OpenMinis iSH ARM64 checkout used by the iOS build
|
|- platforms/ and plugins/ - Cordova-generated projects and installed plugin copies
|
|- utils/ - CLI tools for building, string manipulation, and more
</pre>

## • iOS Port and Terminal Direction

The iOS port uses Cordova for the application shell and native Objective-C bridges for platform capabilities. The supported terminal direction is OpenMinis userspace iSH running an Alpine aarch64 guest:

- Build with Meson `kernel=ish` and `guest_arch=arm64` for both iOS device and simulator targets.
- Use `third_party/ish-arm64` as the active OpenMinis checkout. The separate `third_party/ish` tree remains an x86 reference and is not the supported iOS runtime.
- Keep the FakeFS root format (`meta.db` plus `data/`) authoritative. Root filesystem imports and generated roots must preserve SQLite metadata, executable files, and ARM64 ELF binaries.
- Do not use the experimental `ReleaseLinux`/`LinuxInterop` path. Its ARM64 guest ABI is incomplete and it is not linked into the supported Acode iOS build.

### iOS Terminal Transport

The terminal keeps the shared JavaScript API (`start`, `write`, `resize`, `stop`, and `exec`) while using a lower-overhead transport for interactive iOS sessions:

```text
xterm.js -> Executor.spawnStream() -> local WebSocket -> IshWebSocketServer
         -> AcodeIshTerminal -> iSH PTY and guest shell
```

The native server binds to loopback on a per-session port, sends terminal output as binary frames, accepts input frames, batches small output writes, and handles resize control messages. JavaScript attaches xterm.js through `AttachAddon` and can reconnect to a live native session if the WebView socket closes. iOS background execution remains subject to platform scheduling and suspension limits.

### Building the iOS Runtime

Install dependencies with Bun, then build the ARM64 iSH archives:

```bash
bun install
ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh
```

After changing the terminal plugin, refresh its generated Cordova copy before preparing or building iOS:

```bash
bunx cordova plugin remove com.foxdebug.acode.rk.exec.terminal
bunx cordova plugin add src/plugins/terminal
bunx cordova prepare ios
```

Generate a bundled root filesystem from a pinned Alpine aarch64 minirootfs with:

```bash
ISH_GUEST_ARCH=arm64 ./scripts/prepare-ish-rootfs.sh <alpine-aarch64.tar.gz> --sha256 <digest>
```

### Local Development Quick Start

The iOS terminal workflow is a macOS/Xcode workflow. The shortest path from a fresh checkout to a local simulator run is:

```bash
# Clone the branch containing the iOS terminal streaming work.
git clone --branch feat/ios-terminal-ws-streaming --recurse-submodules \
  git@github.com:cyber-sight/Acode.git Acode
cd Acode
git submodule update --init --recursive -- third_party/ish-arm64

# Install JavaScript dependencies and baseline Cordova plugins.
bun install
bun run setup
bunx cordova platform add ios

# Build the ARM64 iSH archives and host CLI tools.
ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh
meson setup third_party/ish-arm64/build-host-arm64 \
  third_party/ish-arm64 -Dguest_arch=arm64 --buildtype=release
meson compile -C third_party/ish-arm64/build-host-arm64

# Generate the FakeFS root from a pinned Alpine aarch64 archive.
ISH_GUEST_ARCH=arm64 ./scripts/prepare-ish-rootfs.sh \
  <alpine-aarch64.tar.gz> --sha256 <digest>

# Refresh generated plugin/platform files, then build and run the simulator.
bunx cordova plugin remove com.foxdebug.acode.rk.exec.terminal
bunx cordova plugin add ./src/plugins/terminal
bunx cordova prepare ios
ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  bunx cordova run ios --debug --target='iPhone-16e'
```

To inspect the prepared rootfs without Cordova or Xcode, run the prebuilt host
iSH binary directly:

```bash
ISH_BIN="$PWD/third_party/ish-arm64/build-host-arm64/ish"
ISH_ROOT="$PWD/src/plugins/terminal/src/ios/ish-rootfs"
"$ISH_BIN" -f "$ISH_ROOT" /bin/sh -c \
  'printf "arch=%s\\n" "$(uname -m)"; pwd; printf "rootfs-ok\\n"'
```

Expected architecture is `aarch64`. The CLI validates guest execution and
FakeFS independently; it does not exercise the iOS Objective-C bridge,
WebSocket reconnect, or xterm.js attachment.

The detailed build, rootfs, runtime, and acceptance checks are documented in [`docs/ISH_INTEGRATION.md`](docs/ISH_INTEGRATION.md). For a fresh clone, complete local build, and run commands, see [`docs/LOCAL_DEVELOPMENT.md`](docs/LOCAL_DEVELOPMENT.md). For the full iSH boot, FakeFS, PTY, WebSocket, reconnect, and failure-boundary explanation, see [`docs/ISH_RUNTIME.md`](docs/ISH_RUNTIME.md). Cordova-generated copies under `plugins/` and `platforms/ios/` should be treated as derived output and compared with the canonical files under `src/plugins/terminal/` when debugging propagation issues.

## • Multi-language Support

Enhance Acode's capabilities by adding new languages easily. Just create a file with the language code (e.g., en-us for English) in [`src/lang/`](https://github.com/Acode-Foundation/Acode/tree/main/src/lang) and include it in [`src/lib/lang.js`](https://github.com/Acode-Foundation/Acode/blob/main/src/lib/lang.js). Manage strings across languages effortlessly using utility commands:

```shell
bun run lang add
bun run lang remove
bun run lang search
bun run lang update
```

## • Contributing & Building the Application

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed instructions.

## • Contributors

<a href="https://github.com/Acode-Foundation/Acode/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=Acode-Foundation/Acode" />
</a>

## • Developing a Plugin for Acode

For comprehensive documentation on creating plugins for Acode Editor, visit the [repository](https://github.com/Acode-Foundation/acode-plugin).

For plugin development information, refer to: [Acode Plugin Documentation](https://docs.acode.app/)

## Star History

<a href="https://star-history.com/#Acode-Foundation/Acode&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Acode-Foundation/Acode&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Acode-Foundation/Acode&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Acode-Foundation/Acode&type=Date" />
 </picture>
</a>
