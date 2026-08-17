# iSH Runtime Internals

This document explains how the ARM64 iSH runtime is embedded in the iOS Acode
terminal. It traces boot, rootfs mounting, process creation, PTY I/O, WebSocket
streaming, reconnect, root management, and the limits of the standalone CLI.

This is not a native iOS shell. It is an ARM64 Linux-like guest running inside
the iSH emulator and kernel, with an Alpine aarch64 userspace backed by FakeFS.
Acode supplies the native bridge, the PTY adapter, the local WebSocket server,
and the JavaScript terminal UI.

## 1. Runtime Contract

~~~text
host:        iOS arm64 application
guest CPU:   ARM64 userspace emulated by the iSH fork
guest OS:    Alpine aarch64 userspace
kernel:      iSH kernel, configured as kernel=ish
filesystem:  FakeFS, represented by meta.db plus data/
terminal:    iSH PTY exposed through Acode's TTY adapter
transport:   loopback WebSocket between native code and JavaScript
~~~

The supported iOS runtime is the ARM64 fork in
third_party/ish-arm64. The old ReleaseLinux approach is not supported because
it does not provide the ARM64 guest ABI, signal-frame behavior, and
rt_sigreturn behavior required by this integration.

The runtime has these layers:

~~~text
Terminal component and xterm.js
        |
        | Executor.spawnStream, WebSocket, AttachAddon
        v
Cordova Executor plugin
        |
        | Objective-C spawn, reconnect, and stop methods
        v
IshBridge and IshWebSocketServer
        |
        | AcodeIshTerminal and IshTerminalBridge
        v
iSH task, PTY, and TTY driver
        |
        | guest system calls and processes
        v
iSH ARM64 kernel and emulator
        |
        v
FakeFS-mounted Alpine aarch64 rootfs
~~~

A shell prompt is meaningful evidence. It implies that rootfs mounting, guest
PID 1 startup, child creation, executable loading, PTY wiring, transport
delivery, and frontend attachment all worked together.

## 2. Source and Generated-Asset Map

~~~text
scripts/build-ish.sh
  Builds iOS ARM64 archives for iphoneos and iphonesimulator.

scripts/prepare-ish-rootfs.sh
  Creates and validates the FakeFS Alpine aarch64 rootfs.

src/plugins/terminal/plugin.xml
  Registers Objective-C sources, frameworks, archives, and iOS hooks.

src/plugins/terminal/hooks/ios/add-ish-lib.js
  Adds iSH, FakeFS, and libarchive archives and linker flags to Xcode.

src/plugins/terminal/hooks/ios/add-ish-rootfs.js
  Copies the canonical rootfs into the generated iOS app bundle.

src/plugins/terminal/src/ios/IshBridge.h/.m
  Owns kernel lifecycle, rootfs mount, sessions, and native API methods.

src/plugins/terminal/src/ios/AcodeIshTerminal.h/.m
  Owns one guest PTY and translates native input, output, and resize calls.

src/plugins/terminal/src/ios/IshWebSocketServer.h/.m
  Serves the local WebSocket data plane for one terminal session.

src/plugins/terminal/src/ios/Executor.h/.m
  Exposes native control-plane methods to Cordova.

src/plugins/terminal/www/Executor.js
  Calls Cordova and opens a WebSocket to the returned local port.

src/components/terminal/terminal.js
  Creates xterm sessions, attaches streams, reconnects, resizes, and disposes.
~~~

Cordova copies plugin files under plugins/ and creates platform files under
platforms/ios/. Those are generated build products. If they disagree with
src/plugins/terminal/, refresh the plugin and prepare the platform before
concluding that the source fix is ineffective.

## 3. FakeFS Rootfs

### 3.1 The two-part filesystem

FakeFS stores metadata and file content separately:

~~~text
meta.db  -> directory entries, metadata, inode-like state, file locations
data/    -> backing files and directories referenced by the database
~~~

The guest sees these as one filesystem after iSH mounts FakeFS. A host directory
that merely looks like /bin, /etc, or /home is not a valid replacement. The
metadata database must describe the content that guest path resolution will use.

The canonical generated root is:

~~~text
src/plugins/terminal/src/ios/ish-rootfs/
  meta.db
  data/
~~~

The normal build produces additional copies:

~~~text
plugins/com.foxdebug.acode.rk.exec.terminal/src/ios/ish-rootfs/
  Cordova plugin copy

platforms/ios/App/ish-rootfs/
platforms/ios/www/ish-rootfs/
  generated iOS platform and app copies

Documents/ish-rootfs/
  active writable app root managed by RootfsManager
~~~

RootfsManager selects the active writable root in app Documents. The bundled
root is used to stage or restore the default. Imported roots must be validated
before activation.

### 3.2 Generation pipeline

prepare-ish-rootfs.sh takes a pinned Alpine aarch64 minirootfs archive and calls
the host-built ARM64 fakefsify tool. It then boots the converted filesystem
under host iSH to configure and validate it:

~~~text
Alpine aarch64 tarball
        |
        v
fakefsify conversion
        |
        v
temporary FakeFS root
        |
        +--> apk update and package installation
        +--> /home/acode, /workspace, /mnt/acode
        +--> profile and acode doctor command
        +--> architecture and command validation
        +--> SQLite checkpoint and integrity check
        v
validated canonical rootfs
~~~

The package list is explicit in scripts/ish-rootfs-packages.txt. It supplies
the shell and common developer tools used by the terminal, including Bash, Git,
Node, NPM, Python, pip, curl, certificates, and Alpine command lookup support.

The generated guest profile establishes:

~~~text
HOME=/home/acode
USER=acode
LOGNAME=acode
PATH=/home/acode/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
~~~

This is guest configuration. It does not expose the host Bun executable inside
the guest. Guest tools must be installed into the rootfs or guest home.

### 3.3 Validation and promotion

The generator stages a temporary root and promotes it only after validation.
The gates are:

~~~text
archive SHA-256 matches the supplied digest
guest reports aarch64
/bin/sh exists and can start
required commands exist
acode doctor succeeds
meta.db passes SQLite integrity_check
meta.db WAL is checkpointed
meta.db-shm and meta.db-wal are absent
~~~

SQLite sidecars are not rootfs content. They indicate that a database was copied
while active and can make the packaged root appear corrupt or incomplete.

## 4. Kernel Startup

IshBridge serializes kernel operations on its private kernelQueue. iSH kernel
state, task lists, PTYs, and FakeFS operations must not be mutated concurrently
from arbitrary UIKit or Cordova callbacks.

The first session calls startKernelIfNeeded. The boot sequence is:

~~~text
1. Ensure the active rootfs is ready.
2. Resolve the rootfs data/ backing path.
3. Mount FakeFS with mount_root(&fakefs, dataPath).
4. Become the iSH first process, the guest PID 1.
5. Mount or initialize procfs and devpts.
6. Install exit and fatal-error handlers.
7. Configure guest console and standard I/O.
8. Start the configured guest init command.
9. Keep the kernel alive for later Acode sessions.
~~~

The app does not launch a separate Linux process through fork or an iOS shell
binary. These calls enter the iSH task and emulator runtime linked into the app.

The init command comes from active root configuration. The standard root expects
/sbin/init to exist. RootfsManager validates and configures init for imported
roots. If init cannot be loaded, Objective-C session creation can return while
the guest never becomes usable.

## 5. Creating a Guest Session

The JavaScript terminal requests a stream session through Executor.spawnStream.
The native call chain is:

~~~text
terminal.js
  -> Executor.spawnStream(command, callback)
  -> cordova.exec("Executor", "spawn", ...)
  -> Executor.m: spawn
  -> IshBridge: startWithCommand:completion:
  -> iSH task creation and PTY allocation
  -> IshWebSocketServer creation
  -> { port, sessionId }
~~~

### 5.1 Interactive and one-shot commands

An empty command, sh, or /bin/sh is treated as an interactive shell. The bridge
starts it with /bin/sh -i so it has a prompt and terminal behavior.

A noninteractive command is wrapped so it starts in the Acode guest home and
workspace with the expected environment. The bridge still executes /bin/sh with
the requested command as its payload. The process is a guest task, not a host
process.

The essential native sequence is:

~~~text
become_new_init_child()
create AcodeIshTerminal and its PTY
create_stdio("/dev/pts/<number>", ...)
set TERM, HOME, USER, LOGNAME, PATH
do_execve("/bin/sh", argv, envp)
store session UUID -> terminal and PID mappings
task_start()
~~~

The session UUID and guest PID are different identifiers. The UUID is used by
JavaScript reconnect and frontend bookkeeping. The PID identifies the guest task
for native exit and cleanup.

### 5.2 Why a PTY is created before exec

The shell must see a terminal-like device rather than an ordinary pipe. The PTY
is attached to child standard streams before shell execution. This enables line
editing, prompts, terminal control sequences, Ctrl-C, and window-size changes.

## 6. PTY and TTY Adapter

AcodeIshTerminal owns one guest terminal endpoint. IshTerminalBridge implements
the adapter functions used by the iSH TTY driver.

### 6.1 Output

When the guest writes to its PTY, the TTY driver calls the adapter output
callback. The adapter copies the bytes to NSData and forwards them to the
session output handler.

The WebSocket path keeps these bytes raw. Terminal output contains UTF-8,
ANSI escape sequences, control characters, and sometimes partial multi-byte
sequences. Decoding each callback independently can corrupt a character split
across callbacks.

There is a legacy callback path in IshBridge.m that decodes output using ISO
Latin-1 for older Executor consumers. The streaming WebSocket path bypasses this
conversion and sends raw binary frames to JavaScript. The WebSocket path should
not be diagnosed as Latin-1 merely because the legacy path still exists.

### 6.2 Input

When xterm sends input, the WebSocket server passes the received bytes to
AcodeIshTerminal, which calls the iSH TTY input function. The bytes go into the
guest PTY, not into a host shell and not through a temporary file.

### 6.3 Resize

The frontend sends a JSON control message:

~~~json
{"type":"resize","cols":120,"rows":34}
~~~

The native WebSocket server parses it and calls the terminal adapter. The
adapter locks the guest TTY and invokes tty_set_winsize. Programs such as
shells, stty, full-screen editors, and pagers can then observe the dimensions.

Resize is intentionally separate from stdin. It is not a shell input sequence
and does not depend on the shell interpreting a terminal escape code.

### 6.4 Destruction

Explicit session stop destroys the PTY, applies hangup behavior, stops the
WebSocket listener, and removes session mappings. A WebSocket disconnect alone
does not destroy the PTY because the frontend can reconnect to the same guest
session.

## 7. WebSocket Data Plane

### 7.1 Purpose

The original bridge exposed per-keystroke Cordova calls for input and a native
callback for output. That increases round trips, fragments output, and makes
resize coordination difficult.

The streaming implementation keeps the guest runtime native but creates one
loopback WebSocket server per session. JavaScript gets a browser-compatible
stream without creating a LAN-accessible service.

### 7.2 Connection setup

IshWebSocketServer binds an NWListener to loopback on an ephemeral port. The
native Executor.spawn method returns the port and session UUID:

~~~json
{"port":54321,"sessionId":"..."}
~~~

Executor.js then opens:

~~~text
ws://127.0.0.1:<port>
~~~

The server performs the RFC 6455 upgrade handshake and validates client frames.
It is loopback-only; the returned port is not a public or LAN service.

### 7.3 Frame types

~~~text
server -> client: binary frame containing raw PTY output bytes
client -> server: binary frame containing terminal input bytes
client -> server: text JSON resize control message
~~~

Binary output avoids an accidental lossy native-to-JavaScript string conversion
and lets xterm consume ANSI and UTF-8 data as a terminal stream.

### 7.4 Buffering

The native server coalesces output and flushes it on a short timer instead of
performing one network write per character. This reduces overhead while keeping
interactive latency low. The output buffer is bounded so a slow or disconnected
client cannot grow native memory without limit.

The buffer is after the PTY callback and before the WebSocket frame. It does not
change guest scheduling or PTY input semantics.

### 7.5 Reconnect

The frontend retains the session UUID and can call
Executor.reconnectStream(sessionId) after a socket closes. Native reconnect
looks up the existing session, creates a new listener when necessary, and
returns a port for the same guest PTY.

The terminal reconnect loop uses backoff and stops retrying when native code
reports that the session no longer exists:

~~~text
socket lost, session alive -> reconnect may recover the terminal
session explicitly stopped -> reconnect must stop
guest process exited       -> reconnect must stop
~~~

Native stop is authoritative. Closing the browser WebSocket is not equivalent to
stopping the shell.

## 8. Cordova and JavaScript API

Executor.js exposes two API generations:

~~~text
legacy:
  start, write, resize, stop, isRunning, exec

streaming:
  spawnStream, reconnectStream
~~~

Streaming methods use Cordova for control-plane operations such as creating and
stopping a native session. They use WebSocket for the data plane.

The iOS terminal component:

~~~text
1. checks that the iOS terminal runtime is installed
2. requests Executor.spawnStream(["sh"])
3. receives port and sessionId
4. opens the loopback WebSocket
5. attaches xterm's AttachAddon
6. fits and focuses the terminal
~~~

When the terminal dimensions change, terminal.js sends the JSON resize message
over the active socket. It does not use the old per-event Cordova resize method
for the iOS streaming path.

The older start/write/resize methods remain for existing consumers. Confirm
which API is active before diagnosing an iOS transport issue: Executor.start
does not exercise the same path as the xterm WebSocket session.

## 9. Root Management at Runtime

RootfsManager owns app-level root selection and persistence. Its responsibilities
include:

~~~text
validate the bundled default root
validate imported roots
copy or import FakeFS content into app storage
list available roots
activate a root
rename a root
configure or inspect its init command
delete non-active roots
report the active public home path
reconcile filesystem state
~~~

Activation is a state transition, not just a string assignment. The manager
validates the target, updates active-root state, and keeps the default root
recoverable.

The public home path can be used by host-side integration code that exposes the
active guest home to the app. It is not a promise that arbitrary host files are
visible inside the guest without an explicit FakeFS import or mount path.

## 10. Background and Lifecycle Boundaries

The plugin has foreground terminal lifecycle logic and may contain background
runtime coordination in the current checkout. iOS background execution is
bounded by system policy; a background task or assertion does not create an
indefinitely running in-process emulator.

The reliable lifecycle contract is:

~~~text
foreground session -> native PTY and WebSocket are active
socket disconnect -> session may remain available for reconnect
explicit stop     -> PTY and guest task are cleaned up
app suspension    -> execution and delivery may be interrupted by iOS policy
~~~

Do not describe a background session as guaranteed merely because a background
API was requested. Validate behavior on the target iOS version and device.

## 11. Failure Diagnosis by Boundary

### Build-time failures

Symptoms:

~~~text
missing libish or libfakefs archive
missing required symbol
ReleaseLinux linker flags reappearing
rootfs hook cannot find the rootfs
~~~

Check the ARM64 build and generated plugin state:

~~~sh
ISH_GUEST_ARCH=arm64 ./scripts/build-ish.sh
find third_party/ish-arm64/build -type f -name '*.a' -print
git diff --check
~~~

add-ish-lib.js is the source of truth for the archive names and linker flags
consumed by Xcode.

### Rootfs failures

Symptoms:

~~~text
guest exits before a prompt
/bin/sh cannot be loaded
guest reports the wrong architecture
SQLite reports corruption
~~~

Check:

~~~sh
sqlite3 src/plugins/terminal/src/ios/ish-rootfs/meta.db \
  'pragma integrity_check;'
test ! -e src/plugins/terminal/src/ios/ish-rootfs/meta.db-shm
test ! -e src/plugins/terminal/src/ios/ish-rootfs/meta.db-wal
~~~

Recreate a wrong-architecture or corrupt root from an Alpine aarch64 archive.
Do not repair it by copying host /bin files into the FakeFS data directory.

### Kernel startup failures

A native spawn callback without a prompt is not enough evidence of boot. Check
these events in order:

~~~text
active root selected
FakeFS mount succeeded
guest PID 1 became active
procfs and devpts initialized
init was found and executed
child PTY was created
~~~

A failure before PTY creation is a kernel or rootfs issue. A failure after PTY
creation may be a task, exec, transport, or frontend issue.

### PTY failures

If a prompt appears but input, Ctrl-C, or resize fails, confirm that the
session's AcodeIshTerminal still maps to the correct guest TTY. Confirm that
the active socket sends binary input frames or resize JSON. Also verify that
the generated plugin copy contains the current IshTerminalBridge.m.

### WebSocket failures

Check the control/data sequence:

~~~text
spawn callback contains both port and sessionId
WebSocket URL uses 127.0.0.1 and the returned port
binaryType is configured for array-buffer output
AttachAddon is attached after the socket opens
reconnect uses the original sessionId
stop is called only for explicit termination
~~~

If text is corrupted, check whether the legacy NSISOLatin1StringEncoding callback
was used accidentally. The streaming path should deliver raw binary frames.

## 12. Verification Matrix

~~~text
source:
  git diff --check and linker/symbol search

host iSH:
  meson test -C third_party/ish-arm64/build-host-arm64

rootfs:
  uname -m, required commands, SQLite integrity

iOS archives:
  iphoneos and iphonesimulator static archives

app boot:
  native logs and shell prompt

input/output:
  typed input, ANSI output, and Ctrl-C

resize:
  change xterm dimensions and inspect stty size

reconnect:
  close the socket without stopping the session

stop:
  terminate from the UI and verify cleanup

concurrency:
  run two sessions and verify isolated UUID/PID state
~~~

An end-to-end manual smoke test inside the iOS app is:

~~~sh
printf 'hello from iSH\n'
pwd
uname -m
stty size
sleep 30
~~~

While sleep is active, send Ctrl-C, resize the terminal, disconnect and
reconnect the UI, then stop the session. Expected architecture is aarch64 and
the shell should return to the prompt after Ctrl-C.

## 13. Contracts to Preserve

When changing this runtime, preserve these contracts unless the change is
intentional and tested end to end:

~~~text
ARM64 guest userspace matches the ARM64 iSH runtime.
FakeFS metadata and backing data are promoted together.
Kernel operations stay serialized on the iSH kernel queue.
PTY input/output remains byte-oriented at the native boundary.
Resize is an explicit TTY operation, not shell input.
WebSocket disconnect does not implicitly destroy a live session.
Explicit stop destroys the native session and guest task.
Generated Cordova copies are refreshed after plugin source changes.
~~~

The safest debugging method is to identify the first boundary that loses the
expected state or bytes, then inspect only the code and generated artifact for
that boundary. A prompt failure, Unicode corruption, and reconnect failure are
different bugs even though they appear in the same terminal UI.
