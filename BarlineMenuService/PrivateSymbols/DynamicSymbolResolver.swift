import Darwin
import Foundation
import os

/// Resolves unsupported WindowServer entry points without creating hard linker
/// dependencies. A missing entry point is a capability failure, never a crash.
final class DynamicSymbolResolver: @unchecked Sendable {
    private struct Storage: Sendable {
        var handles = [UInt]()
        var symbols = [String: UInt]()
        var missingSymbols = Set<String>()
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    private let libraryPaths: [String]

    init(libraryPaths: [String] = DynamicSymbolResolver.defaultLibraryPaths) {
        self.libraryPaths = libraryPaths
    }

    deinit {
        storage.withLock { storage in
            for handle in storage.handles {
                if let pointer = UnsafeMutableRawPointer(bitPattern: handle) {
                    dlclose(pointer)
                }
            }
            storage.handles.removeAll()
            storage.symbols.removeAll()
        }
    }

    func contains(_ symbol: String) -> Bool {
        rawSymbolAddress(named: symbol) != nil
    }

    func resolve<T>(_ symbol: String, as type: T.Type = T.self) -> T? {
        guard
            let address = rawSymbolAddress(named: symbol),
            let pointer = UnsafeMutableRawPointer(bitPattern: address)
        else {
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }

    private func rawSymbolAddress(named symbol: String) -> UInt? {
        storage.withLock { storage in
            if let cached = storage.symbols[symbol] {
                return cached
            }
            if storage.missingSymbols.contains(symbol) {
                return nil
            }

            if storage.handles.isEmpty {
                storage.handles = libraryPaths.compactMap { path in
                    dlopen(path, RTLD_NOW | RTLD_LOCAL).map { UInt(bitPattern: $0) }
                }
            }

            for address in storage.handles {
                guard let handle = UnsafeMutableRawPointer(bitPattern: address) else {
                    continue
                }
                if let pointer = dlsym(handle, symbol) {
                    let symbolAddress = UInt(bitPattern: pointer)
                    storage.symbols[symbol] = symbolAddress
                    return symbolAddress
                }
            }

            storage.missingSymbols.insert(symbol)
            return nil
        }
    }

    private static let defaultLibraryPaths = [
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
    ]
}
