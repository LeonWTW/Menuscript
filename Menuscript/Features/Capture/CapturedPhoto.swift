// Defines the small value types that describe staged photo state, failures,
// user-facing capture issues, and accepted-versus-rejected additions.

import Foundation
import UIKit

/// One stable slot in the capture staging grid. Slots are reserved before an
/// asynchronous import starts, so completion order can never reorder photos or
/// make an in-flight page invisible to `canRecognize`.
struct CapturedPhoto: Identifiable {
    /// Tracks the lifecycle of one reserved slot and keeps failed work explicit
    /// instead of silently dropping a photo from the grid.
    enum State {
        case pending
        case ready(Data)
        case failed(CapturedPhotoFailure)
    }

    let id: UUID
    var preview: UIImage?
    var state: State

    /// Creates a stable slot, pending by default so async imports can reserve it
    /// before their data is available.
    init(id: UUID = UUID(), preview: UIImage? = nil, state: State = .pending) {
        self.id = id
        self.preview = preview
        self.state = state
    }

    /// Exposes JPEG bytes only after preparation has completed successfully.
    var jpegData: Data? {
        guard case .ready(let data) = state else { return nil }
        return data
    }

    /// Indicates whether this slot is still waiting for preparation.
    var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    /// Exposes the reason for a failed slot and returns nil for other states.
    var failure: CapturedPhotoFailure? {
        guard case .failed(let failure) = state else { return nil }
        return failure
    }

    /// Confirms that the slot contains non-empty data safe to submit.
    var isReady: Bool { jpegData?.isEmpty == false }
}

/// Technical reasons why one selected image could not become request-ready.
enum CapturedPhotoFailure: Error, Equatable, Sendable {
    case loadFailed
    case invalidImage
    case jpegEncodingFailed
}

/// User-level capture problems that the screen can explain and recover from.
enum CaptureIssue: Error, Equatable, Sendable {
    case photoLimitExceeded(maximum: Int, rejected: Int)
    case photosStillLoading(count: Int)
    case photoPreparationFailed(count: Int)
    case requestTooLarge(estimatedBytes: Int, limit: Int)

    /// Converts each issue and its relevant counts into localized guidance.
    var message: String {
        switch self {
        case .photoLimitExceeded(let maximum, let rejected):
            return L10n.string("最多只可以加入 %lld 張相；今次有 %lld 張未加入。", maximum, rejected)
        case .photosStillLoading(let count):
            return L10n.string("仲有 %lld 張相載入緊，等全部完成先可以辨識。", count)
        case .photoPreparationFailed(let count):
            return L10n.string("%lld 張相載入失敗", count)
                + L10n.string("。請刪除失敗嘅相，再重新揀選或拍攝。")
        case .requestTooLarge(_, let limit):
            let megabytes = Double(limit) / 1_000_000
            return L10n.string("相片資料太大（上限 %.0f MB）。請刪除部分相片再試。", megabytes)
        }
    }
}

/// Reports how many requested photos were accepted under the global limit.
struct PhotoAddResult: Equatable, Sendable {
    var accepted: Int
    var rejected: Int
}

/// Identifies slots reserved synchronously for a later asynchronous import.
struct PhotoReservation: Equatable, Sendable {
    var ids: [UUID]
    var rejected: Int
}
