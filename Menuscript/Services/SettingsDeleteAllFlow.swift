// Defines the order of work for Settings' “delete all history” confirmation.
// Navigation changes occur only after storage succeeds, preventing a failed deletion from looking successful.

import Foundation

/// Predictable coordinator for Settings' destructive delete-all
/// action. Presentation side effects happen only after persistence succeeds;
/// any fetch/save error escapes without dismissing or notifying navigation.
@MainActor
enum SettingsDeleteAllFlow {
    /// Runs deletion first, then dismisses the prompt and notifies navigation, returning the confirmed deleted count.
    /// A thrown storage error stops both presentation callbacks automatically.
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
