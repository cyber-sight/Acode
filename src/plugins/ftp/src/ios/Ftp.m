#import "Ftp.h"
#import <Cordova/CDVPluginResult.h>
#import <GRRequests/GRRequests.h>

@interface Ftp () <GRRequestsManagerDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, GRRequestsManager *> *managers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *workingDirectories;
@property (nonatomic, strong) NSMapTable<id<GRRequestProtocol>, CDVInvokedUrlCommand *> *requestMap;
@end

@implementation Ftp

- (void)pluginInitialize {
    self.managers = [NSMutableDictionary dictionary];
    self.workingDirectories = [NSMutableDictionary dictionary];
    self.requestMap = [NSMapTable weakToStrongObjectsMapTable];
}

- (NSString *)ftpIdForHost:(NSString *)host port:(NSNumber *)port username:(NSString *)username {
    return [NSString stringWithFormat:@"%@@%@:%@", username ?: @"", host ?: @"", port ?: @0];
}

- (GRRequestsManager *)managerForId:(NSString *)ftpId host:(NSString *)host port:(NSNumber *)port username:(NSString *)username password:(NSString *)password {
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        manager = [[GRRequestsManager alloc] initWithHostname:host user:username password:password];
        manager.delegate = self;
        if (port) {
            manager.port = port.intValue;
        }
        self.managers[ftpId] = manager;
    }
    return manager;
}

- (void)connect:(CDVInvokedUrlCommand *)command {
    NSString *host = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSNumber *port = command.arguments.count > 1 ? command.arguments[1] : @21;
    NSString *username = command.arguments.count > 2 ? command.arguments[2] : @"";
    NSString *password = command.arguments.count > 3 ? command.arguments[3] : @"";
    NSString *ftpId = [self ftpIdForHost:host port:port username:username];

    [self managerForId:ftpId host:host port:port username:username password:password];
    if (!self.workingDirectories[ftpId]) {
        self.workingDirectories[ftpId] = @"/";
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:ftpId];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)listDirectory:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *path = command.arguments.count > 1 ? command.arguments[1] : @"/";
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    GRListingRequest *request = [[GRListingRequest alloc] initWithPath:path];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)execCommand:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@""];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)isConnected:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    int status = manager ? 1 : 0;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:status];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)disconnect:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    [manager stopAndCancelAllRequests];
    [self.managers removeObjectForKey:ftpId];
    [self.workingDirectories removeObjectForKey:ftpId];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)downloadFile:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *remotePath = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSString *localPath = command.arguments.count > 2 ? command.arguments[2] : @"";

    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    NSURL *localURL = [NSURL URLWithString:localPath];
    if (!localURL || !localURL.isFileURL) {
        localURL = [NSURL fileURLWithPath:localPath];
    }

    GRDownloadRequest *request = [[GRDownloadRequest alloc] initWithPath:remotePath toLocalFile:localURL.path];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)uploadFile:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *localPath = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSString *remotePath = command.arguments.count > 2 ? command.arguments[2] : @"";

    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    NSURL *localURL = [NSURL URLWithString:localPath];
    if (!localURL || !localURL.isFileURL) {
        localURL = [NSURL fileURLWithPath:localPath];
    }

    GRUploadRequest *request = [[GRUploadRequest alloc] initWithLocalFile:localURL.path toRemotePath:remotePath];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)deleteFile:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *path = command.arguments.count > 1 ? command.arguments[1] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    GRDeleteRequest *request = [[GRDeleteRequest alloc] initWithPath:path];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)deleteDirectory:(CDVInvokedUrlCommand *)command {
    [self deleteFile:command];
}

- (void)createDirectory:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *path = command.arguments.count > 1 ? command.arguments[1] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    GRCreateDirectoryRequest *request = [[GRCreateDirectoryRequest alloc] initWithPath:path];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)createFile:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *path = command.arguments.count > 1 ? command.arguments[1] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    NSData *emptyData = [NSData data];
    GRUploadDataRequest *request = [[GRUploadDataRequest alloc] initWithData:emptyData toRemotePath:path];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)getStat:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *path = command.arguments.count > 1 ? command.arguments[1] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    GRListingRequest *request = [[GRListingRequest alloc] initWithPath:path];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)exists:(CDVInvokedUrlCommand *)command {
    [self getStat:command];
}

- (void)changeDirectory:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *path = command.arguments.count > 1 ? command.arguments[1] : @"/";
    self.workingDirectories[ftpId] = path;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)changeToParentDirectory:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *current = self.workingDirectories[ftpId] ?: @"/";
    NSString *parent = [current stringByDeletingLastPathComponent];
    if (parent.length == 0) {
        parent = @"/";
    }
    self.workingDirectories[ftpId] = parent;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)getWorkingDirectory:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *current = self.workingDirectories[ftpId] ?: @"/";
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:current];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)rename:(CDVInvokedUrlCommand *)command {
    NSString *ftpId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *oldPath = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSString *newPath = command.arguments.count > 2 ? command.arguments[2] : @"";
    GRRequestsManager *manager = self.managers[ftpId];
    if (!manager) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP client not found."] callbackId:command.callbackId];
        return;
    }

    GRRenameRequest *request = [[GRRenameRequest alloc] initWithPath:oldPath toNewPath:newPath];
    [self.requestMap setObject:command forKey:request];
    [manager addRequest:request];
    [manager startProcessingRequests];
}

- (void)getKeepAlive:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:0];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendNoOp:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

#pragma mark - GRRequestsManagerDelegate

- (void)requestsManager:(id)requestsManager didCompleteListingRequest:(id<GRRequestProtocol>)request listing:(NSArray *)listing {
    CDVInvokedUrlCommand *command = [self.requestMap objectForKey:request];
    if (!command) {
        return;
    }
    [self.requestMap removeObjectForKey:request];

    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *item in listing) {
        NSString *name = item[(NSString *)kCFFTPResourceName] ?: @"";
        NSNumber *type = item[(NSString *)kCFFTPResourceType];
        NSNumber *size = item[(NSString *)kCFFTPResourceSize] ?: @0;
        NSDate *date = item[(NSString *)kCFFTPResourceModDate];

        BOOL isDirectory = type && type.intValue == 4; // kCFFTPResourceTypeDirectory
        NSDictionary *fileInfo = @{
            @"name": name,
            @"length": size,
            @"url": name,
            @"isDirectory": @(isDirectory),
            @"isFile": @(!isDirectory),
            @"isLink": @NO,
            @"link": [NSNull null],
            @"lastModified": date ? @((long long)([date timeIntervalSince1970] * 1000)) : @0,
            @"canWrite": @YES,
            @"canRead": @YES
        };
        [files addObject:fileInfo];
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:files];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)requestsManager:(id)requestsManager didCompleteDownloadRequest:(id<GRRequestProtocol>)request {
    [self finishSimpleRequest:request successMessage:nil];
}

- (void)requestsManager:(id)requestsManager didCompleteUploadRequest:(id<GRRequestProtocol>)request {
    [self finishSimpleRequest:request successMessage:nil];
}

- (void)requestsManager:(id)requestsManager didCompleteCreateDirectoryRequest:(id<GRRequestProtocol>)request {
    [self finishSimpleRequest:request successMessage:nil];
}

- (void)requestsManager:(id)requestsManager didCompleteDeleteRequest:(id<GRRequestProtocol>)request {
    [self finishSimpleRequest:request successMessage:nil];
}

- (void)requestsManager:(id)requestsManager didCompleteRenameRequest:(id<GRRequestProtocol>)request {
    [self finishSimpleRequest:request successMessage:nil];
}

- (void)requestsManager:(id)requestsManager didFailRequest:(id<GRRequestProtocol>)request error:(NSError *)error {
    CDVInvokedUrlCommand *command = [self.requestMap objectForKey:request];
    if (!command) {
        return;
    }
    [self.requestMap removeObjectForKey:request];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Request failed"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)finishSimpleRequest:(id<GRRequestProtocol>)request successMessage:(NSString *)message {
    CDVInvokedUrlCommand *command = [self.requestMap objectForKey:request];
    if (!command) {
        return;
    }
    [self.requestMap removeObjectForKey:request];
    CDVPluginResult *result = message ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message] : [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
