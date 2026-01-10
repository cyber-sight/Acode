#import "Sftp.h"
#import <Cordova/CDVPluginResult.h>
#import <NMSSH/NMSSH.h>

@interface Sftp ()
@property (nonatomic, strong) NMSSHSession *session;
@property (nonatomic, strong) NMSFTP *sftp;
@property (nonatomic, copy) NSString *connectionId;
@end

@implementation Sftp

- (void)connectUsingPassword:(CDVInvokedUrlCommand *)command {
    NSString *host = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSNumber *port = command.arguments.count > 1 ? command.arguments[1] : @22;
    NSString *username = command.arguments.count > 2 ? command.arguments[2] : @"";
    NSString *password = command.arguments.count > 3 ? command.arguments[3] : @"";

    [self.commandDelegate runInBackground:^{
        NMSSHSession *session = [NMSSHSession connectToHost:host port:port.integerValue withUsername:username];
        if (!session.isConnected) {
            [self sendError:@"Failed to establish SSH connection" command:command];
            return;
        }

        [session authenticateByPassword:password];
        if (!session.isAuthorized) {
            [self sendError:@"Authentication failed" command:command];
            [session disconnect];
            return;
        }

        NMSFTP *sftp = [[NMSFTP alloc] initWithSession:session];
        if (![sftp connect]) {
            [self sendError:@"Failed to initialize SFTP subsystem" command:command];
            [session disconnect];
            return;
        }

        self.session = session;
        self.sftp = sftp;
        self.connectionId = [NSString stringWithFormat:@"%@@%@", username, host];

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)connectUsingKeyFile:(CDVInvokedUrlCommand *)command {
    NSString *host = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSNumber *port = command.arguments.count > 1 ? command.arguments[1] : @22;
    NSString *username = command.arguments.count > 2 ? command.arguments[2] : @"";
    NSString *keyPath = command.arguments.count > 3 ? command.arguments[3] : @"";
    NSString *passphrase = command.arguments.count > 4 ? command.arguments[4] : nil;

    [self.commandDelegate runInBackground:^{
        NSURL *keyURL = [NSURL URLWithString:keyPath];
        if (!keyURL || !keyURL.isFileURL) {
            keyURL = [NSURL fileURLWithPath:keyPath];
        }

        NMSSHSession *session = [NMSSHSession connectToHost:host port:port.integerValue withUsername:username];
        if (!session.isConnected) {
            [self sendError:@"Failed to establish SSH connection" command:command];
            return;
        }

        [session authenticateByPublicKey:keyURL.path privateKey:keyURL.path andPassword:passphrase];
        if (!session.isAuthorized) {
            [self sendError:@"Authentication failed" command:command];
            [session disconnect];
            return;
        }

        NMSFTP *sftp = [[NMSFTP alloc] initWithSession:session];
        if (![sftp connect]) {
            [self sendError:@"Failed to initialize SFTP subsystem" command:command];
            [session disconnect];
            return;
        }

        self.session = session;
        self.sftp = sftp;
        self.connectionId = [NSString stringWithFormat:@"%@@%@", username, host];

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)exec:(CDVInvokedUrlCommand *)command {
    NSString *cmd = command.arguments.count > 0 ? command.arguments[0] : @"";
    [self.commandDelegate runInBackground:^{
        if (!self.session || !self.session.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSError *error = nil;
        NSString *response = [self.session.channel execute:cmd error:&error];
        if (error) {
            [self sendError:error.localizedDescription command:command];
            return;
        }

        NSDictionary *payload = @{
            @"code": @(self.session.channel.exitStatus),
            @"result": response ?: @""
        };
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)getFile:(CDVInvokedUrlCommand *)command {
    NSString *remotePath = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *localPath = command.arguments.count > 1 ? command.arguments[1] : @"";

    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSURL *localURL = [NSURL URLWithString:localPath];
        if (!localURL || !localURL.isFileURL) {
            localURL = [NSURL fileURLWithPath:localPath];
        }

        BOOL ok = [self.sftp downloadFile:remotePath to:localURL.path];
        if (!ok) {
            [self sendError:@"SFTP download failed" command:command];
            return;
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)putFile:(CDVInvokedUrlCommand *)command {
    NSString *remotePath = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *localPath = command.arguments.count > 1 ? command.arguments[1] : @"";

    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSURL *localURL = [NSURL URLWithString:localPath];
        if (!localURL || !localURL.isFileURL) {
            localURL = [NSURL fileURLWithPath:localPath];
        }

        BOOL ok = [self.sftp uploadFile:localURL.path to:remotePath];
        if (!ok) {
            [self sendError:@"SFTP upload failed" command:command];
            return;
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)lsDir:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";

    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSError *error = nil;
        NSArray<NMSFTPFile *> *files = [self.sftp contentsOfDirectoryAtPath:path error:&error];
        if (error) {
            [self sendError:error.localizedDescription command:command];
            return;
        }

        NSMutableArray *resultFiles = [NSMutableArray array];
        for (NMSFTPFile *file in files) {
            if ([file.filename isEqualToString:@"."] || [file.filename isEqualToString:@".."])
                continue;

            NSDictionary *fileInfo = @{
                @"name": file.filename ?: @"",
                @"exists": @YES,
                @"canRead": @YES,
                @"canWrite": @YES,
                @"permissions": file.permissionsString ?: @"",
                @"length": @(file.fileSize),
                @"url": file.longname ?: file.filename ?: @"",
                @"lastModified": @((long long)(file.modificationDate.timeIntervalSince1970 * 1000)),
                @"isLink": @(file.isSymbolicLink),
                @"isDirectory": @(file.isDirectory),
                @"isFile": @(file.isRegularFile)
            };
            [resultFiles addObject:fileInfo];
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultFiles];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)stat:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";

    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSError *error = nil;
        NMSFTPFile *file = [self.sftp infoForFileAtPath:path error:&error];
        if (error || !file) {
            NSDictionary *payload = @{
                @"exists": @NO,
                @"url": path ?: @""
            };
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        NSDictionary *payload = @{
            @"exists": @YES,
            @"canRead": @YES,
            @"canWrite": @YES,
            @"isLink": @(file.isSymbolicLink),
            @"isDirectory": @(file.isDirectory),
            @"isFile": @(file.isRegularFile),
            @"length": @(file.fileSize),
            @"permissions": file.permissionsString ?: @"",
            @"lastModified": @((long long)(file.modificationDate.timeIntervalSince1970 * 1000)),
            @"name": file.filename ?: @"",
            @"url": path ?: @""
        };
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)mkdir:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }
        NSError *error = nil;
        BOOL ok = [self.sftp createDirectoryAtPath:path error:&error];
        if (!ok || error) {
            [self sendError:error.localizedDescription ?: @"SFTP mkdir failed" command:command];
            return;
        }
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)rm:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }
        NSError *error = nil;
        BOOL ok = [self.sftp removeFileAtPath:path error:&error];
        if (!ok || error) {
            [self sendError:error.localizedDescription ?: @"SFTP remove failed" command:command];
            return;
        }
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)createFile:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *content = command.arguments.count > 1 ? command.arguments[1] : @"";

    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        BOOL ok = [self.sftp writeContents:data toFileAtPath:path];
        if (!ok) {
            [self sendError:@"SFTP create file failed" command:command];
            return;
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)rename:(CDVInvokedUrlCommand *)command {
    NSString *oldPath = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *newPath = command.arguments.count > 1 ? command.arguments[1] : @"";

    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSError *error = nil;
        BOOL ok = [self.sftp moveItemAtPath:oldPath toPath:newPath error:&error];
        if (!ok || error) {
            [self sendError:error.localizedDescription ?: @"SFTP rename failed" command:command];
            return;
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)pwd:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        if (!self.sftp || !self.sftp.isConnected) {
            [self sendError:@"Not connected" command:command];
            return;
        }

        NSString *pwd = [self.sftp contentsOfDirectoryAtPath:@"." error:nil] ? @"." : @"/";
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:pwd];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)close:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        if (self.sftp) {
            [self.sftp disconnect];
        }
        if (self.session) {
            [self.session disconnect];
        }
        self.sftp = nil;
        self.session = nil;
        self.connectionId = nil;
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)isConnected:(CDVInvokedUrlCommand *)command {
    BOOL connected = self.session && self.session.isConnected && self.sftp && self.sftp.isConnected;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:connected ? (self.connectionId ?: @"1") : @"0"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendError:(NSString *)message command:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Error"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
