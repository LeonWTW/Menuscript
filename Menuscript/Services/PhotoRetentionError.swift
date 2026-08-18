// Names photo-retention failures and explains that no original photos were lost.

import Foundation

/// Retention failures named by the step that could not be completed, so the
/// message can always tell the user what happened to their photos.
enum PhotoRetentionError: Error, LocalizedError, Equatable {
    case fetchFailed(String)
    case saveFailed(String)

    /// Provides localized explanations confirming that the original photos were kept.
    var errorDescription: String? {
        switch self {
        case .fetchFailed(let detail):
            return L10n.string("未能讀取菜單記錄，今次未有清理任何相片。（%@）", detail)
        case .saveFailed(let detail):
            return L10n.string("未能清理菜單相片，原有相片已保留。（%@）", detail)
        }
    }
}
