// Declares the complete SwiftData model graph in one reusable place so tests
// and future migration code construct exactly the same database schema.

import SwiftData

/// Builds one shared database layout for the app and its tests. Keeping this
/// list centralized also gives future data upgrades a single reliable starting point.
enum AppSchema {
    /// Builds the current schema from the session model and its related menu items.
    static var current: Schema {
        Schema([MenuSession.self, MenuItem.self])
    }
}
