import Foundation

/// Hard safety limits shared by every capture entry point. The provider also
/// performs its own final serialized-body check; this earlier estimate keeps
/// an obviously oversized request from reaching the networking layer at all.
enum CaptureLimits {
    static let maxPhotoCount = 6
    static let maxSerializedRequestBytes = 18_000_000

    /// Conservative allowance for the prompt, response schema, JSON keys and
    /// the rest of the request outside the base64 image parts.
    private static let nonImageRequestAllowance = 128_000
    private static let perImageJSONAllowance = 128

    static func estimatedSerializedRequestBytes(imageData: [Data]) -> Int {
        imageData.reduce(nonImageRequestAllowance) { total, data in
            let base64Length = ((data.count + 2) / 3) * 4
            return total + base64Length + perImageJSONAllowance
        }
    }

    static func isWithinRequestBudget(estimatedBytes: Int) -> Bool {
        estimatedBytes <= maxSerializedRequestBytes
    }

    static func isWithinRequestBudget(imageData: [Data]) -> Bool {
        isWithinRequestBudget(estimatedBytes: estimatedSerializedRequestBytes(imageData: imageData))
    }
}
