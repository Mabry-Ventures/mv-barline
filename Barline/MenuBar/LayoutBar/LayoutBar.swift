//
//  LayoutBar.swift
//  Barline
//

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
                imageCache: imageCache,
                section: section
            )
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
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
    @ObservedObject var imageCache: MenuBarItemImageCache

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
                        MenuBarInventoryItem(
                            item: item,
                            capturedImage: imageCache.images[item.stableID]
                        )
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
    let capturedImage: MenuBarItemImageCache.CapturedImage?

    private var displayName: String {
        item.isControlItem ? "Barline" : item.displayName
    }

    private var image: NSImage {
        capturedImage?.nsImage
            ?? item.sourceApplication?.icon
            ?? item.owningApplication?.icon
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: displayName)
            ?? NSImage()
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)

            Text(displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.secondary.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
    }
}
