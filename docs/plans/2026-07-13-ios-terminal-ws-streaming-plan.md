# iOS Terminal WebSocket Streaming — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Cordova-bridge terminal I/O on iOS with a WebSocket server for low-latency streaming, fix encoding, and add resize support.

**Architecture:** Local WebSocket server (`IshWebSocketServer`) using Apple Network.framework runs on each iSH terminal session — I/O bypasses Cordova exec entirely. JS connects via `WebSocket` + `AttachAddon` (same as Android).

**Tech Stack:** Objective-C (Network.framework NWListener), Cordova, xterm.js

---

### Task 1: Create IshWebSocketServer.h

**Files:**
- Create: `src/plugins/terminal/src/ios/IshWebSocketServer.h`

**Step 1: Write the header**

```objc
#import <Foundation/Foundation.h>

@class AcodeIshTerminal;

NS_ASSUME_NONNULL_BEGIN

@interface IshWebSocketServer : NSObject

@property (nonatomic, readonly) in_port_t port;

- (instancetype)initWithTerminal:(AcodeIshTerminal *)terminal;
- (BOOL)startWithError:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
```

**Step 2: Verify file created**

File should exist at the expected path.

---

### Task 2: Create IshWebSocketServer.m

**Files:**
- Create: `src/plugins/terminal/src/ios/IshWebSocketServer.m`

**Step 1: Write the implementation**

The WebSocket server should:
1. Create NWListener on 127.0.0.1:0 (random port)
2. On new connection: perform HTTP WebSocket upgrade handshake
3. On upgrade success: bridge WebSocket ↔ AcodeIshTerminal
4. Handle text frames (input) → `[terminal sendInput:]`
5. Handle binary frames (input) → `[terminal sendInput:]` (UTF-8 decoded)
6. Terminal output → binary frames (opcode 0x2) to WebSocket
7. Handle resize JSON: `{"type":"resize","cols":N,"rows":N}` → `[terminal resizeToColumns:rows:]`
8. Internal output buffer — coalesce writes, flush every 16ms or at 4KB
9. On close/error → cleanup

Key implementation details:
- WebSocket handshake: parse HTTP GET, validate `Sec-WebSocket-Key`, respond with `Sec-WebSocket-Accept` (SHA-1 + base64 per RFC 6455)
- Frame parsing: read 2-byte header, mask + length, unmask payload
- Frame sending: construct binary frame header (opcode 0x2), no mask (server→client)

**Step 2: Verify file created**

---

### Task 3: Modify Executor.h — add spawn: method

**Files:**
- Modify: `src/plugins/terminal/src/ios/Executor.h`

**Step 1: Add spawn method declaration**

```objc
- (void)spawn:(CDVInvokedUrlCommand *)command;
```

---

### Task 4: Modify Executor.m — implement spawn: action

**Files:**
- Modify: `src/plugins/terminal/src/ios/Executor.m`

**Step 1: Add import for IshWebSocketServer.h**

**Step 2: Implement spawn: method**

```
spawn: action:
1. Parse command string and initial cols/rows from args
2. Start iSH session via IshBridge with cols/rows
3. Get the AcodeIshTerminal from the session
4. Create IshWebSocketServer with the terminal
5. Start server → get port
6. Return port to JS callbackContext.success(port)
7. Store reference to server keyed by sessionId
8. On session exit event: stop the WebSocket server
9. In stopService: clean up all WebSocket servers
```

**Step 3: Also fix output event dispatch — remove the redundant kernelQueue → mainQueue double-dispatch in the output path and dispatch directly.**

---

### Task 5: Fix encoding in IshBridge.m

**Files:**
- Modify: `src/plugins/terminal/src/ios/IshBridge.m`

**Step 1: Fix NSISOLatin1StringEncoding → NSUTF8StringEncoding**

Line 166: `NSISOLatin1StringEncoding` → `NSUTF8StringEncoding`

**Step 2: Add cols/rows parameter support to startWithCommand**

Add a new variant or modify existing to accept initial terminal dimensions.
Pass to `[terminal resizeToColumns:rows:]` before `task_start`.

---

### Task 6: Update plugin.xml with new source files

**Files:**
- Modify: `src/plugins/terminal/plugin.xml`

**Step 1: Add IshWebSocketServer source files to iOS platform block**

```xml
<header-file src="src/ios/IshWebSocketServer.h" />
<source-file src="src/ios/IshWebSocketServer.m" />
```

---

### Task 7: Modify terminal.js — use WebSocket for iOS

**Files:**
- Modify: `src/components/terminal/terminal.js`

**Step 1: Modify createSession()**

Replace the iOS branch that calls `Executor.start("sh", callback)` with calling `Executor.spawnStream("sh")` to get a WebSocket.

**Step 2: Modify connectToSession()**

iOS path should follow the same WebSocket + AttachAddon pattern as Android, with these differences:
- WebSocket URL uses the port from spawnStream
- Handle resize via WebSocket JSON messages
- Handle exit events from WebSocket

**Step 3: Remove connectToNativeSession()**

No longer needed — replaced by WebSocket path.

**Step 4: Enable resizeTerminal() for iOS**

Remove `if (isIOSTerminal) return;`

---

### Task 8: Verify

**Step 1: LSP diagnostics on all changed files**

```bash
# Run diagnostics on new/modified ObjC files
```

**Step 2: Check for any remaining NSISOLatin1StringEncoding references**

**Step 3: Verify branch is clean**

```bash
git status
```
