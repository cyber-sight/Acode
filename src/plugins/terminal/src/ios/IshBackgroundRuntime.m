#import "IshBackgroundRuntime.h"

#import <BackgroundTasks/BackgroundTasks.h>
#import <UIKit/UIKit.h>

static NSString *const IshContinuedTaskWildcard = @"com.foxdebug.acodeios.terminal.*";

@interface IshBackgroundRuntime ()
@property (nonatomic) NSMutableSet<NSString *> *activeSessions;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic) BOOL continuedTaskRegistered;
@property (nonatomic, copy, nullable) NSString *continuedRequestIdentifier;
@property (nonatomic, strong, nullable) BGContinuedProcessingTask *continuedTask API_AVAILABLE(ios(26.0));
@property (nonatomic, strong, nullable) NSTimer *progressTimer;
@end

@implementation IshBackgroundRuntime

+ (instancetype)shared {
    static IshBackgroundRuntime *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [[IshBackgroundRuntime alloc] initPrivate];
    });
    return runtime;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _activeSessions = [NSMutableSet set];
        _backgroundTask = UIBackgroundTaskInvalid;
        _continuedTaskRegistered = NO;
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        [notifications addObserver:self
                          selector:@selector(applicationDidEnterBackground:)
                              name:UIApplicationDidEnterBackgroundNotification
                            object:nil];
        [notifications addObserver:self
                          selector:@selector(applicationWillEnterForeground:)
                              name:UIApplicationWillEnterForegroundNotification
                            object:nil];

        if (@available(iOS 26.0, *)) {
            BOOL registered = [[BGTaskScheduler sharedScheduler]
                registerForTaskWithIdentifier:IshContinuedTaskWildcard
                                   usingQueue:dispatch_get_main_queue()
                                launchHandler:^(__kindof BGTask *task) {
                [[IshBackgroundRuntime shared] beginContinuedTask:(BGContinuedProcessingTask *)task];
            }];
            self.continuedTaskRegistered = registered;
            if (!registered) NSLog(@"iSH background: continued-processing handler was not registered");
        }
    }
    return self;
}

- (instancetype)init {
    return [IshBackgroundRuntime shared];
}

- (void)sessionDidStart:(NSString *)sessionId {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL wasEmpty = self.activeSessions.count == 0;
        [self.activeSessions addObject:sessionId];
        if (!wasEmpty) return;

        if (@available(iOS 26.0, *)) {
            [self submitContinuedTask];
        }
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
            [self beginBackgroundAssertion];
        }
    });
}

- (void)sessionDidEnd:(NSString *)sessionId {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.activeSessions removeObject:sessionId];
        if (self.activeSessions.count != 0) return;
        [self finishContinuedTaskSuccessfully:YES];
        [self endBackgroundAssertion];
    });
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    if (self.activeSessions.count != 0) [self beginBackgroundAssertion];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    [self endBackgroundAssertion];
}

- (void)beginBackgroundAssertion {
    if (self.backgroundTask != UIBackgroundTaskInvalid || self.activeSessions.count == 0) return;

    __weak IshBackgroundRuntime *weakSelf = self;
    self.backgroundTask = [UIApplication.sharedApplication
        beginBackgroundTaskWithName:@"Acode terminal sessions"
                  expirationHandler:^{
        IshBackgroundRuntime *strongSelf = weakSelf;
        NSLog(@"iSH background: finite execution allowance expired; sessions may be suspended by iOS");
        [strongSelf endBackgroundAssertion];
    }];
}

- (void)endBackgroundAssertion {
    UIBackgroundTaskIdentifier task = self.backgroundTask;
    if (task == UIBackgroundTaskInvalid) return;
    self.backgroundTask = UIBackgroundTaskInvalid;
    [UIApplication.sharedApplication endBackgroundTask:task];
}

- (void)submitContinuedTask API_AVAILABLE(ios(26.0)) {
    if (self.continuedRequestIdentifier || self.continuedTask) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    if (!self.continuedTaskRegistered) {
        NSLog(@"iSH background: continued-processing task is unavailable; using finite background assertion");
        return;
    }

    NSString *identifier = [NSString stringWithFormat:@"com.foxdebug.acodeios.terminal.%@", NSUUID.UUID.UUIDString];
    BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
        initWithIdentifier:identifier
                     title:@"Acode terminal running"
                  subtitle:@"Keeping terminal processes available in the background"];
    request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
    request.requiredResources = BGContinuedProcessingTaskRequestResourcesDefault;

    self.continuedRequestIdentifier = identifier;
    @try {
        NSError *error = nil;
        if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error]) {
            self.continuedRequestIdentifier = nil;
            NSLog(@"iSH background: continued-processing request failed: %@", error.localizedDescription);
        }
    } @catch (NSException *exception) {
        self.continuedRequestIdentifier = nil;
        NSLog(@"iSH background: continued-processing request raised %@: %@", exception.name, exception.reason);
    }
}

- (void)beginContinuedTask:(BGContinuedProcessingTask *)task API_AVAILABLE(ios(26.0)) {
    if (self.activeSessions.count == 0) {
        [task setTaskCompletedWithSuccess:YES];
        return;
    }

    self.continuedTask = task;
    task.progress.totalUnitCount = 86400;
    task.progress.completedUnitCount = 1;
    __weak IshBackgroundRuntime *weakSelf = self;
    task.expirationHandler = ^{
        IshBackgroundRuntime *strongSelf = weakSelf;
        NSLog(@"iSH background: continued-processing task expired; sessions may be suspended by iOS");
        [strongSelf finishContinuedTaskSuccessfully:NO];
    };
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        IshBackgroundRuntime *strongSelf = weakSelf;
        BGContinuedProcessingTask *activeTask = strongSelf.continuedTask;
        if (!activeTask) {
            [timer invalidate];
            return;
        }
        int64_t next = activeTask.progress.completedUnitCount + 1;
        activeTask.progress.completedUnitCount = MIN(next, activeTask.progress.totalUnitCount - 1);
    }];
}

- (void)finishContinuedTaskSuccessfully:(BOOL)success {
    [self.progressTimer invalidate];
    self.progressTimer = nil;

    if (@available(iOS 26.0, *)) {
        if (self.continuedRequestIdentifier) {
            [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:self.continuedRequestIdentifier];
            self.continuedRequestIdentifier = nil;
        }
        BGContinuedProcessingTask *task = self.continuedTask;
        self.continuedTask = nil;
        if (task) {
            task.progress.completedUnitCount = task.progress.totalUnitCount;
            [task setTaskCompletedWithSuccess:success];
        }
    }
}

@end
