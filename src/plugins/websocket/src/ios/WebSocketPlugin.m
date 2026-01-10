#import "WebSocketPlugin.h"
#import <Cordova/CDVPluginResult.h>

@interface WSClient : NSObject
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *task;
@property (nonatomic, copy) NSString *callbackId;
@property (nonatomic, copy) NSString *binaryType;
@end

@implementation WSClient
@end

@interface WebSocketPlugin () <NSURLSessionDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, WSClient *> *clients;
@end

@implementation WebSocketPlugin

- (void)pluginInitialize {
    self.clients = [NSMutableDictionary dictionary];
}

- (void)connect:(CDVInvokedUrlCommand *)command {
    NSString *urlString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSArray *protocols = command.arguments.count > 1 ? command.arguments[1] : nil;
    NSString *binaryType = command.arguments.count > 2 ? command.arguments[2] : @"";
    NSDictionary *headers = command.arguments.count > 3 ? command.arguments[3] : nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid URL"] callbackId:command.callbackId];
        return;
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    if ([headers isKindOfClass:[NSDictionary class]]) {
        config.HTTPAdditionalHeaders = headers;
    }
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    NSURLSessionWebSocketTask *task = nil;
    if ([protocols isKindOfClass:[NSArray class]] && protocols.count > 0) {
        task = [session webSocketTaskWithURL:url protocols:protocols];
    } else {
        task = [session webSocketTaskWithURL:url];
    }

    NSString *instanceId = [[NSUUID UUID] UUIDString];
    WSClient *client = [[WSClient alloc] init];
    client.session = session;
    client.task = task;
    client.binaryType = binaryType ?: @"";

    self.clients[instanceId] = client;

    [task resume];
    [self startReceiveLoopForClient:client instanceId:instanceId];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:instanceId];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];

    [self sendEventToClient:client type:@"open" instanceId:instanceId payload:@{}];
}

- (void)registerListener:(CDVInvokedUrlCommand *)command {
    NSString *instanceId = command.arguments.count > 0 ? command.arguments[0] : @"";
    WSClient *client = self.clients[instanceId];
    if (!client) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"WebSocket not found"] callbackId:command.callbackId];
        return;
    }
    client.callbackId = command.callbackId;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)setBinaryType:(CDVInvokedUrlCommand *)command {
    NSString *instanceId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *type = command.arguments.count > 1 ? command.arguments[1] : @"";
    WSClient *client = self.clients[instanceId];
    if (client) {
        client.binaryType = type ?: @"";
    }
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)send:(CDVInvokedUrlCommand *)command {
    NSString *instanceId = command.arguments.count > 0 ? command.arguments[0] : @"";
    id message = command.arguments.count > 1 ? command.arguments[1] : @"";
    BOOL binary = command.arguments.count > 2 ? [command.arguments[2] boolValue] : NO;

    WSClient *client = self.clients[instanceId];
    if (!client) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"WebSocket not found"] callbackId:command.callbackId];
        return;
    }

    NSURLSessionWebSocketMessage *wsMessage = nil;
    if (binary) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:message options:0];
        wsMessage = [[NSURLSessionWebSocketMessage alloc] initWithData:data ?: [NSData data]];
    } else {
        wsMessage = [[NSURLSessionWebSocketMessage alloc] initWithString:[message isKindOfClass:[NSString class]] ? message : @""];
    }

    [client.task sendMessage:wsMessage completionHandler:^(NSError * _Nullable error) {
        if (error) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Send error"] callbackId:command.callbackId];
        } else {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    }];
}

- (void)close:(CDVInvokedUrlCommand *)command {
    NSString *instanceId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSNumber *code = command.arguments.count > 1 ? command.arguments[1] : @(1000);
    NSString *reason = command.arguments.count > 2 ? command.arguments[2] : @"";

    WSClient *client = self.clients[instanceId];
    if (!client) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"WebSocket not found"] callbackId:command.callbackId];
        return;
    }

    NSData *reasonData = [reason dataUsingEncoding:NSUTF8StringEncoding];
    [client.task cancelWithCloseCode:code.integerValue reason:reasonData];
    [self sendEventToClient:client type:@"close" instanceId:instanceId payload:@{ @"code": code ?: @1000, @"reason": reason ?: @"" }];

    [self.clients removeObjectForKey:instanceId];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)listClients:(CDVInvokedUrlCommand *)command {
    NSArray *keys = self.clients.allKeys ?: @[];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:keys];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)startReceiveLoopForClient:(WSClient *)client instanceId:(NSString *)instanceId {
    [client.task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            [self sendEventToClient:client type:@"error" instanceId:instanceId payload:@{ @"data": error.localizedDescription ?: @"WebSocket error" }];
            return;
        }

        if (message.type == NSURLSessionWebSocketMessageTypeData) {
            NSString *base64 = [message.data base64EncodedStringWithOptions:0] ?: @"";
            [self sendEventToClient:client type:@"message" instanceId:instanceId payload:@{ @"data": base64, @"isBinary": @YES, @"parseAsText": @NO }];
        } else {
            [self sendEventToClient:client type:@"message" instanceId:instanceId payload:@{ @"data": message.string ?: @"", @"isBinary": @NO, @"parseAsText": @NO }];
        }

        [self startReceiveLoopForClient:client instanceId:instanceId];
    }];
}

- (void)sendEventToClient:(WSClient *)client type:(NSString *)type instanceId:(NSString *)instanceId payload:(NSDictionary *)payload {
    if (!client.callbackId) {
        return;
    }

    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:payload ?: @{}];
    event[@"type"] = type ?: @"";

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:client.callbackId];
}

@end
