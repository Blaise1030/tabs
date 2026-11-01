import AppKit
import XCTest
@testable import Search

final class TabshAgentMarksTests: XCTestCase {
    func testKnownAgentMarksLoadAsImages() {
        for brand in [TabshAgentBrand.claude, .openai, .gemini, .cursor, .opencode] {
            XCTAssertNotNil(brand.image, "\(brand.rawValue) should draw from its path")
        }
    }

    func testUnknownAgentFallsBackToASymbol() {
        XCTAssertNil(TabshAgentBrand.agent.image)
    }

    /// A card's mark comes from the commands it runs, never from its name:
    /// the name is the prompt's first line, and "Fix the agent panel" is not
    /// Cursor's `agent` CLI.
    func testACardsCommandsChooseItsMarkNotItsName() {
        func card(name: String, agent: String? = nil, acp: String? = nil) -> Tabsh.SessionInfo {
            Tabsh.SessionInfo(id: "s-1", name: name, status: "in_progress", statusAt: 0,
                              note: nil, cwd: nil, agent: agent, acp: acp,
                              mode: "ui", parent: nil, pinned: false)
        }

        XCTAssertEqual(card(name: "For the agent composer", acp: "opencode acp").brand, .opencode)
        XCTAssertEqual(card(name: "Fix Claude's icon", acp: "opencode acp").brand, .opencode)
        XCTAssertEqual(card(name: "For the agent composer", agent: "opencode --session {session}").brand,
                       .opencode)
        XCTAssertEqual(card(name: "A Cursor-shaped prompt", agent: "agent {prompt}").brand, .cursor)
        XCTAssertEqual(card(name: "Resume", agent: "cursor-agent {prompt}").brand, .cursor)
        XCTAssertEqual(card(name: "A Cursor-shaped prompt", agent: "muse {prompt}").brand, .agent)
        XCTAssertEqual(card(name: "Anything",
                            acp: "npx --yes @agentclientprotocol/claude-agent-acp").brand, .claude)
        XCTAssertEqual(card(name: "Anything",
                            acp: "npx --yes @agentclientprotocol/codex-acp").brand, .openai)
    }

    func testStatusBadgesCarryTheStatesThatWantSomething() {
        XCTAssertEqual(TabshStatus.needsInput.badgeSymbol, "questionmark")
        XCTAssertEqual(TabshStatus.completed.badgeSymbol, "checkmark")
        XCTAssertNil(TabshStatus.backlog.badgeSymbol)
        XCTAssertNil(TabshStatus.inProgress.badgeSymbol)
    }

    func testTypingPacksMatchTabshsSamples() {
        XCTAssertEqual(TypingSoundPack.mxBlackPBT.title, "Cherry MX Black (PBT)")
        XCTAssertNil(TypingSoundPack.mxBlackPBT.release)
        XCTAssertEqual(TypingSoundPack.mxBlue.release, "release")
        XCTAssertEqual(TypingSoundPack.holyPanda.specials, ["space", "enter", "back"])
        XCTAssertEqual(TypingSoundPack.off.specials, [])
    }

    func testTypingSamplesAreInTheBundle() {
        for pack in TypingSoundPack.allCases where pack != .off {
            XCTAssertNotNil(TypingSounds.sampleURL("press_key1", pack: pack),
                            "\(pack.rawValue) should carry its samples")
        }
    }
}
