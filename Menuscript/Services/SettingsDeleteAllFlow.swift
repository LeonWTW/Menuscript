import Foundation

/// Deterministic orchestration seam for Settings' destructive delete-all
/// action. Presentation side effects happen only after persistence succeeds;
/// any fetch/save error escapes without dismissing or notifying navigation.
@MainActor
enum SettingsDeleteAllFlow {
    @discardableResult
    static func perform(
        deleteAll: () throws -> Int,
        dismiss: () -> Void,
        onSucceeded: () -> Void
    ) throws -> Int {
        let deletedCount = try deleteAll()
        dismiss()
        onSucceeded()
        return deletedCount
    }
}
