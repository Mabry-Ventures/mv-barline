//
//  DisplayVariantsEditor.swift
//  Barline
//

import BarlineCore
import SwiftUI

struct DisplayVariantsEditor: View {
    @Binding var variants: [DisplayProfileOverride]
    @Binding var isCapturing: Bool
    let canCapture: Bool
    let capture: () async throws -> DisplayProfileOverride
    @State private var captureTask: Task<Void, Never>?
    @State private var pendingReplacement: DisplayProfileOverride?
    @State private var showsReplacement = false
    @State private var showsFailure = false

    var body: some View {
        Section("Display Variants") {
            Text("Arrange items on a display, then capture its menu bar here. The base layout and other displays are preserved. Changes are saved only when you click Save.")
                .foregroundStyle(.secondary)
            ForEach(Array(variants.enumerated()), id: \.element.displayID) { index, variant in
                DisclosureGroup("Display variant \(index + 1)") {
                    LabeledContent("Visible / hidden / always hidden", value: "\(variant.layout.visible.count) / \(variant.layout.hidden.count) / \(variant.layout.alwaysHidden.count)")
                    Text(variant.displayFingerprint == nil ? "Matched by display identifier" : "Matched by unique hardware identity on reconnect")
                        .foregroundStyle(.secondary)
                    Button("Remove Variant", role: .destructive) {
                        variants.removeAll { $0.displayID == variant.displayID }
                    }
                }
            }
            Button(isCapturing ? "Capturing…" : "Capture Current Menu Bar Display") {
                guard canCapture, !isCapturing else { return }
                isCapturing = true
                captureTask = Task { @MainActor in
                    defer { isCapturing = false }
                    do {
                        let variant = try await capture()
                        try Task.checkCancellation()
                        guard matchingIndices(variant).count <= 1 else { showsFailure = true; return }
                        if matchingIndex(variant) != nil {
                            pendingReplacement = variant
                            showsReplacement = true
                        } else {
                            variants.append(variant)
                        }
                    } catch where !Task.isCancelled {
                        showsFailure = true
                    } catch {
                        // The sheet was dismissed; never append to a discarded draft.
                    }
                }
            }
            .disabled(!canCapture || isCapturing)
            Text("The display containing the active menu bar is captured. Ambiguous, disconnected, or empty displays are never guessed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear { captureTask?.cancel() }
        .confirmationDialog("Replace the saved variant for this display?", isPresented: $showsReplacement) {
            Button("Replace Variant") {
                if let pendingReplacement, let index = matchingIndex(pendingReplacement) {
                    variants[index] = pendingReplacement
                }
                pendingReplacement = nil
            }
            Button("Cancel", role: .cancel) { pendingReplacement = nil }
        }
        .alert("Couldn’t capture this display", isPresented: $showsFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check Accessibility permission, close any open menu, and ensure this display has menu bar items. Your saved layout was not changed.")
        }
    }

    private func matchingIndex(_ variant: DisplayProfileOverride) -> Int? {
        let indices = matchingIndices(variant)
        return indices.count == 1 ? indices.first : nil
    }

    private func matchingIndices(_ variant: DisplayProfileOverride) -> [Int] {
        variants.indices.filter {
            variants[$0].displayID == variant.displayID ||
                (variant.displayFingerprint != nil && variants[$0].displayFingerprint == variant.displayFingerprint)
        }
    }
}
