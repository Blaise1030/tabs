import AppKit
import XCTest
@testable import Search

/// A card's status, moved by the agent's hooks, has to land on the open
/// tab's badge (`tab.tabsh`, which `TabshTabMark` draws): through the list
/// the daemon hands over, through a board event on the socket, and through
/// a move made in this window, which must not wait for the socket's echo.
@MainActor
final class TabshTabStatusTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tabsh-tab-status-\(getpid())", 1)
        super.setUp()
    }

    private func card(id: String, status: String) -> Tabsh.SessionInfo {
        Tabsh.SessionInfo(id: id, name: "card \(id)", status: status, statusAt: 0,
                          note: nil, cwd: "/tmp", agent: "claude {prompt}", acp: nil,
                          mode: "tui", parent: nil, pinned: false)
    }

    private func event(id: String, status: String) -> Data {
        Data("""
        {"id":"\(id)","status":"\(status)","status_at":42,"note":null,"source":"hook"}
        """.utf8)
    }

    func testCardStatusReachesTheTabsBadge() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let board = TabshSessions()
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        let id = "tabsh-tab-status-\(UUID().uuidString)"
        // The tab is made here rather than through `Browser.show`, whose
        // attach asks the shared board for its list — a card this test
        // invented is not on it, and its orphan sweep would close the tab.
        browser.newTab()
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.show(InternalPage(.tabsh, id))
        XCTAssertEqual(tab.tabshSessionID, id)

        board.install([card(id: id, status: "backlog")])
        XCTAssertEqual(tab.tabsh?.state, .backlog)

        board.applyBoardEvent(event(id: id, status: "needs_input"))
        XCTAssertEqual(board.sessions[id]?.state, .needsInput)
        XCTAssertEqual(tab.tabsh?.state, .needsInput)

        // A move made here updates the tab at once, not on the echo.
        board.move(id, to: .completed)
        XCTAssertEqual(tab.tabsh?.state, .completed)

        // Archiving from any status closes the tab; the card stays listed.
        board.move(id, to: .archived)
        XCTAssertEqual(board.sessions[id]?.state, .archived)
        XCTAssertFalse(browser.tabs.contains(where: { $0.tabshSessionID == id }))
        XCTAssertFalse(browser.parkedTabs.contains(where: { $0.tabshSessionID == id }))
    }

    func testBoardEventArchivingClosesTheTab() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let board = TabshSessions()
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        let id = "tabsh-tab-archive-\(UUID().uuidString)"
        browser.newTab()
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.show(InternalPage(.tabsh, id))

        board.install([card(id: id, status: "in_progress")])
        XCTAssertTrue(browser.tabs.contains(where: { $0.tabshSessionID == id }))

        board.applyBoardEvent(event(id: id, status: "archived"))
        XCTAssertEqual(board.sessions[id]?.state, .archived)
        XCTAssertFalse(browser.tabs.contains(where: { $0.tabshSessionID == id }))
        XCTAssertFalse(browser.parkedTabs.contains(where: { $0.tabshSessionID == id }))
    }
}
