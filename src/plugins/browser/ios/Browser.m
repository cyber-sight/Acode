#import "Browser.h"
#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>

@implementation Browser

- (void)open:(CDVInvokedUrlCommand *)command {
    NSString *urlString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid URL"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 9.0, *)) {
            SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
            [self.viewController presentViewController:safari animated:YES completion:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    });

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
