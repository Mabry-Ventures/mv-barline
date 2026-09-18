#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface BLNGoldenGateAssessmentController : NSObject
@property(nonatomic, strong, nullable) id assertion;
@property(nonatomic, strong, nullable) id pendingAssertion;
@property(nonatomic) uint64_t pendingToken;
@property(nonatomic) uint64_t nextToken;
@property(nonatomic) BOOL pendingClearsCurrentAssertion;
@property(nonatomic) int32_t activationState;
- (uint64_t)beginConcealedBundleIdentifiers:(NSArray<NSString *> *)concealedBundleIdentifiers
           allowedSystemItemIdentifiers:(NSArray<NSNumber *> *)allowedSystemItemIdentifiers;
- (int32_t)activationStateForToken:(uint64_t)token;
- (void)acknowledgeCandidate:(id)candidate token:(uint64_t)token error:(NSError * _Nullable)error;
- (BOOL)commitToken:(uint64_t)token;
- (BOOL)abortToken:(uint64_t)token;
- (void)invalidate;
@end

@implementation BLNGoldenGateAssessmentController

#if defined(BARLINE_BRIDGE_TESTING)
static NSUInteger BLNGoldenGateForcedRuntimeMisses;

void BLNGoldenGateAssessmentForceRuntimeMisses(NSUInteger count) {
    BLNGoldenGateForcedRuntimeMisses = count;
}
#endif

static BOOL BLNGoldenGateAssessmentRuntimeAvailable(void) {
    static void *frameworkHandle;
    static BOOL confirmedAvailable;

    // The helper can be asked for capabilities while launch services are still
    // bringing its private runtime into the process. A negative result at that
    // boundary is not authoritative for the lifetime of the helper. Cache only
    // a confirmed positive result and allow later user-driven probes to recover.
    @synchronized (BLNGoldenGateAssessmentController.class) {
#if defined(BARLINE_BRIDGE_TESTING)
        if (BLNGoldenGateForcedRuntimeMisses > 0) {
            BLNGoldenGateForcedRuntimeMisses -= 1;
            return NO;
        }
#endif
        if (confirmedAvailable) return YES;
        if (!frameworkHandle) {
            // MenuBarClientCore is delivered from the dyld shared cache on
            // macOS 27; its framework directory contains no standalone Mach-O
            // image. Resolve it lazily, matching dyld's supported platform-
            // binary path. RTLD_NOW can reject the cache image while eagerly
            // resolving implementation-only dependencies that Barline never
            // calls, leaving the Objective-C classes unavailable even though
            // the assessment API itself is present.
            frameworkHandle = dlopen(
                "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
                RTLD_LAZY | RTLD_LOCAL
            );
            if (!frameworkHandle) {
                const char *error = dlerror();
                NSLog(@"[BarlineAssessment] MenuBarClientCore load failed: %s",
                      error ?: "unknown dyld error");
            }
        }
        Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        BOOL frameworkAvailable = frameworkHandle != NULL;
#if defined(BARLINE_BRIDGE_TESTING)
        frameworkAvailable = YES;
#endif
        confirmedAvailable = frameworkAvailable && configurationClass && assertionClass &&
            [configurationClass instancesRespondToSelector:NSSelectorFromString(
                @"initWithAllowedSystemItems:allowedBundleIdentifiers:"
            )] &&
            [assertionClass instancesRespondToSelector:NSSelectorFromString(
                @"activateWithConfiguration:completionHandler:"
            )] &&
            [assertionClass instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
        if (!confirmedAvailable && frameworkAvailable) {
            NSLog(@"[BarlineAssessment] runtime surface unavailable config=%d assertion=%d",
                  configurationClass != Nil, assertionClass != Nil);
        }
        return confirmedAvailable;
    }
}

- (uint64_t)beginConcealedBundleIdentifiers:(NSArray<NSString *> *)concealedBundleIdentifiers
           allowedSystemItemIdentifiers:(NSArray<NSNumber *> *)allowedSystemItemIdentifiers {
    if (!BLNGoldenGateAssessmentRuntimeAvailable()) return 0;

    uint64_t token = 0;
    @synchronized (self) {
        if (self.pendingToken != 0) return 0;
        self.nextToken += 1;
        if (self.nextToken == 0) self.nextToken = 1;
        token = self.nextToken;
        self.pendingToken = token;
        self.activationState = 0;
    }

    if (concealedBundleIdentifiers.count == 0 && allowedSystemItemIdentifiers.count == 9) {
        @synchronized (self) {
            if (self.pendingToken != token) return 0;
            self.pendingClearsCurrentAssertion = YES;
            self.activationState = 1;
        }
        return token;
    }

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
        [self abortToken:token];
        return 0;
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
    if (!configuration) {
        [self abortToken:token];
        return 0;
    }

    id candidate = ((id (*)(id, SEL))objc_msgSend)(assertionClass, @selector(new));
    if (!candidate) {
        [self abortToken:token];
        return 0;
    }

    @synchronized (self) {
        if (self.pendingToken != token || self.pendingAssertion) {
            ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
            [self abortToken:token];
            return 0;
        }
        self.pendingAssertion = candidate;
        self.pendingClearsCurrentAssertion = NO;
    }

    __weak BLNGoldenGateAssessmentController *weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        BLNGoldenGateAssessmentController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf acknowledgeCandidate:candidate token:token error:error];
    };
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            candidate, activationSelector, configuration, completion
        );
    } @catch (__unused NSException *exception) {
        @synchronized (self) {
            if (self.pendingToken == token && self.pendingAssertion == candidate) {
                self.pendingAssertion = nil;
                self.pendingToken = 0;
                self.activationState = -1;
            }
        }
        ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
        return 0;
    }
    return token;
}

- (void)acknowledgeCandidate:(id)candidate token:(uint64_t)token error:(NSError *)error {
    @synchronized (self) {
        // A callback only acknowledges readiness. The Swift owner must
        // explicitly commit this exact token before native state changes.
        if (self.pendingToken != token || self.pendingAssertion != candidate) return;
        if (error) {
            self.pendingAssertion = nil;
            self.activationState = -1;
        } else {
            self.activationState = 1;
        }
    }

    if (error) {
        ((void (*)(id, SEL))objc_msgSend)(candidate, NSSelectorFromString(@"invalidate"));
        NSLog(@"[BarlineAssessment] activation rejected domain=%@ code=%ld",
              error.domain, (long)error.code);
    }
}

- (int32_t)activationStateForToken:(uint64_t)token {
    @synchronized (self) {
        if (token == 0 || self.pendingToken != token) return -2;
        return self.activationState;
    }
}

- (BOOL)commitToken:(uint64_t)token {
    id previous = nil;
    @synchronized (self) {
        if (token == 0 || self.pendingToken != token || self.activationState != 1) {
            return NO;
        }
        previous = self.assertion;
        self.assertion = self.pendingClearsCurrentAssertion ? nil : self.pendingAssertion;
        self.pendingAssertion = nil;
        self.pendingToken = 0;
        self.pendingClearsCurrentAssertion = NO;
        self.activationState = -2;
    }
    if (previous) {
        ((void (*)(id, SEL))objc_msgSend)(previous, NSSelectorFromString(@"invalidate"));
    }
    return YES;
}

- (BOOL)abortToken:(uint64_t)token {
    id pending = nil;
    @synchronized (self) {
        if (token == 0 || self.pendingToken != token) return NO;
        pending = self.pendingAssertion;
        self.pendingAssertion = nil;
        self.pendingToken = 0;
        self.pendingClearsCurrentAssertion = NO;
        self.activationState = -2;
    }
    if (pending) {
        ((void (*)(id, SEL))objc_msgSend)(pending, NSSelectorFromString(@"invalidate"));
    }
    return YES;
}

- (void)invalidate {
    id current = nil;
    id pending = nil;
    @synchronized (self) {
        current = self.assertion;
        pending = self.pendingAssertion;
        self.assertion = nil;
        self.pendingAssertion = nil;
        self.pendingToken = 0;
        self.pendingClearsCurrentAssertion = NO;
        self.activationState = -2;
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

uint64_t BLNGoldenGateAssessmentBegin(
    void *opaqueController,
    CFArrayRef concealedBundleIdentifiers,
    CFArrayRef allowedSystemItemIdentifiers
) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    return [controller beginConcealedBundleIdentifiers:(__bridge NSArray *)concealedBundleIdentifiers
                          allowedSystemItemIdentifiers:(__bridge NSArray *)allowedSystemItemIdentifiers];
}

int32_t BLNGoldenGateAssessmentActivationState(void *opaqueController, uint64_t transactionToken) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    return [controller activationStateForToken:transactionToken];
}

bool BLNGoldenGateAssessmentCommit(void *opaqueController, uint64_t transactionToken) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    return [controller commitToken:transactionToken];
}

bool BLNGoldenGateAssessmentAbort(void *opaqueController, uint64_t transactionToken) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    return [controller abortToken:transactionToken];
}

void BLNGoldenGateAssessmentInvalidate(void *opaqueController) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    [controller invalidate];
}

void BLNGoldenGateAssessmentDestroy(void *opaqueController) {
    CFBridgingRelease(opaqueController);
}
