#import <AppKit/AppKit.h>
#define BARLINE_BRIDGE_TESTING 1

@interface MBAssessmentModeConfiguration : NSObject
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                  allowedBundleIdentifiers:(NSArray<NSString *> *)identifiers;
@end

@implementation MBAssessmentModeConfiguration
- (instancetype)initWithAllowedSystemItems:(__unused NSArray<NSNumber *> *)items
                  allowedBundleIdentifiers:(__unused NSArray<NSString *> *)identifiers {
    return [super init];
}
@end


@interface MBAssessmentModeAssertion : NSObject
- (void)activateWithConfiguration:(id)configuration
                completionHandler:(void (^)(NSError * _Nullable error))completion;
- (void)invalidate;
@end

@implementation MBAssessmentModeAssertion
- (void)activateWithConfiguration:(__unused id)configuration
                completionHandler:(void (^)(NSError * _Nullable error))completion {
    completion(nil);
}
- (void)invalidate {}
@end

#import "../../BarlineMenuService/GoldenGateAssessmentModeBridge.m"

@interface BLNTestAssertion : NSObject
@property(nonatomic) BOOL invalidated;
@end

@implementation BLNTestAssertion
- (void)invalidate { self.invalidated = YES; }
@end

static void BLNRequire(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        BLNGoldenGateAssessmentForceRuntimeMisses(1);
        BLNRequire(BLNGoldenGateAssessmentCreate() == NULL,
                   @"transient runtime miss rejects the first acquisition");
        void *recoveredController = BLNGoldenGateAssessmentCreate();
        BLNRequire(recoveredController != NULL,
                   @"runtime acquisition recovers after a transient miss");
        BLNGoldenGateAssessmentDestroy(recoveredController);

        BLNGoldenGateAssessmentController *controller = [BLNGoldenGateAssessmentController new];
        BLNTestAssertion *accepted = [BLNTestAssertion new];
        BLNTestAssertion *aborted = [BLNTestAssertion new];
        controller.assertion = accepted;
        controller.pendingAssertion = aborted;
        controller.pendingToken = 11;
        controller.activationState = 0;

        BLNRequire([controller abortToken:11], @"pending transaction aborts");
        BLNRequire(controller.assertion == accepted, @"abort preserves accepted assertion");
        BLNRequire(aborted.invalidated, @"abort invalidates pending candidate");
        [controller acknowledgeCandidate:aborted token:11 error:nil];
        BLNRequire(controller.assertion == accepted, @"late success cannot commit after abort");
        BLNRequire(![controller commitToken:11], @"stale token cannot commit");

        BLNTestAssertion *replacement = [BLNTestAssertion new];
        controller.pendingAssertion = replacement;
        controller.pendingToken = 12;
        controller.activationState = 0;
        [controller acknowledgeCandidate:replacement token:12 error:nil];
        BLNRequire(controller.activationState == 1, @"accepted callback becomes ready");
        BLNRequire(controller.assertion == accepted, @"ready callback does not commit");
        BLNRequire([controller commitToken:12], @"ready token commits");
        BLNRequire(controller.assertion == replacement, @"commit swaps accepted assertion");
        BLNRequire(accepted.invalidated, @"commit invalidates prior assertion");

        BLNTestAssertion *rejected = [BLNTestAssertion new];
        controller.pendingAssertion = rejected;
        controller.pendingToken = 13;
        controller.activationState = 0;
        NSError *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
        [controller acknowledgeCandidate:rejected token:13 error:error];
        BLNRequire(controller.activationState == -1, @"rejection remains observable");
        BLNRequire(controller.assertion == replacement, @"rejection preserves accepted assertion");
        BLNRequire(rejected.invalidated, @"rejection invalidates candidate");
        BLNRequire([controller abortToken:13], @"rejected transaction can be cleared");

        controller.pendingToken = 14;
        controller.pendingClearsCurrentAssertion = YES;
        controller.activationState = 1;
        BLNRequire([controller commitToken:14], @"clear transaction commits");
        BLNRequire(controller.assertion == nil, @"clear transaction removes accepted assertion");
        BLNRequire(replacement.invalidated, @"clear transaction invalidates prior assertion");
        BLNRequire(![controller abortToken:14], @"committed token cannot abort");
    }
    puts("PASS: Golden Gate assertion transactions preserve accepted state across abort, rejection, and late callbacks");
    return 0;
}
