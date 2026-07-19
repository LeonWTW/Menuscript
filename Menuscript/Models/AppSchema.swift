import SwiftData

/// Shared schema construction for disk-backed tests and future migration-plan
/// wiring. The app currently relies on SwiftData's automatic lightweight
/// migration; lifecycle state and snapshot bytes are additive optional fields.
enum AppSchema {
    static var current: Schema {
        Schema([MenuSession.self, MenuItem.self])
    }
}
