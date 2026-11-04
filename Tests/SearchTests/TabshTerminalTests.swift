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

    /// An agent at work animates its title with a braille spinner (Claude
    /// Code and friends); that spin, not the words after it, is the signal.
    func testASpinnerTitleIsWorking() {
        XCTAssertEqual(TabshAgentActivity(title: "⠂ Fix the login crash"), .working)
        XCTAssertEqual(TabshAgentActivity(title: "⠋ Working…"), .working)
    }

    /// The still mark an agent leaves in its title at rest is Ready, even
    /// though no turn has finished — it must not read as Completed.
    func testAStillTitleIsReady() {
        XCTAssertEqual(TabshAgentActivity(title: "✳ Claude Code"), .ready)
        XCTAssertEqual(TabshAgentActivity(title: "✳ Fix the login crash"), .ready)
    }

    func testAWaitingTitleNeedsInput() {
        XCTAssertEqual(TabshAgentActivity(title: "Claude Code — waiting for input"), .needsInput)
        XCTAssertEqual(TabshAgentActivity(title: "Allow this command? (y/n)"), .needsInput)
    }

    /// A task summary that merely mentions permission is not a request for
    /// it: the still title stays Ready.
    func testATaskAboutPermissionIsNotARequest() {
        XCTAssertEqual(TabshAgentActivity(title: "✳ Fix the permission bug"), .ready)
    }

    /// A plain shell's title (user, host, folder) says nothing about an
    /// agent, so the header stays bare.
    func testAPlainShellTitleSaysNothing() {
        XCTAssertNil(TabshAgentActivity(title: "blaise@mac: ~/Developer/tabs-browser"))
        XCTAssertNil(TabshAgentActivity(title: "zsh"))
        XCTAssertNil(TabshAgentActivity(title: "  "))
    }

    func testAFreshSocketAsksForTheWholeScrollback() throws {
        let url = try XCTUnwrap(Tabsh.socketURL(session: "abc-1", token: "t"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(parts.queryItems?.first { $0.name == "resume" })
    }
}
