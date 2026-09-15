#import <CoreFoundation/CoreFoundation.h>
#import <stdbool.h>

void * _Nullable BLNGoldenGateAssessmentCreate(void);
uint64_t BLNGoldenGateAssessmentBegin(
    void * _Nonnull opaqueController,
    CFArrayRef _Nonnull concealedBundleIdentifiers,
    CFArrayRef _Nonnull allowedSystemItemIdentifiers
);
int32_t BLNGoldenGateAssessmentActivationState(
    void * _Nonnull opaqueController,
    uint64_t transactionToken
);
bool BLNGoldenGateAssessmentCommit(
    void * _Nonnull opaqueController,
    uint64_t transactionToken
);
bool BLNGoldenGateAssessmentAbort(
    void * _Nonnull opaqueController,
    uint64_t transactionToken
);
void BLNGoldenGateAssessmentInvalidate(void * _Nonnull opaqueController);
void BLNGoldenGateAssessmentDestroy(void * _Nonnull opaqueController);
