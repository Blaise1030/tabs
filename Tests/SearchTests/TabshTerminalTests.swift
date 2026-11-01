import XCTest
@testable import Search

/// The terminal's socket says where it left off, so a reattach can be sent
/// only the bytes it missed rather than the whole scrollback again.
final class TabshTerminalTests: XCTestCase {
    func testASocketNamesTheEpochAndOffsetItHasSeen() throws {
        let url = try XCTUnwrap(Tabsh.socketURL(session: "abc-1", token: "t",
                                                resume: ("e-1", 42)))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(parts.path, "/ws")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "id" }?.value, "abc-1")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "token" }?.value, "t")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "resume" }?.value, "e-1:42")
    }

    func testAFreshSocketAsksForTheWholeScrollback() throws {
        let url = try XCTUnwrap(Tabsh.socketURL(session: "abc-1", token: "t"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(parts.queryItems?.first { $0.name == "resume" })
    }
}
