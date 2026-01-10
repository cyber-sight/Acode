# Acode iOS Support + iSH Integration — Conversation Export

## User request
- Add iOS support across Cordova plugins (keep JS API intact), only Terminal + Proot can be unsupported initially.
- Add `setup-ios.sh` to prepare macOS for iOS builds.
- Add stricter iOS permission handling and iOS Info.plist entries.
- Implement iSH-style x86 emulation for Terminal on iOS and integrate with Cordova.
- Export conversation summary for macOS continuation.

## Work completed (high level)
- Added iOS implementations or stubs for plugins, with real implementations for:
  - BuildInfo, Browser, System (partial), FTP, SFTP, WebSocket, Server, IAP, SDcard.
- Added iOS permission handling + Info.plist entries.
- Added iSH source clone, bridge stubs, and initial iSH integration wiring.
- Added build + rootfs scripts and hooks.

## Key file changes

### iOS plugin implementations
- BuildInfo iOS: `src/plugins/cordova-plugin-buildinfo/src/ios/CDVBuildInfo.m`
- Browser iOS: `src/plugins/browser/ios/Browser.m`
- System iOS: `src/plugins/system/src/ios/System.m`
- FTP iOS (GRRequests): `src/plugins/ftp/src/ios/Ftp.m`
- SFTP iOS (NMSSH): `src/plugins/sftp/src/ios/Sftp.m`
- WebSocket iOS (URLSessionWebSocketTask): `src/plugins/websocket/src/ios/WebSocketPlugin.m`
- Server iOS (GCDWebServer): `src/plugins/server/src/ios/Server.m`
- IAP iOS (StoreKit): `src/plugins/iap/src/ios/Iap.m`
- SDcard iOS (UIDocumentPicker + FS): `src/plugins/sdcard/src/ios/SDcard.m`

### JS action mapping for iOS
- System action mapping: `src/plugins/system/www/plugin.js`
- SDcard action mapping: `src/plugins/sdcard/www/plugin.js`

### iOS permissions + Info.plist
- Stricter permissions in System plugin: `src/plugins/system/src/ios/System.m`
  - Notifications, camera, mic, photos mapped to iOS prompts.
- Info.plist keys in `config.xml`:
  - `NSCameraUsageDescription`
  - `NSMicrophoneUsageDescription`
  - `NSPhotoLibraryUsageDescription`
  - `NSPhotoLibraryAddUsageDescription`
  - `NSLocalNetworkUsageDescription`

### iSH integration
- iSH cloned: `third_party/ish`
- Bridge + rootfs support:
  - `src/plugins/terminal/src/ios/IshBridge.h`
  - `src/plugins/terminal/src/ios/IshBridge.m`
  - `src/plugins/terminal/src/ios/IshRootfs.h`
  - `src/plugins/terminal/src/ios/IshRootfs.c`
- Executor streaming wired:
  - `src/plugins/terminal/src/ios/Executor.m`
- Headers synced:
  - `src/plugins/terminal/src/ios/ish/include/LinuxInterop.h`
  - `src/plugins/terminal/src/ios/ish/include/Terminal.h`
- Plugin hooks and files:
  - `src/plugins/terminal/plugin.xml`

### Scripts and docs
- iOS setup: `setup-ios.sh`
- iSH build: `scripts/build-ish.sh`
- iSH header sync: `scripts/sync-ish-headers.sh`
- iSH rootfs prep: `scripts/prepare-ish-rootfs.sh`
- iSH fetch: `scripts/fetch-ish.sh`
- iSH docs: `docs/ISH_INTEGRATION.md`

## iSH integration notes

### What is wired
- iSH sessions started via `linux_start_session`.
- PTY output bridged by swizzling `Terminal sendOutput:length:`.
- Input sent via `Terminal sendInput:`.
- Rootfs copied from app bundle `ish-rootfs` into `Documents/ish-rootfs`.
- Rootfs path provided by `DefaultRootPath()` in `IshRootfs.c`.

### What’s still required (macOS)
1) Build iSH static library
   - `scripts/build-ish.sh`
   - Update scheme after `xcodebuild -list -project third_party/ish/iSH.xcodeproj`
2) Sync headers
   - `scripts/sync-ish-headers.sh`
3) Prepare rootfs
   - `scripts/prepare-ish-rootfs.sh /path/to/alpine-rootfs.tar.gz`
4) Add iOS platform
   - `npx cordova platform add ios`
5) Optional auto-linking
   - `npm install -D xcode`
   - Hook `hooks/ios/add-ish-lib.js` links `libiSHLinux.a` into Xcode project

## Outstanding TODOs
- Add exit callbacks from iSH sessions to JS (`exit:<code>`)
- Ensure iSH static library is linked properly in Cordova iOS build
- Bundle a minimal Alpine rootfs in `src/ios/ish-rootfs`

## iOS dependency notes
- iOS pods/frameworks added via plugin.xml:
  - GRRequests (FTP)
  - NMSSH (SFTP)
  - GCDWebServer (Server)
  - StoreKit.framework (IAP)
  - UserNotifications.framework (System)
  - MobileCoreServices.framework + UniformTypeIdentifiers.framework (SDcard)

## Command summary (macOS)
```
./setup-ios.sh
scripts/fetch-ish.sh
scripts/sync-ish-headers.sh
scripts/prepare-ish-rootfs.sh /path/to/alpine-rootfs.tar.gz
scripts/build-ish.sh
npm install -D xcode
npx cordova platform add ios
npx cordova build ios
```

