import XCTest
@testable import Search

/// Internal addresses round-trip through the session: a camelCase host that
/// used to be lowercased away must still open as New Agent after a restart.
final class InternalPageTests: XCTestCase {
    func testAgentComposerParsesLegacyCamelCaseHost() {
        let url = URL(string: "search://agentComposer")!
        let page = InternalPage(url: url)
        XCTAssertEqual(page?.kind, .agentComposer)
        XCTAssertEqual(page?.title, "New Agent")
    }

    func testAgentComposerParsesLowercasedHost() {
        let url = URL(string: "search://agentcomposer")!
        XCTAssertEqual(InternalPage(url: url)?.kind, .agentComposer)
    }

    func testAgentComposerWritesKebabHost() {
        let url = InternalPage(.agentComposer).url
        XCTAssertEqual(url.absoluteString, "search://agent-composer")
        XCTAssertEqual(InternalPage(url: url)?.kind, .agentComposer)
    }

    func testSettingsStillParses() {
        let url = URL(string: "search://settings/privacy")!
        let page = InternalPage(url: url)
        XCTAssertEqual(page?.kind, .settings)
        XCTAssertEqual(page?.detail, "privacy")
    }
}
