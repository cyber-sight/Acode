# iOS Terminal WebSocket Streaming Design

## Problem

The iOS terminal in Acode uses the Cordova bridge (`Executor.write()` / `handleNativeEvent()`) for every keystroke and output chunk, causing:

1. **High latency** — 8 dispatch hops + 2 Cordova bridge crossings per round trip
2. **No resize** — `resizeTerminal()` is a no-op on iOS, guest shell stuck at 80x24
3. **Wrong encoding** — `NSISOLatin1StringEncoding` corrupts Unicode/UTF-8
4. **Choppy output** — no output batching, each kernel write becomes a separate Cordova callback
5. **Lost characters** — `pendingEvents` buffer (256 cap) drops overflow

## Solution

Add a local WebSocket server on iOS (matching Android's `ProcessServer` pattern) so terminal I/O bypasses the Cordova bridge entirely. The WebSocket server uses Apple's Network framework (`NWListener`) for minimal overhead.

## Architecture

```
xterm.js → onData → WebSocket.send() ──[binary WS frame]──→ NWListener → tty_input()
xterm.js ← AttachAddon ← onmessage ──[binary WS frame]──→ NWListener ← acode_tty_write
```

## Components

### New: IshWebSocketServer (ObjC)
- Lightweight WebSocket server using `NWListener` on `127.0.0.1:{random_port}`
- Implements WebSocket handshake (HTTP upgrade) per RFC 6455
- Binary frames (opcode 0x2) for terminal output
- Text frames (opcode 0x1) for terminal input
- Internal 4KB output buffer flushed every 16ms to coalesce small writes
- JSON text frames for control: `{"type":"resize","cols":80,"rows":24}`
- Per-session: one server instance per terminal session

### Modified: Executor.m — `spawn:` action
- Creates iSH session via `IshBridge` with initial terminal dimensions
- Creates `IshWebSocketServer` on random port
- Wires WebSocket server ↔ iSH session I/O
- Returns port number to JS
- On WebSocket close: cleans up the session

### Fixed: IshBridge.m
- `NSISOLatin1StringEncoding` → `NSUTF8StringEncoding`
- New `startWithCommand:cols:rows:` variant for initial terminal size
- Skip redundant `kernelQueue` dispatch in output handler

### Modified: terminal.js
- iOS uses `Executor.spawnStream()` → gets WebSocket → `AttachAddon`
- Eliminates `connectToNativeSession()` entirely
- Resize works via WebSocket JSON messages
- Same code path as Android's WebSocket flow

### Modified: Executor.js
- `spawnStream()` already exists for Android — just enables for iOS

## Encoding

All WebSocket I/O uses binary frames (UTF-8 encoded). No string encoding/decoding at the bridge layer. xterm.js receives raw bytes via `AttachAddon`.
