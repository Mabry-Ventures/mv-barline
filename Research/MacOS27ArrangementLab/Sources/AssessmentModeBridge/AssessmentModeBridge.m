#import "AssessmentModeBridge.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface BLNLabAssessmentController : NSObject
@property(nonatomic, strong, nullable) id assertion;
@property(nonatomic, strong, nullable) id pendingAssertion;
@property(nonatomic) uint64_t pendingToken;
@property(nonatomic) uint64_t nextToken;
@property(nonatomic) BOOL pendingClearsAssertion;
@property(nonatomic) int32_t activationState;
@end

@implementation BLNLabAssessmentController

static BOOL BLNLabRuntimeAvailable(void) {
    static void *frameworkHandle;
    static BOOL available;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
            RTLD_NOW | RTLD_LOCAL
        );
        Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        available = frameworkHandle && configurationClass && assertionClass &&
            [configurationClass instancesRespondToSelector:NSSelectorFromString(
                @"initWithAllowedSystemItems:allowedBundleIdentifiers:"
            )] &&
            [assertionClass instancesRespondToSelector:NSSelectorFromString(
                @"activateWithConfiguration:completionHandler:"
            )] &&
            [assertionClass instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
    });
    return available;
}

- (uint64_t)begin:(NSArray<NSString *> *)concealedBundleIdentifiers {
    if (!BLNLabRuntimeAvailable()) return 0;

    uint64_t token = 0;
    @synchronized (self) {
        if (self.pendingToken != 0) return 0;
        self.nextToken += 1;
        if (self.nextToken == 0) self.nextToken = 1;
        token = self.nextToken;
        self.pendingToken = token;
        self.activationState = 0;
        self.pendingClearsAssertion = concealedBundleIdentifiers.count == 0;
    }
    if (concealedBundleIdentifiers.count == 0) {
        @synchronized (self) {
            self.activationState = 1;
        }
        return token;
    }

    NSSet<NSString *> *concealed = [NSSet setWithArray:concealedBundleIdentifiers];
    NSMutableOrderedSet<NSString *> *allowedBundles = [NSMutableOrderedSet orderedSet];
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *bundleIdentifier = application.bundleIdentifier;
        if (bundleIdentifier.length &&
            ![concealed containsObject:bundleIdentifier.lowercaseString]) {
            [allowedBundles addObject:bundleIdentifier];
        }
    }
    [allowedBundles addObject:@"com.apple.systemuiserver"];
    [allowedBundles addObject:@"com.apple.finder"];
    [allowedBundles addObject:@"com.apple.dock"];
    [allowedBundles addObject:@"com.mabryventures.Barline.ArrangementObserver"];
    [allowedBundles addObject:@"com.mabryventures.Barline.VisibilityProbe"];

    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    SEL configurationInitializer = NSSelectorFromString(
        @"initWithAllowedSystemItems:allowedBundleIdentifiers:"
    );
    SEL activationSelector = NSSelectorFromString(
        @"activateWithConfiguration:completionHandler:"
    );
    SEL invalidationSelector = NSSelectorFromString(@"invalidate");
    NSArray<NSNumber *> *allowedSystemItems = @[@0, @1, @2, @3, @4, @5, @6, @7, @8];

    id allocation = ((id (*)(id, SEL))objc_msgSend)(configurationClass, @selector(alloc));
    id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)(
        allocation,
        configurationInitializer,
        allowedSystemItems,
        allowedBundles.array
    );
    id candidate = ((id (*)(id, SEL))objc_msgSend)(assertionClass, @selector(new));
    if (!configuration || !candidate) {
        [self abort:token];
        return 0;
    }

    @synchronized (self) {
        if (self.pendingToken != token || self.pendingAssertion) {
            ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
            [self abort:token];
            return 0;
        }
        self.pendingAssertion = candidate;
    }

    __weak BLNLabAssessmentController *weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        BLNLabAssessmentController *strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized (strongSelf) {
            if (strongSelf.pendingToken != token || strongSelf.pendingAssertion != candidate) return;
            if (error) {
                strongSelf.pendingAssertion = nil;
                strongSelf.activationState = -1;
            } else {
                strongSelf.activationState = 1;
            }
        }
        if (error) {
            ((void (*)(id, SEL))objc_msgSend)(candidate, invalidationSelector);
        }
    };
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            candidate,
            activationSelector,
            configuration,
            completion
        );
    } @catch (__unused NSException *exception) {
        [self abort:token];
        return 0;
    }
    return token;
}

- (int32_t)state:(uint64_t)token {
    @synchronized (self) {
        if (token == 0 || self.pendingToken != token) return -2;
        return self.activationState;
    }
}

- (BOOL)commit:(uint64_t)token {
    id previous = nil;
    @synchronized (self) {
        if (token == 0 || self.pendingToken != token || self.activationState != 1) return NO;
        previous = self.assertion;
        self.assertion = self.pendingClearsAssertion ? nil : self.pendingAssertion;
        self.pendingAssertion = nil;
        self.pendingToken = 0;
        self.pendingClearsAssertion = NO;
        self.activationState = -2;
    }
    if (previous) {
        ((void (*)(id, SEL))objc_msgSend)(previous, NSSelectorFromString(@"invalidate"));
    }
    return YES;
}

- (BOOL)abort:(uint64_t)token {
    id pending = nil;
    @synchronized (self) {
        if (token == 0 || self.pendingToken != token) return NO;
        pending = self.pendingAssertion;
        self.pendingAssertion = nil;
        self.pendingToken = 0;
        self.pendingClearsAssertion = NO;
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
        self.pendingClearsAssertion = NO;
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

void *BLNLabAssessmentCreate(void) {
    if (!BLNLabRuntimeAvailable()) return NULL;
    return (__bridge_retained void *)[BLNLabAssessmentController new];
}

uint64_t BLNLabAssessmentBegin(void *opaque, CFArrayRef concealed) {
    BLNLabAssessmentController *controller = (__bridge BLNLabAssessmentController *)opaque;
    NSArray<NSString *> *identifiers = (__bridge NSArray<NSString *> *)concealed;
    return [controller begin:[identifiers valueForKey:@"lowercaseString"]];
}

int32_t BLNLabAssessmentState(void *opaque, uint64_t token) {
    return [(__bridge BLNLabAssessmentController *)opaque state:token];
}

bool BLNLabAssessmentCommit(void *opaque, uint64_t token) {
    return [(__bridge BLNLabAssessmentController *)opaque commit:token];
}

bool BLNLabAssessmentAbort(void *opaque, uint64_t token) {
    return [(__bridge BLNLabAssessmentController *)opaque abort:token];
}

void BLNLabAssessmentInvalidate(void *opaque) {
    [(__bridge BLNLabAssessmentController *)opaque invalidate];
}

void BLNLabAssessmentDestroy(void *opaque) {
    CFBridgingRelease(opaque);
}
