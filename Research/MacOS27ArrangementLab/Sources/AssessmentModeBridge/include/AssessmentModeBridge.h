#ifndef AssessmentModeBridge_h
#define AssessmentModeBridge_h

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

void * _Nullable BLNLabAssessmentCreate(void);
uint64_t BLNLabAssessmentBegin(
    void * _Nonnull controller,
    CFArrayRef _Nonnull concealedBundleIdentifiers
);
int32_t BLNLabAssessmentState(void * _Nonnull controller, uint64_t token);
bool BLNLabAssessmentCommit(void * _Nonnull controller, uint64_t token);
bool BLNLabAssessmentAbort(void * _Nonnull controller, uint64_t token);
void BLNLabAssessmentInvalidate(void * _Nonnull controller);
void BLNLabAssessmentDestroy(void * _Nonnull controller);

#endif
