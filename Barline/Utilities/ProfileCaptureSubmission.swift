//
//  ProfileCaptureSubmission.swift
//  Barline
//

import Combine
import Foundation

/// Owns UI admission independently of ProfileManager's serialized operations.
@MainActor
final class ProfileCaptureSubmission: ObservableObject {
    @Published private(set) var isSubmitting = false

    /// Snapshot the submitted draft and close admission before scheduling work.
    /// The name field can remain editable without changing the in-flight name.
    func submit(
        name: String,
        whenAllowed: Bool,
        operation: @escaping @MainActor (String) async -> Void
    ) {
        guard whenAllowed, !isSubmitting,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            await operation(name)
        }
    }
}
