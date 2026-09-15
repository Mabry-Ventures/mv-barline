#import <CoreFoundation/CoreFoundation.h>
#import <stdbool.h>

void * _Nullable BLNGoldenGateAssessmentCreate(void);
bool BLNGoldenGateAssessmentApply(
    void * _Nonnull opaqueController,
    CFArrayRef _Nonnull concealedBundleIdentifiers,
    CFArrayRef _Nonnull allowedSystemItemIdentifiers
);
int32_t BLNGoldenGateAssessmentActivationState(void * _Nonnull opaqueController);
void BLNGoldenGateAssessmentInvalidate(void * _Nonnull opaqueController);
void BLNGoldenGateAssessmentDestroy(void * _Nonnull opaqueController);
