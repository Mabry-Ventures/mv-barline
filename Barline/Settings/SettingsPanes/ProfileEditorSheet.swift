//
//  ProfileEditorSheet.swift
//  Barline
//

import BarlineCore
import SwiftUI

struct ProfileEditorSheet: View {
    let profile: BarlineProfile
    let canResetFromWorkspace: Bool
    let canPerformOperations: Bool
    let onSave: (String, String?, [ProfileGroup], [ProfileSpacer], [DisplayProfileOverride]) async -> Bool
    let onReset: () async -> Bool
    let onCapture: (BarlineProfile) async throws -> DisplayProfileOverride

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var groups: [ProfileGroup]
    @State private var spacers: [ProfileSpacer]
    @State private var variants: [DisplayProfileOverride]
    @State private var showsResetConfirmation = false
    @State private var isCapturing = false
    @State private var isSaving = false
    @State private var isResetting = false
    @State private var showsSaveFailure = false

    init(
        profile: BarlineProfile,
        canResetFromWorkspace: Bool,
        canPerformOperations: Bool,
        onSave: @escaping (String, String?, [ProfileGroup], [ProfileSpacer], [DisplayProfileOverride]) async -> Bool,
        onReset: @escaping () async -> Bool,
        onCapture: @escaping (BarlineProfile) async throws -> DisplayProfileOverride
    ) {
        self.profile = profile
        self.canResetFromWorkspace = canResetFromWorkspace
        self.canPerformOperations = canPerformOperations
        self.onSave = onSave
        self.onReset = onReset
        self.onCapture = onCapture
        _name = State(initialValue: profile.name)
        _symbol = State(initialValue: profile.symbol ?? "")
        _groups = State(initialValue: profile.groups)
        _spacers = State(initialValue: profile.spacers)
        _variants = State(initialValue: profile.displayOverrides)
    }

    private var itemIDs: [MenuBarItemID] {
        profile.layout.allItemIDs
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSymbol: String? {
        let value = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    LabeledContent("Symbol") {
                        HStack {
                            Image(systemName: normalizedSymbol ?? "menubar.rectangle")
                            TextField("SF Symbol", text: $symbol)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Groups") {
                    if groups.isEmpty {
                        Text("No groups")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        groupEditor(group)
                    }
                    Button("Add Group", systemImage: "plus") {
                        groups.append(ProfileGroup(name: "New Group", itemIDs: []))
                    }
                }

                Section("Spacers") {
                    if spacers.isEmpty {
                        Text("No spacers")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(spacers) { spacer in
                        spacerEditor(spacer)
                    }
                    Menu("Add Spacer", systemImage: "plus") {
                        ForEach(BarlineCore.MenuBarSection.allCases, id: \.self) { section in
                            Button("End of \(sectionLabel(section))") {
                                spacers.append(ProfileSpacer(placement: .end(section)))
                            }
                        }
                    }
                }

                DisplayVariantsEditor(variants: $variants, isCapturing: $isCapturing, canCapture: canResetFromWorkspace && canPerformOperations && !isResetting) {
                    var draft = profile
                    draft.groups = groups
                    draft.spacers = spacers
                    return try await onCapture(draft)
                }

                Section("Recovery") {
                    Button("Reset Profile from Current Workspace", role: .destructive) {
                        showsResetConfirmation = true
                    }
                    .disabled(!canResetFromWorkspace || !canPerformOperations || isCapturing || isResetting)
                    Text("Replaces this profile’s layout and modeled workspace settings, and removes its groups, spacers, and display overrides. Other profiles and app settings are preserved.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Layout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving || isResetting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard canPerformOperations, !isSaving, !isCapturing, !isResetting else { return }
                        isSaving = true
                        Task {
                            let saved = await onSave(normalizedName, normalizedSymbol, groups, spacers, variants)
                            isSaving = false
                            if saved {
                                dismiss()
                            } else {
                                showsSaveFailure = true
                            }
                        }
                    }
                    .disabled(
                        !canPerformOperations || isCapturing || isResetting || normalizedName.isEmpty || groups.contains {
                            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                    )
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving || isResetting)
        .alert("Couldn’t update this layout", isPresented: $showsSaveFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your draft is still here. Check local storage and make sure the layout has not changed elsewhere. A layout controlled by Focus must be released before its structure can be edited.")
        }
        .confirmationDialog(
            "Reset \(profile.name)?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Profile", role: .destructive) {
                guard canPerformOperations, !isSaving, !isCapturing, !isResetting else { return }
                isResetting = true
                Task {
                    let reset = await onReset()
                    isResetting = false
                    if reset {
                        dismiss()
                    } else {
                        showsSaveFailure = true
                    }
                }
            }
            .disabled(!canPerformOperations || isSaving || isCapturing || isResetting)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current validated layout and supported workspace settings will replace this profile.")
        }
    }

    @ViewBuilder
    private func groupEditor(_ group: ProfileGroup) -> some View {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            HStack {
                TextField("Group name", text: $groups[index].name)
                Menu("Items (\(groups[index].itemIDs.count))") {
                    ForEach(itemIDs, id: \.self) { itemID in
                        Button {
                            toggle(itemID, inGroupAt: index)
                        } label: {
                            if groups[index].itemIDs.contains(itemID) {
                                Label(itemLabel(itemID), systemImage: "checkmark")
                            } else {
                                Text(itemLabel(itemID))
                            }
                        }
                    }
                }
                Button(role: .destructive) {
                    groups.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete \(group.name) group")
            }
        }
    }

    @ViewBuilder
    private func spacerEditor(_ spacer: ProfileSpacer) -> some View {
        if let index = spacers.firstIndex(where: { $0.id == spacer.id }) {
            VStack(alignment: .leading) {
                HStack {
                    Text(spacerLabel(spacers[index].placement))
                    Spacer()
                    Stepper(
                        "\(Int(spacers[index].width)) pt",
                        value: $spacers[index].width,
                        in: 1 ... 160,
                        step: 1
                    )
                    Button(role: .destructive) {
                        spacers.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete spacer")
                }
                Menu("Change Placement") {
                    ForEach(BarlineCore.MenuBarSection.allCases, id: \.self) { section in
                        Button("Beginning of \(sectionLabel(section))") {
                            spacers[index].placement = .beginning(section)
                        }
                        Button("End of \(sectionLabel(section))") {
                            spacers[index].placement = .end(section)
                        }
                    }
                    if !itemIDs.isEmpty {
                        Divider()
                        ForEach(itemIDs, id: \.self) { itemID in
                            Button("After \(itemLabel(itemID))") {
                                spacers[index].placement = .after(itemID)
                            }
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func toggle(_ itemID: MenuBarItemID, inGroupAt index: Int) {
        if let memberIndex = groups[index].itemIDs.firstIndex(of: itemID) {
            groups[index].itemIDs.remove(at: memberIndex)
        } else {
            groups[index].itemIDs.append(itemID)
        }
    }

    private func itemLabel(_ itemID: MenuBarItemID) -> String {
        itemID.alias ?? itemID.title ?? itemID.accessibilityIdentifier ?? itemID.bundleIdentifier
    }

    private func sectionLabel(_ section: BarlineCore.MenuBarSection) -> String {
        switch section {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }

    private func spacerLabel(_ placement: ProfileSpacer.Placement) -> String {
        switch placement {
        case let .beginning(section): "Beginning of \(sectionLabel(section))"
        case let .after(itemID): "After \(itemLabel(itemID))"
        case let .end(section): "End of \(sectionLabel(section))"
        }
    }
}
