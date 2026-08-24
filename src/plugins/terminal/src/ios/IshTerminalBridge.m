#import "AcodeIshTerminal.h"

#define ISH_INTERNAL 1
#include "fs/devices.h"
#include "fs/tty.h"
#include "kernel/errno.h"
#include "kernel/signal.h"

@interface AcodeIshTerminal () {
    struct tty *_tty;
    /** Bytes produced while no outputHandler was attached. Capped; oldest
     * bytes are dropped. Guarded by pendingOutputLock. */
    NSMutableData *_pendingOutput;
    NSLock *_pendingOutputLock;
}
@property (nonatomic, readwrite) NSUUID *uuid;
@end

static const NSUInteger AcodeIshMaxPendingOutput = 256 * 1024;

@implementation AcodeIshTerminal

static int acode_tty_init(struct tty *tty) {
    AcodeIshTerminal *terminal = [[AcodeIshTerminal alloc] init];
    terminal->_tty = tty;
    terminal->_pendingOutput = [NSMutableData data];
    terminal->_pendingOutputLock = [NSLock new];
    tty->data = (void *)CFBridgingRetain(terminal);
    return 0;
}

static int acode_tty_write(struct tty *tty, const void *buffer, size_t length, bool blocking) {
    (void)blocking;
    AcodeIshTerminal *terminal = (__bridge AcodeIshTerminal *)tty->data;
    AcodeIshTerminalOutputHandler handler = terminal.outputHandler;
    if (length == 0) return 0;
    if (handler) {
        handler([NSData dataWithBytes:buffer length:length]);
    } else {
        // No consumer yet (guest booted faster than the WebSocket attach).
        // Buffer so a shell banner or first prompt is not silently dropped.
        [terminal->_pendingOutputLock lock];
        [terminal->_pendingOutput appendBytes:buffer length:length];
        NSUInteger overflow = terminal->_pendingOutput.length - AcodeIshMaxPendingOutput;
        if (overflow > 0) {
            [terminal->_pendingOutput replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
        }
        [terminal->_pendingOutputLock unlock];
    }
    return (int)length;
}

static void acode_tty_cleanup(struct tty *tty) {
    AcodeIshTerminal *terminal = CFBridgingRelease(tty->data);
    tty->data = NULL;
    terminal->_tty = NULL;
}

static struct tty_driver_ops acode_tty_ops = {
    .init = acode_tty_init,
    .write = acode_tty_write,
    .cleanup = acode_tty_cleanup,
};

static struct tty_driver acode_pty_driver = {
    .ops = &acode_tty_ops,
};

static struct tty_driver acode_console_driver = {
    .ops = &acode_tty_ops,
};

void AcodeIshInstallConsoleDriver(void) {
    acode_console_driver.major = TTY_CONSOLE_MAJOR;
    acode_console_driver.limit = 64;
    acode_console_driver.ttys = calloc(acode_console_driver.limit, sizeof(*acode_console_driver.ttys));
    tty_drivers[TTY_CONSOLE_MAJOR] = &acode_console_driver;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _uuid = [NSUUID UUID];
        _pendingOutput = [NSMutableData data];
        _pendingOutputLock = [NSLock new];
    }
    return self;
}

- (void)setOutputHandler:(AcodeIshTerminalOutputHandler)outputHandler {
    // Attach the new consumer before draining so bytes produced during the
    // drain are streamed directly instead of re-entering the buffer.
    _outputHandler = outputHandler;
    if (!outputHandler) return;
    [_pendingOutputLock lock];
    NSMutableData *drain = _pendingOutput;
    _pendingOutput = [NSMutableData data];
    [_pendingOutputLock unlock];
    if (drain.length > 0) outputHandler(drain);
}

+ (instancetype)createPseudoTerminal:(struct tty **)tty {
    if (!tty) return nil;
    *tty = pty_open_fake(&acode_pty_driver);
    if (IS_ERR(*tty)) return nil;
    return (__bridge AcodeIshTerminal *)(*tty)->data;
}

- (void)sendInput:(NSData *)input {
    struct tty *tty = _tty;
    if (!tty || input.length == 0) return;
    tty_input(tty, input.bytes, input.length, false);
}

- (void)resizeToColumns:(int)columns rows:(int)rows {
    struct tty *tty = _tty;
    if (!tty) return;
    lock(&tty->lock);
    tty_set_winsize(tty, (struct winsize_){.col = columns, .row = rows});
    unlock(&tty->lock);
}

- (void)terminateGuest {
    // tty_hangup only wakes readers/pollers; it never signals guest processes
    // (fs/tty.c), so an explicit stop must raise SIGHUP itself or the shell
    // leaks as an invisible running task.
    struct tty *tty = _tty;
    pid_t_ fgGroup = 0;
    if (tty) {
        lock(&tty->lock);
        fgGroup = tty->fg_group;
        unlock(&tty->lock);
    }
    // fg_group is copied out first because send_group_signal takes pids_lock;
    // calling it under tty->lock would invert the kernel's lock ordering
    // (signal delivery paths take pids_lock and may touch ttys afterwards).
    if (fgGroup != 0)
        send_group_signal(fgGroup, SIGHUP_, SIGINFO_NIL);
    // Fallback for sessions whose controlling-tty setup failed but whose
    // leader is still alive. The session task is its own session leader
    // (task_setsid in construct_task), so the pid doubles as the pgid.
    if (_sessionLeaderPid > 1 && (pid_t_)_sessionLeaderPid != fgGroup)
        send_group_signal((dword_t)_sessionLeaderPid, SIGHUP_, SIGINFO_NIL);
}

- (void)destroy {
    struct tty *tty = _tty;
    if (!tty) return;
    lock(&tty->lock);
    tty_hangup(tty);
    unlock(&tty->lock);
    self.outputHandler = nil;
}

@end
