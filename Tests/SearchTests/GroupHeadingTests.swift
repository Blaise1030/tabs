import AppKit
import XCTest
@testable import Search

/// What a group heading's menu adds, without the menu: the three kinds of
/// tab land in the group they were asked from rather than loose at the end
/// of the row.
@MainActor
final class GroupHeadingTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "group-heading-\(getpid())", 1)
        super.setUp()
    }

    func testNewTabFromAHeadingJoinsItsGroup() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.usesTabGroups
        defer { browser.closeAll(); prefs.usesTabGroups = saved }
        prefs.usesTabGroups = true

        let first = try XCTUnwrap(browser.active)
        first.restore(url: URL(string: "https://example.com/first")!, title: "First")
        let group = browser.addTabGroup(containing: first)

        browser.newTab(in: group)
        let made = try XCTUnwrap(browser.active)
        XCTAssertNotEqual(made.id, first.id, "A second tab is made, not the one in the group reused")
        XCTAssertEqual(made.groupID, group)
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [first.id, made.id])
        XCTAssertEqual(made.draft, "", "It is an ordinary new tab, waiting for an address")
    }

    func testNewAgentFromAHeadingLeavesItsComposerInTheGroup() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.usesTabGroups
        defer { browser.closeAll(); prefs.usesTabGroups = saved }
        prefs.usesTabGroups = true

        let first = try XCTUnwrap(browser.active)
        first.restore(url: URL(string: "https://example.com/first")!, title: "First")
        let group = browser.addTabGroup(containing: first)

        browser.newAgentComposer(in: group)
        let composer = try XCTUnwrap(browser.pageTab(.agentComposer))
        XCTAssertEqual(browser.group(of: composer), group)
        XCTAssertEqual(browser.activeID, composer.id, "The composer is what you fill in")
    }
}
