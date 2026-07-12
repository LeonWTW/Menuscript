import Foundation
import Testing
@testable import Menuscript

@Suite("PhotoSearch")
struct PhotoSearchTests {

    /// Re-parses a built URL so assertions read the actual wire form, not the
    /// inputs we passed in.
    private func parsedComponents(for query: String) throws -> URLComponents {
        let url = try #require(PhotoSearch.imagesURL(query: query))
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }

    private func value(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    @Test("Builds an https www.google.com /search URL")
    func schemeHostPath() throws {
        let components = try parsedComponents(for: "ramen")
        #expect(components.scheme == "https")
        #expect(components.host == "www.google.com")
        #expect(components.path == "/search")
    }

    @Test("Query carries the search term as q and the image-search flag tbm=isch")
    func queryItemsCarryTermAndImageFlag() throws {
        let components = try parsedComponents(for: "ramen")
        #expect(value("q", in: components) == "ramen")
        #expect(value("tbm", in: components) == "isch")
    }

    @Test("CJK dish name percent-encodes: round-trips intact and leaks no raw CJK scalars")
    func cjkPercentEncoded() throws {
        let dish = "宮保雞丁"
        let components = try parsedComponents(for: dish)
        // The decoded query item still equals the original dish name.
        #expect(value("q", in: components) == dish)
        // The raw wire form carries none of the dish's CJK scalars un-encoded.
        let encoded = try #require(components.percentEncodedQuery)
        for scalar in dish.unicodeScalars {
            #expect(!encoded.unicodeScalars.contains(scalar))
        }
        // The whole encoded query is ASCII, and encoding actually happened.
        #expect(encoded.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(encoded.contains(where: { $0 == "%" }))
    }

    @Test("Blank queries produce no URL", arguments: ["", "  ", "\n", " \t\n "])
    func blankQueryIsNil(input: String) {
        #expect(PhotoSearch.imagesURL(query: input) == nil)
    }

    @Test("Ampersand and equals in the term round-trip through query items")
    func ampersandAndEqualsRoundTrip() throws {
        let dish = "fish & chips = good"
        let components = try parsedComponents(for: dish)
        // The literal & and = are encoded within the value, so the term survives whole...
        #expect(value("q", in: components) == dish)
        // ...and tbm remains its own item rather than being swallowed by the literal &.
        #expect(value("tbm", in: components) == "isch")
    }

    @Test("Leading and trailing whitespace is trimmed from the term")
    func trimsSurroundingWhitespace() throws {
        let components = try parsedComponents(for: "  udon  ")
        #expect(value("q", in: components) == "udon")
    }
}
