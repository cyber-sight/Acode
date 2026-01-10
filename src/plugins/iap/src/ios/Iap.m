#import "Iap.h"
#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>

@interface Iap () <SKProductsRequestDelegate, SKPaymentTransactionObserver>
@property (nonatomic, strong) SKProductsRequest *productsRequest;
@property (nonatomic, copy) NSString *purchaseUpdatedCallbackId;
@end

@implementation Iap

- (void)pluginInitialize {
    [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
}

- (void)startConnection:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:0];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)setPurchaseUpdatedListener:(CDVInvokedUrlCommand *)command {
    self.purchaseUpdatedCallbackId = command.callbackId;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)getProducts:(CDVInvokedUrlCommand *)command {
    NSArray *productIds = command.arguments.count > 0 ? command.arguments[0] : @[];
    if (![productIds isKindOfClass:[NSArray class]] || productIds.count == 0) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No product IDs provided"] callbackId:command.callbackId];
        return;
    }

    NSSet *identifiers = [NSSet setWithArray:productIds];
    self.productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:identifiers];
    self.productsRequest.delegate = self;
    objc_setAssociatedObject(self.productsRequest, "callbackId", command.callbackId, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self.productsRequest start];
}

- (void)purchase:(CDVInvokedUrlCommand *)command {
    NSString *productId = command.arguments.count > 0 ? command.arguments[0] : @"";
    if (productId.length == 0) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Product ID cannot be empty"] callbackId:command.callbackId];
        return;
    }

    if (![SKPaymentQueue canMakePayments]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Payments not allowed"] callbackId:command.callbackId];
        return;
    }

    SKMutablePayment *payment = [SKMutablePayment paymentWithProductIdentifier:productId];
    [[SKPaymentQueue defaultQueue] addPayment:payment];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)consume:(CDVInvokedUrlCommand *)command {
    NSString *token = command.arguments.count > 0 ? command.arguments[0] : @"";
    [self finishTransactionWithId:token command:command];
}

- (void)acknowledgePurchase:(CDVInvokedUrlCommand *)command {
    NSString *token = command.arguments.count > 0 ? command.arguments[0] : @"";
    [self finishTransactionWithId:token command:command];
}

- (void)getPurchases:(CDVInvokedUrlCommand *)command {
    NSMutableArray *purchases = [NSMutableArray array];
    for (SKPaymentTransaction *transaction in [SKPaymentQueue defaultQueue].transactions) {
        NSDictionary *payload = [self transactionToJson:transaction];
        if (payload) {
            [purchases addObject:payload];
        }
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:purchases];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

#pragma mark - SKProductsRequestDelegate

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    NSString *callbackId = objc_getAssociatedObject(request, "callbackId");
    NSMutableArray *products = [NSMutableArray array];

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;

    for (SKProduct *product in response.products) {
        formatter.locale = product.priceLocale;
        NSString *price = [formatter stringFromNumber:product.price] ?: @"";
        long long micros = (long long)(product.price.doubleValue * 1000000.0);

        NSDictionary *item = @{
            @"productId": product.productIdentifier ?: @"",
            @"title": product.localizedTitle ?: @"",
            @"description": product.localizedDescription ?: @"",
            @"price": price,
            @"priceAmountMicros": @(micros),
            @"priceCurrencyCode": [product.priceLocale objectForKey:NSLocaleCurrencyCode] ?: @"",
            @"type": @"inapp"
        };
        [products addObject:item];
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:products];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    NSString *callbackId = objc_getAssociatedObject(request, "callbackId");
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Request failed"];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

#pragma mark - SKPaymentTransactionObserver

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
    if (!self.purchaseUpdatedCallbackId) {
        return;
    }

    NSMutableArray *payload = [NSMutableArray array];
    for (SKPaymentTransaction *transaction in transactions) {
        NSDictionary *item = [self transactionToJson:transaction];
        if (item) {
            [payload addObject:item];
        }

        if (transaction.transactionState == SKPaymentTransactionStatePurchased || transaction.transactionState == SKPaymentTransactionStateFailed) {
            [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
        }
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:payload];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:self.purchaseUpdatedCallbackId];
}

#pragma mark - Helpers

- (NSDictionary *)transactionToJson:(SKPaymentTransaction *)transaction {
    if (!transaction) {
        return nil;
    }

    NSString *productId = transaction.payment.productIdentifier ?: @"";
    NSArray *productIds = productId.length > 0 ? @[productId] : @[];
    NSString *transactionId = transaction.transactionIdentifier ?: @"";
    NSTimeInterval time = transaction.transactionDate ? transaction.transactionDate.timeIntervalSince1970 * 1000.0 : 0;

    NSNumber *purchaseState = @0;
    switch (transaction.transactionState) {
        case SKPaymentTransactionStatePurchased:
            purchaseState = @1;
            break;
        case SKPaymentTransactionStateDeferred:
            purchaseState = @2;
            break;
        case SKPaymentTransactionStateFailed:
            purchaseState = @0;
            break;
        default:
            purchaseState = @0;
            break;
    }

    return @{
        @"productIds": productIds,
        @"orderId": transactionId,
        @"signature": @"",
        @"purchaseTime": @((long long)time),
        @"purchaseToken": transactionId,
        @"purchaseState": purchaseState,
        @"isAcknowledged": @YES,
        @"developerPayload": @""
    };
}

- (void)finishTransactionWithId:(NSString *)transactionId command:(CDVInvokedUrlCommand *)command {
    if (transactionId.length == 0) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid transaction token"] callbackId:command.callbackId];
        return;
    }

    for (SKPaymentTransaction *transaction in [SKPaymentQueue defaultQueue].transactions) {
        if ([transaction.transactionIdentifier isEqualToString:transactionId]) {
            [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
            return;
        }
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Transaction not found"] callbackId:command.callbackId];
}

@end
