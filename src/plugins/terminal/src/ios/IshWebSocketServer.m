#import "IshWebSocketServer.h"
#import "AcodeIshTerminal.h"
#import "IshBridge.h"
#import <CommonCrypto/CommonCrypto.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const IshWSErrorDomain = @"IshWebSocketServer";
static const NSUInteger IshWSMaxHTTPHeader = 16 * 1024;
static const NSUInteger IshWSMaxMessage = 4 * 1024 * 1024;
static const NSUInteger IshWSOutputBatch = 16 * 1024;
static const NSUInteger IshWSMaxOutputBacklog = 1024 * 1024;
static const NSTimeInterval IshWSFlushInterval = 1.0 / 60.0;
// Overall deadline for a single writeData call. Without it, a half-open
// client socket (common after iOS app suspension drops the peer without a
// FIN) makes select() spin on EAGAIN forever and wedges the serial server
// queue, so later reconnects are refused and the session is bricked.
static const NSTimeInterval IshWSWriteDeadline = 5.0;
// Aggressive TCP keepalive for loopback clients: after iOS suspension the
// WebView side can vanish without a FIN; keepalive probes let the kernel
// detect the dead peer (idle 10s, probe every 5s, 3 failures) instead of
// leaving a zombie connection occupying the single client slot.
static const int IshWSKeepAliveIdle = 10;
static const int IshWSKeepAliveInterval = 5;
static const int IshWSKeepAliveCount = 3;

static NSString *WSAcceptValue(NSString *key) {
    NSData *source = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]
        dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(source.bytes, (CC_LONG)source.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}

static NSData *WSFrame(uint8_t opcode, NSData *payload) {
    payload = payload ?: NSData.data;
    uint64_t length = payload.length;
    uint8_t header[10] = { (uint8_t)(0x80 | opcode), 0 };
    NSUInteger headerLength = 2;
    if (length <= 125) {
        header[1] = (uint8_t)length;
    } else if (length <= UINT16_MAX) {
        header[1] = 126;
        uint16_t value = CFSwapInt16HostToBig((uint16_t)length);
        memcpy(header + 2, &value, sizeof(value));
        headerLength = 4;
    } else {
        header[1] = 127;
        uint64_t value = CFSwapInt64HostToBig(length);
        memcpy(header + 2, &value, sizeof(value));
        headerLength = 10;
    }
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:headerLength];
    [frame appendData:payload];
    return frame;
}

@interface IshWebSocketServer ()
@property (nonatomic, readwrite) in_port_t port;
@property (nonatomic, strong) AcodeIshTerminal *terminal;
@property (nonatomic) int serverFd;
@property (nonatomic) int clientFd;
@property (nonatomic, strong) dispatch_queue_t queue;
// Serializes tty-bound input/resize calls off the WS read loop so they never
// race the IshBridge kernelQueue boot/stop paths with concurrent delivery.
@property (nonatomic, strong) dispatch_queue_t inputQueue;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) dispatch_source_t flushTimer;
@property (nonatomic, strong) NSMutableData *inputBuffer;
@property (nonatomic, strong) NSMutableData *outputBuffer;
@property (nonatomic, strong) NSMutableData *fragmentBuffer;
@property (nonatomic) uint8_t fragmentOpcode;
@property (nonatomic) BOOL upgraded;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL stopping;
@property (nonatomic) BOOL disconnectNotified;
@property (nonatomic, copy, nullable) AcodeIshTerminalOutputHandler installedOutputHandler;
@end

@implementation IshWebSocketServer

- (BOOL)isRunning {
    return self.started && !self.stopping && self.serverFd >= 0;
}

- (instancetype)initWithTerminal:(AcodeIshTerminal *)terminal {
    self = [super init];
    if (self) {
        _terminal = terminal;
        _serverFd = -1;
        _clientFd = -1;
        _queue = dispatch_queue_create("com.foxdebug.acode.ish-websocket", DISPATCH_QUEUE_SERIAL);
        _inputQueue = dispatch_queue_create("com.foxdebug.acode.ish-websocket-input", DISPATCH_QUEUE_SERIAL);
        _inputBuffer = NSMutableData.data;
        _outputBuffer = NSMutableData.data;
        _fragmentBuffer = NSMutableData.data;
    }
    return self;
}

- (void)dealloc {
    [self clearOutputHandlerIfOwned];
    if (_clientFd >= 0) close(_clientFd);
    if (_serverFd >= 0) close(_serverFd);
}

- (void)clearOutputHandlerIfOwned {
    // A replacement server may already own the same terminal. Clearing the
    // property unconditionally from an old server's stop/dealloc path would
    // disconnect the replacement listener from all future PTY output.
    AcodeIshTerminalOutputHandler installed = self.installedOutputHandler;
    if (installed && self.terminal.outputHandler == installed) {
        self.terminal.outputHandler = nil;
    }
    self.installedOutputHandler = nil;
}

- (NSError *)socketError:(NSInteger)code operation:(NSString *)operation {
    NSString *reason = [NSString stringWithUTF8String:strerror(errno)] ?: @"Unknown socket error";
    return [NSError errorWithDomain:IshWSErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", operation, reason]
    }];
}

- (BOOL)startWithError:(NSError **)error {
    if (self.started) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [self socketError:1 operation:@"Unable to create WebSocket socket"];
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(fd, 8) < 0) {
        if (error) *error = [self socketError:2 operation:@"Unable to bind WebSocket socket"];
        close(fd);
        return NO;
    }
    socklen_t addressLength = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &addressLength) < 0) {
        if (error) *error = [self socketError:3 operation:@"Unable to read WebSocket port"];
        close(fd);
        return NO;
    }

    self.serverFd = fd;
    self.port = ntohs(address.sin_port);
    self.started = YES;
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self.queue);
    if (!self.acceptSource) {
        if (error) *error = [NSError errorWithDomain:IshWSErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"Unable to create WebSocket accept source"
        }];
        close(fd);
        self.serverFd = -1;
        self.started = NO;
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.acceptSource, ^{ [weakSelf acceptConnections]; });
    dispatch_resume(self.acceptSource);

    self.flushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.flushTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(IshWSFlushInterval * NSEC_PER_SEC)),
        (uint64_t)(IshWSFlushInterval * NSEC_PER_SEC), NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.flushTimer, ^{ [weakSelf flushTerminalOutput]; });
    dispatch_resume(self.flushTimer);

    AcodeIshTerminalOutputHandler outputHandler = ^(NSData *data) {
        if (!data.length) return;
        dispatch_async(weakSelf.queue, ^{
            if (weakSelf.stopping) return;
            [weakSelf.outputBuffer appendData:data];
            if (weakSelf.outputBuffer.length > IshWSMaxOutputBacklog) {
                NSUInteger overflow = weakSelf.outputBuffer.length - IshWSMaxOutputBacklog;
                [weakSelf.outputBuffer replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
            }
        });
    };
    self.installedOutputHandler = outputHandler;
    self.terminal.outputHandler = outputHandler;
    NSLog(@"[WS] session server listening on 127.0.0.1:%u", self.port);
    return YES;
}

- (void)stop {
    [self clearOutputHandlerIfOwned];
    dispatch_async(self.queue, ^{
        if (self.stopping) return;
        self.stopping = YES;
        if (self.upgraded && self.clientFd >= 0) [self writeData:WSFrame(0x8, NSData.data)];
        [self closeClientNotifying:NO];
        if (self.acceptSource) {
            dispatch_source_cancel(self.acceptSource);
            self.acceptSource = nil;
        }
        if (self.flushTimer) {
            dispatch_source_cancel(self.flushTimer);
            self.flushTimer = nil;
        }
        if (self.serverFd >= 0) {
            close(self.serverFd);
            self.serverFd = -1;
        }
        self.started = NO;
    });
}

- (void)sendControlFrame:(NSData *)data {
    if (!data.length) return;
    // Runs on the server queue so it is ordered before any later -stop call
    // made from the same thread. Buffered PTY output is flushed first so the
    // final output bytes reach the client ahead of the control frame.
    dispatch_async(self.queue, ^{
        if (self.stopping || !self.upgraded || self.clientFd < 0) return;
        [self flushTerminalOutput];
        [self writeData:WSFrame(0x1, data)];
    });
}

- (NSData *)drainOutputBuffer {
    // Synchronous hop onto the server queue: the caller (Executor reconnect
    // path, main thread) needs the bytes before installing a replacement
    // server. Must not be called from self.queue itself.
    __block NSData *drained = nil;
    dispatch_sync(self.queue, ^{
        drained = self.outputBuffer.length ? [self.outputBuffer copy] : nil;
        [self.outputBuffer setLength:0];
    });
    return drained;
}

- (void)primeOutputBuffer:(NSData *)data {
    if (!data.length) return;
    dispatch_async(self.queue, ^{
        if (self.stopping) return;
        // Apply the same backlog bound as live PTY output so a huge stale
        // backlog cannot blow native memory; oldest bytes are dropped first.
        [self.outputBuffer appendData:data];
        if (self.outputBuffer.length > IshWSMaxOutputBacklog) {
            NSUInteger overflow = self.outputBuffer.length - IshWSMaxOutputBacklog;
            [self.outputBuffer replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
        }
    });
}

- (void)rejectConnection:(int)fd {
    static const char busy[] = "HTTP/1.1 409 Conflict\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    send(fd, busy, sizeof(busy) - 1, 0);
    close(fd);
}

// Enable aggressive TCP keepalive on a freshly accepted client so a peer lost
// to iOS suspension is reaped by the kernel instead of occupying the single
// client slot until a write stalls.
- (void)applyClientKeepAlive:(int)fd {
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes)) < 0) return;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &IshWSKeepAliveIdle, sizeof(IshWSKeepAliveIdle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &IshWSKeepAliveInterval, sizeof(IshWSKeepAliveInterval));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &IshWSKeepAliveCount, sizeof(IshWSKeepAliveCount));
}

- (void)acceptConnections {
    while (!self.stopping) {
        int fd = accept(self.serverFd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                NSLog(@"[WS] listener failed for session %@: %s", self.sessionId ?: @"unknown", strerror(errno));
                self.started = NO;
            }
            return;
        }
        if (self.clientFd >= 0) {
            // Wire contract: when a second client connects while one client
            // holds the slot, the old client is replaced WITHOUT its
            // disconnectHandler firing and the newcomer proceeds through the
            // upgrade handshake. WebView suspension can orphan the previous
            // TCP link without a FIN, so the new connect IS the reconnect;
            // answering 409 here would brick the session behind a dead peer.
            // The legacy 409 is kept only when more than one candidate races
            // for the slot simultaneously, which is genuinely ambiguous.
            int rival = -1;
            do {
                rival = accept(self.serverFd, NULL, NULL);
            } while (rival < 0 && errno == EINTR);
            if (rival >= 0) {
                NSLog(@"[WS] multiple clients racing for session %@; rejecting extras with 409", self.sessionId ?: @"unknown");
                [self rejectConnection:fd];
                [self rejectConnection:rival];
                continue;
            }
            NSLog(@"[WS] replacing stale client for session %@", self.sessionId ?: @"unknown");
            // Not notifying: no disconnect happened from JS's point of view,
            // a replacement connection is arriving right now.
            [self closeClientNotifying:NO];
        }
#ifdef SO_NOSIGPIPE
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
        [self applyClientKeepAlive:fd];
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        self.clientFd = fd;
        self.upgraded = NO;
        self.disconnectNotified = NO;
        [self.inputBuffer setLength:0];
        [self.fragmentBuffer setLength:0];
        self.fragmentOpcode = 0;
        [self beginReadingClient];
    }
}

- (void)beginReadingClient {
    self.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self.clientFd, 0, self.queue);
    if (!self.readSource) {
        [self closeClientNotifying:YES];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.readSource, ^{ [weakSelf readClient]; });
    dispatch_resume(self.readSource);
}

- (void)readClient {
    uint8_t bytes[64 * 1024];
    while (self.clientFd >= 0) {
        ssize_t count = recv(self.clientFd, bytes, sizeof(bytes), 0);
        if (count > 0) {
            [self.inputBuffer appendBytes:bytes length:(NSUInteger)count];
            if (!self.upgraded) {
                if (![self processUpgrade]) return;
            }
            if (self.upgraded) while ([self processFrame]) {}
            continue;
        }
        if (count == 0) [self closeClientNotifying:YES];
        else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) [self closeClientNotifying:YES];
        return;
    }
}

- (BOOL)processUpgrade {
    NSData *terminator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange range = [self.inputBuffer rangeOfData:terminator options:0 range:NSMakeRange(0, self.inputBuffer.length)];
    if (range.location == NSNotFound) {
        if (self.inputBuffer.length > IshWSMaxHTTPHeader) [self failUpgrade:@"431 Request Header Fields Too Large"];
        return NO;
    }
    NSUInteger headerLength = NSMaxRange(range);
    NSString *request = [[NSString alloc] initWithBytes:self.inputBuffer.bytes length:headerLength encoding:NSUTF8StringEncoding];
    if (!request) {
        [self failUpgrade:@"400 Bad Request"];
        return NO;
    }
    NSArray<NSString *> *lines = [request componentsSeparatedByString:@"\r\n"];
    NSMutableDictionary<NSString *, NSString *> *headers = NSMutableDictionary.dictionary;
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSRange colon = [lines[index] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[lines[index] substringToIndex:colon.location] lowercaseString];
        headers[name] = [[lines[index] substringFromIndex:NSMaxRange(colon)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    NSString *upgrade = headers[@"upgrade"].lowercaseString;
    NSString *connection = headers[@"connection"].lowercaseString;
    NSString *key = headers[@"sec-websocket-key"];
    BOOL valid = [lines.firstObject hasPrefix:@"GET "] && [upgrade isEqualToString:@"websocket"] &&
        [connection containsString:@"upgrade"] && [headers[@"sec-websocket-version"] isEqualToString:@"13"] &&
        key.length > 0;
    if (!valid) {
        [self failUpgrade:@"400 Bad Request"];
        return NO;
    }
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
        WSAcceptValue(key)];
    if (![self writeData:[response dataUsingEncoding:NSASCIIStringEncoding]]) {
        [self closeClientNotifying:YES];
        return NO;
    }
    [self.inputBuffer replaceBytesInRange:NSMakeRange(0, headerLength) withBytes:NULL length:0];
    self.upgraded = YES;
    NSLog(@"[WS] client upgraded for session %@", self.sessionId ?: @"unknown");
    return YES;
}

- (void)failUpgrade:(NSString *)status {
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", status];
    [self writeData:[response dataUsingEncoding:NSASCIIStringEncoding]];
    [self closeClientNotifying:YES];
}

- (BOOL)processFrame {
    if (self.inputBuffer.length < 2) return NO;
    const uint8_t *bytes = self.inputBuffer.bytes;
    BOOL fin = (bytes[0] & 0x80) != 0;
    BOOL hasReservedBits = (bytes[0] & 0x70) != 0;
    uint8_t opcode = bytes[0] & 0x0f;
    BOOL masked = (bytes[1] & 0x80) != 0;
    uint64_t length = bytes[1] & 0x7f;
    NSUInteger offset = 2;
    if (length == 126) {
        if (self.inputBuffer.length < 4) return NO;
        uint16_t value; memcpy(&value, bytes + 2, 2);
        length = CFSwapInt16BigToHost(value); offset = 4;
    } else if (length == 127) {
        if (self.inputBuffer.length < 10) return NO;
        uint64_t value; memcpy(&value, bytes + 2, 8);
        length = CFSwapInt64BigToHost(value); offset = 10;
        if (length & (1ULL << 63)) return [self protocolError:1002];
    }
    BOOL control = (opcode & 0x08) != 0;
    if (hasReservedBits || !masked || (control && (!fin || length > 125)) || length > IshWSMaxMessage)
        return [self protocolError:length > IshWSMaxMessage ? 1009 : 1002];
    if (self.inputBuffer.length < offset + 4 || length > NSUIntegerMax - offset - 4 ||
        self.inputBuffer.length < offset + 4 + (NSUInteger)length) return NO;
    uint8_t mask[4]; memcpy(mask, bytes + offset, 4); offset += 4;
    NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)length];
    uint8_t *decoded = payload.mutableBytes;
    for (NSUInteger index = 0; index < (NSUInteger)length; index++) decoded[index] = bytes[offset + index] ^ mask[index % 4];
    [self.inputBuffer replaceBytesInRange:NSMakeRange(0, offset + (NSUInteger)length) withBytes:NULL length:0];

    if (opcode == 0x8) {
        uint16_t closeCode = 1005;
        if (payload.length >= 2) {
            memcpy(&closeCode, payload.bytes, 2);
            closeCode = CFSwapInt16BigToHost(closeCode);
        }
        NSLog(@"[WS] peer sent close code %u for session %@", closeCode, self.sessionId ?: @"unknown");
        [self writeData:WSFrame(0x8, payload)];
        [self closeClientNotifying:YES];
        return NO;
    }
    if (opcode == 0x9) { [self writeData:WSFrame(0xA, payload)]; return YES; }
    if (opcode == 0xA) return YES;
    if (opcode == 0x0) {
        if (!self.fragmentOpcode || self.fragmentBuffer.length + payload.length > IshWSMaxMessage) return [self protocolError:1002];
        [self.fragmentBuffer appendData:payload];
        if (fin) {
            [self deliverPayload:self.fragmentBuffer opcode:self.fragmentOpcode];
            [self.fragmentBuffer setLength:0]; self.fragmentOpcode = 0;
        }
        return YES;
    }
    if (opcode != 0x1 && opcode != 0x2) return [self protocolError:1002];
    if (self.fragmentOpcode) return [self protocolError:1002];
    if (!fin) {
        self.fragmentOpcode = opcode;
        [self.fragmentBuffer setData:payload];
    } else {
        [self deliverPayload:payload opcode:opcode];
    }
    return YES;
}

- (BOOL)protocolError:(uint16_t)code {
    uint16_t networkCode = CFSwapInt16HostToBig(code);
    [self writeData:WSFrame(0x8, [NSData dataWithBytes:&networkCode length:2])];
    [self closeClientNotifying:YES];
    return NO;
}

// Input and resize are serialized on a dedicated internal queue so tty calls
// are issued off the WS read loop and cannot interleave with IshBridge's
// kernelQueue boot/stop paths mid-delivery. Text-input frames go through
// [[IshBridge shared] writeToSession:...] so they ride the kernelQueue like
// every other session mutation. Binary frames keep calling terminal.sendInput
// directly because writeToSession takes NSString, and an NSData -> UTF-8
// string round-trip can corrupt arbitrary (non-UTF-8) terminal bytes; the
// inputQueue still serializes those calls. This keeps tty invocation off the
// WS read loop while remaining byte-exact.
// TODO: route binary frames through kernelQueue too once IshBridge exposes a
// byte-level write API (e.g. writeToSessionData:).
- (void)deliverPayload:(NSData *)payload opcode:(uint8_t)opcode {
    if (self.stopping) return;
    if (opcode == 0x2) {
        NSData *input = [payload copy];
        dispatch_async(self.inputQueue, ^{
            if (self.stopping) return;
            [self.terminal sendInput:input];
        });
        return;
    }
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
    if (!text) { [self protocolError:1007]; return; }
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if ([message isKindOfClass:NSDictionary.class] && [message[@"type"] isEqualToString:@"resize"]) {
        NSInteger columns = [message[@"cols"] integerValue];
        NSInteger rows = [message[@"rows"] integerValue];
        if (!(columns > 0 && rows > 0)) return;
        dispatch_async(self.inputQueue, ^{
            if (self.stopping) return;
            [self.terminal resizeToColumns:(int)columns rows:(int)rows];
        });
    } else {
        dispatch_async(self.inputQueue, ^{
            if (self.stopping) return;
            [[IshBridge shared] writeToSession:self.sessionId input:text completion:nil];
        });
    }
}

- (void)flushTerminalOutput {
    if (!self.upgraded || self.clientFd < 0 || !self.outputBuffer.length) return;
    NSUInteger length = MIN(self.outputBuffer.length, IshWSOutputBatch);
    NSData *payload = [self.outputBuffer subdataWithRange:NSMakeRange(0, length)];
    if ([self writeData:WSFrame(0x2, payload)])
        [self.outputBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    else
        [self closeClientNotifying:YES];
}

- (BOOL)writeData:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    // Overall per-call deadline: on a half-open socket EAGAIN persists
    // indefinitely after iOS suspension, so waiting forever wedges the
    // serial server queue and blocks reconnect handling. Give up after
    // IshWSWriteDeadline and let callers tear the client down.
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + IshWSWriteDeadline;
    while (remaining && self.clientFd >= 0) {
        ssize_t count = send(self.clientFd, bytes, remaining, 0);
        if (count > 0) { bytes += count; remaining -= (NSUInteger)count; continue; }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) {
                NSLog(@"[WS] write stalled past %.0fs for session %@; dropping client", IshWSWriteDeadline, self.sessionId ?: @"unknown");
                return NO;
            }
            struct timeval timeout = { .tv_sec = 0, .tv_usec = 100000 };
            fd_set set; FD_ZERO(&set); FD_SET(self.clientFd, &set);
            if (select(self.clientFd + 1, NULL, &set, NULL, &timeout) > 0) continue;
        }
        return NO;
    }
    return remaining == 0;
}

- (void)closeClientNotifying:(BOOL)notify {
    if (self.readSource) {
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
    }
    if (self.clientFd >= 0) { close(self.clientFd); self.clientFd = -1; }
    self.upgraded = NO;
    [self.inputBuffer setLength:0];
    [self.fragmentBuffer setLength:0];
    self.fragmentOpcode = 0;
    if (notify && !self.disconnectNotified) {
        self.disconnectNotified = YES;
        NSLog(@"[WS] client disconnected for session %@", self.sessionId ?: @"unknown");
        if (self.disconnectHandler) self.disconnectHandler();
    }
}

@end
