import Foundation

/// Commits a small group of data values to `UserDefaults` and verifies the
/// values by reading them back.
///
/// `UserDefaults.synchronize()` is not a transaction acknowledgement. Current
/// macOS releases may return `false` after the process-visible values were
/// successfully written, so callers must not interpret that Boolean as a
/// failed commit. This helper treats exact read-back equality as the commit
/// boundary and restores the previous values if verification fails.
public enum VerifiedUserDefaultsDataCommit {
    public static func commit(
        _ values: [String: Data],
        to defaults: UserDefaults,
        synchronize: (() -> Bool)? = nil
    ) -> Bool {
        let previousValues = values.keys.reduce(into: [String: Data?]()) { result, key in
            result[key] = defaults.data(forKey: key)
        }

        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        _ = synchronize?() ?? defaults.synchronize()

        guard values.allSatisfy({ defaults.data(forKey: $0.key) == $0.value }) else {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            _ = synchronize?() ?? defaults.synchronize()
            return false
        }
        return true
    }
}
