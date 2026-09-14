#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface BLNGoldenGateAssessmentController : NSObject
@property(nonatomic, strong, nullable) id assertion;
- (BOOL)applyConcealedBundleIdentifiers:(NSArray<NSString *> *)concealedBundleIdentifiers
           allowedSystemItemIdentifiers:(NSArray<NSNumber *> *)allowedSystemItemIdentifiers;
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
    id candidate = ((id (*)(id, SEL))objc_msgSend)(assertionClass, @selector(new));
    if (!configuration || !candidate) return NO;

    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);
    __block BOOL activationSucceeded = NO;
    void (^completion)(id) = ^(id error) {
        activationSucceeded = error == nil;
        dispatch_semaphore_signal(completionSemaphore);
    };
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            candidate, activationSelector, configuration, completion
        );
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (dispatch_semaphore_wait(
            completionSemaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC))
        ) != 0 || !activationSucceeded) {
        ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
        return NO;
    }

    id previous = self.assertion;
    self.assertion = candidate;
    if (previous) ((void (*)(id, SEL))objc_msgSend)(previous, invalidationSelector);
    return YES;
}

- (void)invalidate {
    id current = self.assertion;
    self.assertion = nil;
    if (current) {
        ((void (*)(id, SEL))objc_msgSend)(current, NSSelectorFromString(@"invalidate"));
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

void BLNGoldenGateAssessmentInvalidate(void *opaqueController) {
    BLNGoldenGateAssessmentController *controller = (__bridge BLNGoldenGateAssessmentController *)opaqueController;
    [controller invalidate];
}

void BLNGoldenGateAssessmentDestroy(void *opaqueController) {
    CFBridgingRelease(opaqueController);
}
