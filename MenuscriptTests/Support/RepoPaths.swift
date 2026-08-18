// Locates the repository root for tests that read checked-in files such as
// string catalogs, the privacy manifest, and source-contract scans.

import Foundation

/// A caseless namespace, matching the AppSchema pattern, for repository file locations.
enum RepoPaths {
    /// The repository root, found by walking up from this file until the XcodeGen
    /// manifest (project.yml) appears. Anchoring on a marker file instead of a
    /// fixed number of path components means moving any test file — or this
    /// helper itself — can never silently point file reads at the wrong
    /// directory: either the marker is found or the suite fails loudly here.
    static let root: URL = {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            let marker = candidate.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: marker.path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        preconditionFailure("project.yml not found above \(#filePath); cannot locate the repository root")
    }()
}
