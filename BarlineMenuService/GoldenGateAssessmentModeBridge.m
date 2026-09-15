#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface BLNGoldenGateAssessmentController : NSObject
@property(nonatomic, strong, nullable) id assertion;
@property(nonatomic, strong, nullable) id pendingAssertion;
@property(nonatomic) int32_t activationState;
- (BOOL)applyConcealedBundleIdentifiers:(NSArray<NSString *> *)concealedBundleIdentifiers
           allowedSystemItemIdentifiers:(NSArray<NSNumber *> *)allowedSystemItemIdentifiers;
- (int32_t)currentActivationState;
- (void)invalidate;
@end

@implementation BLNGoldenGateAssessmentController

static BOOL BLNGoldenGateAssessmentRuntimeAvailable(void) {
    static void *frameworkHandle;
    static BOOL runtimeAvailable;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
            RTLD_NOW | RTLD_LOCAL
        );
        Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        runtimeAvailable = frameworkHandle && configurationClass && assertionClass &&
            [configurationClass instancesRespondToSelector:NSSelectorFromString(
                @"initWithAllowedSystemItems:allowedBundleIdentifiers:"
            )] &&
            [assertionClass instancesRespondToSelector:NSSelectorFromString(
                @"activateWithConfiguration:completionHandler:"
            )] &&
            [assertionClass instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
    });
    return runtimeAvailable;
}

- (BOOL)applyConcealedBundleIdentifiers:(NSArray<NSString *> *)concealedBundleIdentifiers
           allowedSystemItemIdentifiers:(NSArray<NSNumber *> *)allowedSystemItemIdentifiers {
    if (concealedBundleIdentifiers.count == 0 && allowedSystemItemIdentifiers.count == 9) {
        [self invalidate];
        @synchronized (self) {
            self.activationState = 1;
        }
        return YES;
    }

    if (!BLNGoldenGateAssessmentRuntimeAvailable()) return NO;

    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    SEL configurationInitializer = NSSelectorFromString(
        @"initWithAllowedSystemItems:allowedBundleIdentifiers:"
    );
    SEL activationSelector = NSSelectorFromString(
        @"activateWithConfiguration:completionHandler:"
    );
    SEL invalidationSelector = NSSelectorFromString(@"invalidate");
    if (!configurationClass || !assertionClass ||
        ![configurationClass instancesRespondToSelector:configurationInitializer] ||
        ![assertionClass instancesRespondToSelector:activationSelector] ||
        ![assertionClass instancesRespondToSelector:invalidationSelector]) {
        return NO;
    }

    NSSet<NSString *> *concealed = [NSSet setWithArray:concealedBundleIdentifiers];
    NSMutableOrderedSet<NSString *> *allowedBundles = [NSMutableOrderedSet orderedSet];
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *bundleIdentifier = application.bundleIdentifier;
        if (bundleIdentifier.length && ![concealed containsObject:bundleIdentifier.lowercaseString]) {
            [allowedBundles addObject:bundleIdentifier];
        }
    }
    [allowedBundles addObject:@"com.mabryventures.Barline"];
    [allowedBundles addObject:@"com.apple.systemuiserver"];
    [allowedBundles addObject:@"com.apple.finder"];
    [allowedBundles addObject:@"com.apple.dock"];

    id configurationAllocation = ((id (*)(id, SEL))objc_msgSend)(
        configurationClass, @selector(alloc)
    );
    id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)(
        configurationAllocation,
        configurationInitializer,
        allowedSystemItemIdentifiers,
        allowedBundles.array
    );
    if (!configuration) return NO;

    id candidate = ((id (*)(id, SEL))objc_msgSend)(assertionClass, @selector(new));
    if (!candidate) return NO;

    @synchronized (self) {
        if (self.pendingAssertion) {
            ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
            return NO;
        }
        self.pendingAssertion = candidate;
        self.activationState = 0;
    }

    __weak BLNGoldenGateAssessmentController *weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        BLNGoldenGateAssessmentController *strongSelf = weakSelf;
        if (!strongSelf) return;

        id previous = nil;
        @synchronized (strongSelf) {
            // Ignore a callback for an assertion invalidated by shutdown.
            if (strongSelf.pendingAssertion != candidate) return;
            strongSelf.pendingAssertion = nil;
            if (error) {
                strongSelf.activationState = -1;
            } else {
                previous = strongSelf.assertion;
                strongSelf.assertion = candidate;
                strongSelf.activationState = 1;
            }
        }

        if (error) {
            ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
            NSLog(@"[BarlineAssessment] activation rejected domain=%@ code=%ld",
                  error.domain, (long)error.code);
        } else if (previous) {
            ((void (*)(id, SEL))objc_msgSend)(previous, invalidationSelector);
        }
    };
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            candidate, activationSelector, configuration, completion
        );
    } @catch (__unused NSException *exception) {
        @synchronized (self) {
            if (self.pendingAssertion == candidate) {
                self.pendingAssertion = nil;
                self.activationState = -1;
            }
        }
        ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
        return NO;
    }
    return YES;
}

- (int32_t)currentActivationState {
    @synchronized (self) {
        return self.activationState;
    }
}

- (void)invalidate {
    id current = nil;
    id pending = nil;
    @synchronized (self) {
        current = self.assertion;
        pending = self.pendingAssertion;
        self.assertion = nil;
        self.pendingAssertion = nil;
        self.activationState = -1;
    }
    if (current) {
        ((void (*)(id, SEL))objc_msgSend)(current, NSSelectorFromString(@"invalidate"));
    }
    if (pending && pending != current) {
        ((void (*)(id, SEL))objc_msgSend)(pending, NSSelectorFromString(@"invalidate"));
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

void *BLNGoldenGateAssessmentCreate(void) {
    if (!BLNGoldenGateAssessmentRuntimeAvailable()) return NULL;
    return (__bridge_retained void *)[BLNGoldenGateAssessmentController new];
}

bool BLNGoldenGateAssessmentApply(
    void *opaqueController,
    CFArrayRef concealedBundleIdentifiers,
    CFArrayRef allowedSystemItemIdentifiers
) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    return [controller applyConcealedBundleIdentifiers:(__bridge NSArray *)concealedBundleIdentifiers
                          allowedSystemItemIdentifiers:(__bridge NSArray *)allowedSystemItemIdentifiers];
}

int32_t BLNGoldenGateAssessmentActivationState(void *opaqueController) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    return [controller currentActivationState];
}

void BLNGoldenGateAssessmentInvalidate(void *opaqueController) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    [controller invalidate];
}

void BLNGoldenGateAssessmentDestroy(void *opaqueController) {
    CFBridgingRelease(opaqueController);
}
