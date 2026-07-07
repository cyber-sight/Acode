#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <pthread.h>

#ifndef ISH_LINUX
#define ISH_LINUX 1
#endif

#if __has_include("ish/include/LinuxInterop.h")
#import "ish/include/LinuxInterop.h"
#import "ish/include/Terminal.h"
#elif __has_include("LinuxInterop.h")
#import "LinuxInterop.h"
#import "Terminal.h"
#else
#define ACODE_ISH_HEADERS_MISSING 1
#endif

#ifndef ACODE_ISH_HEADERS_MISSING

@interface Terminal ()
@property (nonatomic, strong) NSUUID *uuid;
@property (nonatomic, assign) struct linux_tty *linuxTTY;
@property (nonatomic, assign) BOOL loaded;
- (int)roomForOutput;
- (void)setTty:(struct linux_tty *)tty;
@end

@implementation Terminal

static const int AcodeTerminalBufferSize = 1 << 20;
static NSMapTable<NSNumber *, Terminal *> *acodeTerminalsByKey;
static NSMapTable<NSUUID *, Terminal *> *acodeTerminalsByUUID;

+ (void)initialize {
    if (self == Terminal.class) {
        acodeTerminalsByKey = [NSMapTable strongToWeakObjectsMapTable];
        acodeTerminalsByUUID = [NSMapTable strongToWeakObjectsMapTable];
    }
}

+ (Terminal *)terminalWithType:(int)type number:(int)number {
    NSNumber *key = @(((type & 0xffff) << 16) | (number & 0xffff));
    @synchronized (Terminal.class) {
        Terminal *terminal = [acodeTerminalsByKey objectForKey:key];
        if (terminal) {
            return terminal;
        }

        terminal = [[Terminal alloc] init];
        terminal.uuid = [NSUUID UUID];
        [acodeTerminalsByKey setObject:terminal forKey:key];
        [acodeTerminalsByUUID setObject:terminal forKey:terminal.uuid];
        return terminal;
    }
}

+ (Terminal *)terminalWithUUID:(NSUUID *)uuid {
    if (!uuid) {
        return nil;
    }
    @synchronized (Terminal.class) {
        return [acodeTerminalsByUUID objectForKey:uuid];
    }
}

+ (void)convertCommand:(NSArray<NSString *> *)command toArgs:(char *)argv limitSize:(size_t)maxSize {
    if (!argv || maxSize == 0) {
        return;
    }

    NSString *joined = [command componentsJoinedByString:@" "];
    NSData *data = [joined dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    size_t len = MIN(data.length, maxSize - 1);
    memcpy(argv, data.bytes, len);
    argv[len] = '\0';
}

- (int)sendOutput:(const void *)buf length:(int)len {
    if (!buf || len <= 0) {
        return 0;
    }
    return len;
}

- (int)roomForOutput {
    return AcodeTerminalBufferSize;
}

- (void)sendInput:(NSData *)input {
    if (!input.length || _linuxTTY == NULL) {
        return;
    }

    NSData *inputRef = [input copy];
    struct linux_tty *tty = _linuxTTY;
    async_do_in_workqueue(^{
        if (tty && tty->ops && tty->ops->send_input) {
            tty->ops->send_input(tty, inputRef.bytes, inputRef.length);
        }
    });
}

- (NSString *)arrow:(char)direction {
    return [NSString stringWithFormat:@"\x1b[%c", direction];
}

- (void)destroy {
    struct linux_tty *tty = _linuxTTY;
    _linuxTTY = NULL;
    if (tty && tty->ops && tty->ops->hangup) {
        async_do_in_workqueue(^{
            tty->ops->hangup(tty);
        });
    }

    @synchronized (Terminal.class) {
        if (self.uuid) {
            [acodeTerminalsByUUID removeObjectForKey:self.uuid];
        }
    }
}

- (WKWebView *)webView {
    return nil;
}

- (void)setEnableVoiceOverAnnounce:(BOOL)enableVoiceOverAnnounce {
    _enableVoiceOverAnnounce = enableVoiceOverAnnounce;
}

- (void)setTty:(struct linux_tty *)tty {
    @synchronized (self) {
        _linuxTTY = tty;
    }
}

@end

void async_do_in_ios(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

void ConsoleLog(const char *data, unsigned len) {
    NSLog(@"%.*s", (int)len, data);
}

void FsInitialize(void) {
}

int initrd_below_start_ok = 0;
unsigned long initrd_start = 0;
unsigned long initrd_end = 0;
unsigned int real_root_dev = 0;

bool initrd_load(void) {
    return false;
}

void wait_for_initramfs(void) {
}

int unzstd(unsigned char *inbuf, long len, long (*fill)(void *, unsigned long),
           long (*flush)(void *, unsigned long), unsigned char *outbuf,
           long *pos, void (*error)(char *x)) {
    if (error) {
        error("zstd initramfs decompression is not available");
    }
    return -1;
}

nsobj_t objc_get(nsobj_t object) {
    if (object) {
        CFRetain(object);
    }
    return object;
}

void objc_put(nsobj_t object) {
    if (object) {
        CFRelease(object);
    }
}

void sync_do_in_workqueue(void (^block)(void (^done)(void))) {
    __block pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    __block pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
    __block BOOL doneFlag = NO;

    async_do_in_workqueue(^{
        block(^{
            pthread_mutex_lock(&mutex);
            doneFlag = YES;
            pthread_mutex_unlock(&mutex);
            pthread_cond_broadcast(&cond);
        });
    });

    pthread_mutex_lock(&mutex);
    while (!doneFlag) {
        pthread_cond_wait(&cond, &mutex);
    }
    pthread_mutex_unlock(&mutex);
}

long UIPasteboard_changeCount(void) {
    return UIPasteboard.generalPasteboard.changeCount;
}

nsobj_t UIPasteboard_get(void) {
    NSData *data = [UIPasteboard.generalPasteboard.string dataUsingEncoding:NSUTF8StringEncoding];
    return (__bridge_retained nsobj_t)data;
}

void UIPasteboard_set(const char *data, size_t len) {
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithBytes:data length:len encoding:NSUTF8StringEncoding] ?: @"";
}

size_t NSData_length(nsobj_t data) {
    return [(__bridge NSData *)data length];
}

const void *NSData_bytes(nsobj_t data) {
    return [(__bridge NSData *)data bytes];
}

nsobj_t Terminal_terminalWithType_number(int type, int number) {
    return (__bridge_retained nsobj_t)[Terminal terminalWithType:type number:number];
}

void Terminal_setLinuxTTY(nsobj_t _self, struct linux_tty *tty) {
    [(__bridge Terminal *)_self setTty:tty];
}

int Terminal_sendOutput_length(nsobj_t _self, const char *data, int size) {
    return [(__bridge Terminal *)_self sendOutput:data length:size];
}

int Terminal_roomForOutput(nsobj_t _self) {
    return [(__bridge Terminal *)_self roomForOutput];
}

#endif
