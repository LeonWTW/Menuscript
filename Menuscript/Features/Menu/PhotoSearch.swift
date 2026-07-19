import Foundation

/// Builds a Google Images search URL for a dish so the user can see roughly what
/// it looks like. Operates on a plain query string with no SwiftUI or networking
/// dependency, so it can be unit tested directly.
enum PhotoSearch {
    /// Google Images (`tbm=isch`) search URL for `query`, or nil when `query` is
    /// blank after trimming whitespace and newlines. Non-ASCII characters (e.g.
    /// CJK dish names) are percent-encoded by `URLComponents` when the URL is built.
    static func imagesURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "tbm", value: "isch"),
        ]
        return components.url
    }
}
