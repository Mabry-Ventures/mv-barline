//
//  LayoutBar.swift
//  Barline
//

import BarlineCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct LayoutBar: View {
    private struct Representable: NSViewRepresentable {
        let appState: AppState
        let section: MenuBarSection.Name

        func makeNSView(context _: Context) -> LayoutBarScrollView {
            LayoutBarScrollView(appState: appState, section: section)
        }

        func updateNSView(_: LayoutBarScrollView, context _: Context) {}
    }

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var imageCache: MenuBarItemImageCache

    let section: MenuBarSection.Name

    private var backgroundShape: some InsettableShape {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .circular)
        }
    }

    private var inventoryBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.17, blue: 0.17)
            : Color(red: 0.95, green: 0.95, blue: 0.96)
    }

    private var inventoryBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.12)
    }

    var body: some View {
        if #available(macOS 27.0, *) {
            MenuBarInventoryBar(
                itemManager: appState.itemManager,
                section: section,
                colorScheme: colorScheme
            )
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            // macOS 27 can resolve semantic foreground and background styles
            // against different effective appearances inside Settings. Use an
            // explicit, opaque pair so labels can never disappear into the bar.
            .background(inventoryBackground)
            .containerShape(backgroundShape)
            .clipShape(backgroundShape)
            .contentShape([.interaction, .focusEffect], backgroundShape)
            .overlay {
                backgroundShape
                    .strokeBorder(inventoryBorder)
            }
        } else {
            mainContent
                .frame(height: 48)
                .frame(maxWidth: .infinity)
                .menuBarItemContainer(appState: appState)
                .containerShape(backgroundShape)
                .clipShape(backgroundShape)
                .contentShape([.interaction, .focusEffect], backgroundShape)
                .overlay {
                    backgroundShape
                        .strokeBorder(.quaternary)
                }
        }
    }

    private var mainContent: some View {
        // Item capture is an enhancement, not a prerequisite for inventory.
        // LayoutBarItemView supplies a deterministic fallback icon when an item
        // has no cached image, so keep the discovered inventory visible.
        Representable(appState: appState, section: section)
    }
}

@available(macOS 27.0, *)
private struct MenuBarInventoryBar: View {
    private struct AssignmentEntry: Identifiable {
        let item: MenuBarItem
        let assignmentGroupSize: Int

        var id: MenuBarItemID { item.stableID }
    }

    @ObservedObject var itemManager: MenuBarItemManager

    let section: MenuBarSection.Name
    let colorScheme: ColorScheme

    @State private var isDropTargeted = false
    @State private var assignmentFailed = false
    @State private var assignmentFailureMessage = ""

    private var emptyForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.65) : Color.black.opacity(0.58)
    }

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    /// macOS 27 assigns third-party visibility at application-bundle
    /// granularity. Present one explicit control for a multi-item publisher so
    /// the UI never implies that one of its sibling status items can move by
    /// itself.
    private var assignmentEntries: [AssignmentEntry] {
        let allItems = itemManager.itemCache.managedItems
        var representedBundles = Set<String>()
        return items.compactMap { item in
            let normalizedBundleIdentifier = item.stableID.bundleIdentifier.lowercased()
            guard !normalizedBundleIdentifier.hasPrefix("com.apple.") else {
                return AssignmentEntry(item: item, assignmentGroupSize: 1)
            }
            let groupSize = allItems.count {
                $0.stableID.bundleIdentifier.caseInsensitiveCompare(
                    item.stableID.bundleIdentifier
                ) == .orderedSame
            }
            guard groupSize > 1 else {
                return AssignmentEntry(item: item, assignmentGroupSize: 1)
            }
            guard representedBundles.insert(normalizedBundleIdentifier).inserted else {
                return nil
            }
            return AssignmentEntry(item: item, assignmentGroupSize: groupSize)
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(emptyForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(assignmentEntries) { entry in
                            MenuBarInventoryItem(
                                item: entry.item,
                                assignmentGroupSize: entry.assignmentGroupSize,
                                colorScheme: colorScheme,
                                canAssign: entry.item.isMovable &&
                                    (section != .visible || entry.item.canBeHidden),
                                onAssign: { assign(entry.item.stableID) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 48)
                }
                .scrollIndicators(.hidden)
            }
        }
        .contentShape(Rectangle())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .dropDestination(for: MenuBarLayoutTransfer.self) { transfers, _ in
            guard let transfer = transfers.first else { return false }
            Task { @MainActor in
                await assign(transfer.itemID, to: section)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .alert("Layout could not be changed", isPresented: $assignmentFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(assignmentFailureMessage)
        }
    }

    private var emptyMessage: String {
        switch section {
        case .visible:
            "No visible items"
        case .hidden:
            "No hidden items"
        case .alwaysHidden:
            "No always-hidden items"
        }
    }

    private func assign(_ itemID: MenuBarItemID) {
        let destination: MenuBarSection.Name = section == .visible ? .hidden : .visible
        Task { @MainActor in
            await assign(itemID, to: destination)
        }
    }

    @MainActor
    private func assign(_ itemID: MenuBarItemID, to destination: MenuBarSection.Name) async {
        do {
            try await itemManager.assign(
                itemID: itemID,
                to: destination,
                index: itemManager.itemCache.managedItems(for: destination).count
            )
        } catch {
            assignmentFailureMessage = MenuBarAssignmentFailurePresentation.message(for: error)
            assignmentFailed = true
        }
    }
}

@available(macOS 27.0, *)
private struct MenuBarInventoryItem: View {
    let item: MenuBarItem
    let assignmentGroupSize: Int
    let colorScheme: ColorScheme
    let canAssign: Bool
    let onAssign: () -> Void

    private var foregroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.84)
    }

    private var secondaryColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.65) : Color.black.opacity(0.58)
    }

    private var capsuleColor: Color {
        colorScheme == .dark
            ? Color(red: 0.27, green: 0.24, blue: 0.24)
            : Color.white
    }

    private var capsuleBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.14)
    }

    private var displayName: String {
        item.isControlItem ? "Barline" : item.displayName
    }

    private var applicationIcon: NSImage? {
        guard item.isControlItem || !item.stableID.bundleIdentifier.hasPrefix("com.apple.") else {
            return nil
        }
        return item.sourceApplication?.icon ?? item.owningApplication?.icon
    }

    private var fallbackSymbolName: String {
        MenuBarInventoryPresentation.fallbackSymbolName(
            displayName: displayName,
            title: item.title
        )
    }

    var body: some View {
        Button(action: onAssign) {
            HStack(spacing: 7) {
                if let applicationIcon {
                    Image(nsImage: applicationIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: fallbackSymbolName)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(secondaryColor)
                        .frame(width: 20, height: 20)
                }

                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)

                if assignmentGroupSize > 1 {
                    Text("\(assignmentGroupSize)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(secondaryColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(capsuleColor, in: Capsule())
            .overlay {
                Capsule().strokeBorder(capsuleBorder)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(assignmentHint)
        .draggable(MenuBarLayoutTransfer(itemID: item.stableID))
        .help(canAssign ? assignmentHint : "This item cannot be moved independently")
        .disabled(!canAssign)
    }

    private var accessibilityLabel: String {
        guard assignmentGroupSize > 1 else { return displayName }
        return "\(displayName), \(assignmentGroupSize) menu bar items"
    }

    private var assignmentHint: String {
        guard assignmentGroupSize > 1 else {
            return "Click or drag to move this item to the other visibility section"
        }
        return "Click or drag to move all \(assignmentGroupSize) \(displayName) items to the other visibility section"
    }
}

@available(macOS 27.0, *)
private struct MenuBarLayoutTransfer: Codable, Transferable {
    let itemID: MenuBarItemID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .barlineLayoutItem)
    }
}

private extension UTType {
    static let barlineLayoutItem = UTType(
        exportedAs: "com.mabryventures.Barline.layout-bar-item"
    )
}
