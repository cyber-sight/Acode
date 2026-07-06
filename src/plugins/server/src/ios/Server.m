#import "Server.h"
#import <Cordova/CDVPluginResult.h>
#import <GCDWebServer/GCDWebServer.h>
#import <GCDWebServer/GCDWebServerDataRequest.h>
#import <GCDWebServer/GCDWebServerDataResponse.h>
#import <GCDWebServer/GCDWebServerFileResponse.h>

@interface ServerInstance : NSObject
@property (nonatomic, strong) GCDWebServer *server;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *responses;
@property (nonatomic, strong) NSMutableDictionary<NSString *, dispatch_semaphore_t> *locks;
@property (nonatomic, copy) NSString *onRequestCallbackId;
@end

@implementation ServerInstance
@end

@interface Server ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ServerInstance *> *servers;
@end

@implementation Server

- (void)pluginInitialize {
    self.servers = [NSMutableDictionary dictionary];
}

- (void)start:(CDVInvokedUrlCommand *)command {
    NSNumber *port = command.arguments.count > 0 ? command.arguments[0] : @(8080);
    ServerInstance *instance = self.servers[port];
    if (instance) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[NSString stringWithFormat:@"Server started on port %@", port]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    instance = [[ServerInstance alloc] init];
    instance.responses = [NSMutableDictionary dictionary];
    instance.locks = [NSMutableDictionary dictionary];
    instance.server = [[GCDWebServer alloc] init];

    __weak typeof(self) weakSelf = self;
    [instance.server addDefaultHandlerForMethod:@"GET" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse * _Nullable(GCDWebServerRequest * _Nonnull request) {
        return [weakSelf handleRequest:request serverInstance:instance];
    }];
    [instance.server addDefaultHandlerForMethod:@"POST" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse * _Nullable(GCDWebServerRequest * _Nonnull request) {
        return [weakSelf handleRequest:request serverInstance:instance];
    }];
    [instance.server addDefaultHandlerForMethod:@"PUT" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse * _Nullable(GCDWebServerRequest * _Nonnull request) {
        return [weakSelf handleRequest:request serverInstance:instance];
    }];
    [instance.server addDefaultHandlerForMethod:@"DELETE" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse * _Nullable(GCDWebServerRequest * _Nonnull request) {
        return [weakSelf handleRequest:request serverInstance:instance];
    }];

    if ([instance.server startWithPort:port.unsignedIntegerValue bonjourName:nil]) {
        self.servers[port] = instance;
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[NSString stringWithFormat:@"Server started on port %@", port]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to start server"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }
}

- (void)setOnRequestHandler:(CDVInvokedUrlCommand *)command {
    NSNumber *port = command.arguments.count > 0 ? command.arguments[0] : @(8080);
    ServerInstance *instance = self.servers[port];
    if (!instance) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[NSString stringWithFormat:@"Server not started on port %@", port]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }
    instance.onRequestCallbackId = command.callbackId;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)stop:(CDVInvokedUrlCommand *)command {
    NSNumber *port = command.arguments.count > 0 ? command.arguments[0] : @(8080);
    ServerInstance *instance = self.servers[port];
    if (!instance) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[NSString stringWithFormat:@"Server not started on port %@", port]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }
    [instance.server stop];
    [self.servers removeObjectForKey:port];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)send:(CDVInvokedUrlCommand *)command {
    NSNumber *port = command.arguments.count > 0 ? command.arguments[0] : @(8080);
    NSString *requestId = command.arguments.count > 1 ? command.arguments[1] : @"";
    id response = command.arguments.count > 2 ? command.arguments[2] : @{};

    ServerInstance *instance = self.servers[port];
    if (!instance) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Server not running"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    if (requestId.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid request ID"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    instance.responses[requestId] = response;
    dispatch_semaphore_t sema = instance.locks[requestId];
    if (sema) {
        dispatch_semaphore_signal(sema);
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (GCDWebServerResponse *)handleRequest:(GCDWebServerRequest *)request serverInstance:(ServerInstance *)instance {
    NSString *requestId = [[NSUUID UUID] UUIDString];

    if (!instance.onRequestCallbackId) {
        return [GCDWebServerDataResponse responseWithText:@"No request handler registered"]; 
    }

    NSString *bodyString = @"";
    if ([request isKindOfClass:[GCDWebServerDataRequest class]]) {
        GCDWebServerDataRequest *dataRequest = (GCDWebServerDataRequest *)request;
        if (dataRequest.data.length > 0) {
            bodyString = [[NSString alloc] initWithData:dataRequest.data encoding:NSUTF8StringEncoding] ?: @"";
        }
    }

    NSDictionary *payload = @{
        @"requestId": requestId,
        @"body": bodyString ?: @"",
        @"headers": request.headers ?: @{},
        @"method": request.method ?: @"",
        @"path": request.path ?: @"",
        @"query": request.URL.query ?: @""
    };

    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
    [pluginResult setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:instance.onRequestCallbackId];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    instance.locks[requestId] = sema;
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    id responseObject = instance.responses[requestId];
    [instance.responses removeObjectForKey:requestId];
    [instance.locks removeObjectForKey:requestId];

    if (![responseObject isKindOfClass:[NSDictionary class]]) {
        return [GCDWebServerDataResponse responseWithText:@""];
    }

    NSDictionary *responseDict = (NSDictionary *)responseObject;
    NSString *path = responseDict[@"path"];
    NSDictionary *headers = responseDict[@"headers"];

    if (path.length > 0) {
        NSString *filePath = path;
        if ([filePath hasPrefix:@"file://"]) {
            NSURL *url = [NSURL URLWithString:filePath];
            filePath = url.path;
        }
        GCDWebServerFileResponse *fileResponse = [GCDWebServerFileResponse responseWithFile:filePath];
        if ([headers isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in headers) {
                [fileResponse setValue:headers[key] forAdditionalHeader:key];
            }
        }
        return fileResponse;
    }

    NSInteger status = [responseDict[@"status"] respondsToSelector:@selector(integerValue)] ? [responseDict[@"status"] integerValue] : 200;
    NSString *body = responseDict[@"body"] ?: @"";
    NSString *contentType = headers[@"Content-Type"] ?: @"text/plain";

    GCDWebServerDataResponse *dataResponse = [GCDWebServerDataResponse responseWithText:body];
    dataResponse.statusCode = status;
    dataResponse.contentType = contentType;

    if ([headers isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in headers) {
            [dataResponse setValue:headers[key] forAdditionalHeader:key];
        }
    }

    return dataResponse;
}

@end
