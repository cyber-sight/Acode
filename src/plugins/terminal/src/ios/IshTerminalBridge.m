#import "AcodeIshTerminal.h"

#define ISH_INTERNAL 1
#include "fs/devices.h"
#include "fs/tty.h"
#include "kernel/errno.h"

@interface AcodeIshTerminal () {
    struct tty *_tty;
}
@property (nonatomic, readwrite) NSUUID *uuid;
@end

@implementation AcodeIshTerminal

static int acode_tty_init(struct tty *tty) {
    AcodeIshTerminal *terminal = [[AcodeIshTerminal alloc] init];
    terminal->_tty = tty;
    tty->data = (void *)CFBridgingRetain(terminal);
    return 0;
}

static int acode_tty_write(struct tty *tty, const void *buffer, size_t length, bool blocking) {
    (void)blocking;
    AcodeIshTerminal *terminal = (__bridge AcodeIshTerminal *)tty->data;
    AcodeIshTerminalOutputHandler handler = terminal.outputHandler;
    if (handler && length > 0) {
        handler([NSData dataWithBytes:buffer length:length]);
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
    }
    return self;
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

- (void)destroy {
    struct tty *tty = _tty;
    if (!tty) return;
    lock(&tty->lock);
    tty_hangup(tty);
    unlock(&tty->lock);
    self.outputHandler = nil;
}

@end
