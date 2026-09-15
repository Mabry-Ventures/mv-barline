//
//  LayoutBar.swift
//  Barline
//

import BarlineCore
import SwiftUI

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
    @ObservedObject var imageCache: MenuBarItemImageCache

    let section: MenuBarSection.Name

    private var backgroundShape: some InsettableShape {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .circular)
        }
    }

    var body: some View {
        if #available(macOS 27.0, *) {
            MenuBarInventoryBar(
                itemManager: appState.itemManager,
                section: section
            )
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            // Keep foreground and background inside the same SwiftUI
            // appearance environment. NSColor.controlBackgroundColor can
            // resolve as Aqua on macOS 27 while this window remains dark,
            // producing light labels on a light surface.
            .background(Color.primary.opacity(0.055))
            .containerShape(backgroundShape)
            .clipShape(backgroundShape)
            .contentShape([.interaction, .focusEffect], backgroundShape)
            .overlay {
                backgroundShape
                    .strokeBorder(.quaternary)
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
    @ObservedObject var itemManager: MenuBarItemManager

    let section: MenuBarSection.Name

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    var body: some View {
        if items.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.stableID) { item in
                        MenuBarInventoryItem(item: item)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 48)
            }
            .scrollIndicators(.hidden)
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
}

@available(macOS 27.0, *)
private struct MenuBarInventoryItem: View {
    let item: MenuBarItem

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
        HStack(spacing: 7) {
            if let applicationIcon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: fallbackSymbolName)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }

            Text(displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.075), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.secondary.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
    }
}
