// Defines how long original menu photos are kept before they are pruned and
// converts the saved preference into one concrete retention window.

import Foundation

/// A stable, storable choice for how long a completed session's original photos are kept.
enum PhotoRetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case days30 = "30d"
    case days90 = "90d"
    case forever = "forever"

    /// Uses the stored value as the stable identity shown in pickers.
    var id: String { rawValue }

    /// Seconds original photos are kept before pruning; `nil` means keep forever.
    /// Fixed 86,400-second days keep the boundary deterministic for tests, and
    /// daylight-saving drift is immaterial against a window measured in months.
    var retentionWindow: TimeInterval? {
        switch self {
        case .days30:
            return 30 * 86_400
        case .days90:
            return 90 * 86_400
        case .forever:
            return nil
        }
    }

    /// Reads the saved preference and safely falls back to the 30-day default
    /// when the value is missing or comes from an unknown app version.
    static func resolve(from defaults: UserDefaults = .standard) -> PhotoRetentionPolicy {
        PhotoRetentionPolicy(rawValue: defaults.string(forKey: SettingsKeys.photoRetention) ?? "") ?? .days30
    }
}
