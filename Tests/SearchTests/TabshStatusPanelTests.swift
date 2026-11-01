import XCTest
@testable import Search

/// The sessions panel's height: it fits its cards until the handle is pulled,
/// and holds the height it was left at after — a short list must not nail the
/// edge between the tab list and the sessions shut.
final class TabshStatusPanelTests: XCTestCase {
    private func card(id: String, agent: String? = nil, acp: String? = nil,
                      parent: String? = nil) -> Tabsh.SessionInfo {
        Tabsh.SessionInfo(id: id, name: "card \(id)", status: "backlog", statusAt: 0,
                          note: nil, cwd: "/tmp", agent: agent, acp: acp,
                          mode: "tui", parent: parent, pinned: false)
    }

    /// A plain terminal is a card on the daemon like any other, but it has
    /// no agent behind it: the Sessions panel leaves it to the tab list.
    func testOnlyAgentCardsAreListed() {
        let listed = TabshStatusPanel.listed([
            card(id: "terminal"),
            card(id: "agent", agent: "claude {prompt}"),
            card(id: "chat", acp: "opencode acp"),
            card(id: "half-typed", agent: "  "),
        ])
        XCTAssertEqual(listed.map(\.id), ["agent", "chat"])
    }

    /// A side terminal hangs off its card's row, agent or not.
    func testSideTerminalsAreNotRows() {
        let listed = TabshStatusPanel.listed([
            card(id: "side", agent: "claude {prompt}", parent: "agent"),
        ])
        XCTAssertTrue(listed.isEmpty)
    }

    func testBeforeTheHandleIsPulledThePanelFitsItsCards() {
        // The fit carries the handle as well as the cards.
        let height = TabshStatusPanel.panelHeight(stored: 400, byHand: false, content: 100)
        XCTAssertEqual(height, 7 + 100)
    }

    func testAFitNeverGrowsPastTheStoredHeight() {
        let height = TabshStatusPanel.panelHeight(stored: 200, byHand: false, content: 500)
        XCTAssertEqual(height, 200)
    }

    func testAPulledHeightHoldsEvenWhenTheListIsShort() {
        let height = TabshStatusPanel.panelHeight(stored: 320, byHand: true, content: 100)
        XCTAssertEqual(height, 320)
    }

    func testAPulledHeightStaysWithinItsBounds() {
        XCTAssertEqual(TabshStatusPanel.panelHeight(stored: 10, byHand: true, content: 0), 120)
        XCTAssertEqual(TabshStatusPanel.panelHeight(stored: 900, byHand: true, content: 0), 520)
    }
}
