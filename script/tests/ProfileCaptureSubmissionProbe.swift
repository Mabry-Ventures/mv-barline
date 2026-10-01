import Combine
import Foundation

/// Tests the production UI admission helper without launching or focusing an app.
@main
@MainActor
enum ProfileCaptureSubmissionProbe {
    @MainActor
    final class HeldOperation {
        private(set) var submittedName: String?
        private var continuation: CheckedContinuation<Void, Never>?

        func run(name: String) async {
            await withCheckedContinuation {
                submittedName = name
                continuation = $0
            }
        }

        func finish() {
            precondition(continuation != nil, "operation must be held before completion")
            continuation?.resume()
            continuation = nil
        }
    }

    enum SyntheticFailure: Error { case operationFailed }

    static func main() async {
        await snapshotAndDuplicates()
        await rejectedAdmission()
        await capturedFailureAndReadmission()
        print("PASS: production capture admission, snapshot, held state, duplicates, rejection, completion, and re-admission")
    }

    private static func eventually(_ message: String, _ condition: () -> Bool) async {
        for _ in 0 ..< 10000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        preconditionFailure(message)
    }

    private static func snapshotAndDuplicates() async {
        let submission = ProfileCaptureSubmission()
        let held = HeldOperation()
        var publications: [Bool] = []
        let observer = submission.$isSubmitting.sink { publications.append($0) }
        defer { observer.cancel() }
        var draft = "  Original  "
        var duplicateCalls = 0
        submission.submit(name: draft, whenAllowed: true) { await held.run(name: $0) }
        precondition(submission.isSubmitting && publications == [false, true], "admission must close synchronously")
        precondition(held.submittedName == nil, "operation must be scheduled, not invoked inline")
        draft = "Edited while capture is running"
        submission.submit(name: draft, whenAllowed: true) { _ in duplicateCalls += 1 }
        await eventually("accepted operation never started") { held.submittedName != nil }
        precondition(held.submittedName == "  Original  ", "capture must use the exact submitted name")
        precondition(draft == "Edited while capture is running", "completion must not clear the new draft")
        for _ in 0 ..< 20 {
            submission.submit(name: "duplicate", whenAllowed: true) { _ in duplicateCalls += 1 }
            await Task.yield()
        }
        precondition(duplicateCalls == 0 && submission.isSubmitting && publications == [false, true])
        held.finish()
        await eventually("success did not release admission") { !submission.isSubmitting }
        precondition(publications == [false, true, false])
        precondition(draft == "Edited while capture is running")
        var secondCalls = 0
        submission.submit(name: draft, whenAllowed: true) { name in
            precondition(name == "Edited while capture is running")
            secondCalls += 1
        }
        precondition(submission.isSubmitting)
        await eventually("completion did not reopen admission") { !submission.isSubmitting }
        precondition(secondCalls == 1 && publications == [false, true, false, true, false])
        print("PASS: synchronous admission, 21 duplicates rejected, exact snapshot, editable draft, success and re-admission")
    }

    private static func rejectedAdmission() async {
        let submission = ProfileCaptureSubmission()
        var publications: [Bool] = []
        let observer = submission.$isSubmitting.sink { publications.append($0) }
        defer { observer.cancel() }
        var calls = 0
        submission.submit(name: " \t\n ", whenAllowed: true) { _ in calls += 1 }
        submission.submit(name: "", whenAllowed: true) { _ in calls += 1 }
        submission.submit(name: "Valid", whenAllowed: false) { _ in calls += 1 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        precondition(calls == 0 && !submission.isSubmitting && publications == [false])
        print("PASS: blank and disallowed submissions have no operation or busy publication")
    }

    private static func failAfterHold(_ held: HeldOperation, name: String) async throws {
        await held.run(name: name)
        throw SyntheticFailure.operationFailed
    }

    private static func capturedFailureAndReadmission() async {
        let submission = ProfileCaptureSubmission()
        let held = HeldOperation()
        var publications: [Bool] = []
        let observer = submission.$isSubmitting.sink { publications.append($0) }
        defer { observer.cancel() }
        var failureWasHandled = false
        submission.submit(name: "Failure draft", whenAllowed: true) { name in
            // ProfileManager reports its error internally before returning.
            // The UI helper deliberately accepts a nonthrowing operation.
            do {
                try await failAfterHold(held, name: name)
            } catch SyntheticFailure.operationFailed {
                failureWasHandled = true
            } catch {
                preconditionFailure("unexpected synthetic failure")
            }
        }
        await eventually("failure operation never started") { held.submittedName != nil }
        precondition(submission.isSubmitting && !failureWasHandled)
        held.finish()
        await eventually("handled failure did not release admission") { !submission.isSubmitting }
        precondition(failureWasHandled && publications == [false, true, false])
        var recoveryCalls = 0
        submission.submit(name: "Recovery", whenAllowed: true) { _ in recoveryCalls += 1 }
        await eventually("failure blocked later admission") { !submission.isSubmitting }
        precondition(recoveryCalls == 1 && publications == [false, true, false, true, false])
        print("PASS: internally handled failure releases busy and permits the next submission")
    }
}
