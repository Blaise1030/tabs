import XCTest
@testable import Search

/// What the recogniser says arrives twice — once being revised, once
/// settled — and only the settled words are typed anywhere. These pin the
/// little that decides what is typed: the joining, the revising, and a
/// finalization that comes again.
final class DictationTests: XCTestCase {
    func testSettledSegmentsJoinWithOneSpace() {
        var heard = HeardText()
        XCTAssertEqual(heard.settle("fix the login"), "fix the login")
        XCTAssertEqual(heard.settle("and then the crash"), "and then the crash")
        XCTAssertEqual(heard.shown, "fix the login and then the crash")
    }

    func testTheTailIsShownButNotSettled() {
        var heard = HeardText()
        heard.settle("open the")
        heard.revise("settings")
        XCTAssertEqual(heard.shown, "open the settings")
        XCTAssertEqual(heard.settled, "open the")
        XCTAssertEqual(heard.pending, "settings")
    }

    func testRevisingReplacesTheTailRatherThanAddingToIt() {
        var heard = HeardText()
        heard.revise("to")
        heard.revise("too")
        heard.revise("to the")
        XCTAssertEqual(heard.shown, "to the")
        XCTAssertNil(heard.settle(""))
        XCTAssertEqual(heard.shown, "")
    }

    /// A final result that arrives twice — a wedged recogniser, or a
    /// finalization repeated at the end — must not say it twice.
    func testTheSameSettledSegmentIsKeptOnce() {
        var heard = HeardText()
        XCTAssertEqual(heard.settle("run the tests"), "run the tests")
        XCTAssertNil(heard.settle("run the tests"))
        XCTAssertEqual(heard.shown, "run the tests")
    }

    /// A segment's words may come back with the whitespace a speaker left;
    /// what is typed is trimmed, and an empty one is not kept at all.
    func testSettledWordsAreTrimmed() {
        var heard = HeardText()
        XCTAssertEqual(heard.settle("  hello there  "), "hello there")
        XCTAssertNil(heard.settle("   "))
        XCTAssertEqual(heard.shown, "hello there")
    }

    /// Stopping without a final result leaves the tail unspoken: it was
    /// never settled, so it is not typed.
    func testDroppingTheTailKeepsOnlyWhatSettled() {
        var heard = HeardText()
        heard.settle("make a card")
        heard.revise("for the bug")
        heard.dropTail()
        XCTAssertEqual(heard.shown, "make a card")
        XCTAssertFalse(heard.isEmpty)
    }
}
