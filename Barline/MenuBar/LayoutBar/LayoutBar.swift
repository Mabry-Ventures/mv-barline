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
    @ObservedObject var itemManager: MenuBarItemManager

    let section: MenuBarSection.Name
    let colorScheme: ColorScheme

    private var emptyForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.65) : Color.black.opacity(0.58)
    }

    private var items: [MenuBarItem] {
        itemManager.itemCache.managedItems(for: section)
    }

    var body: some View {
        if items.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(emptyForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.stableID) { item in
                        MenuBarInventoryItem(item: item, colorScheme: colorScheme)
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
    let colorScheme: ColorScheme

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
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(capsuleColor, in: Capsule())
        .overlay {
            Capsule().strokeBorder(capsuleBorder)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
    }
}
