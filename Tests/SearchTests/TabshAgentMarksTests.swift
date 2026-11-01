import AppKit
import XCTest
@testable import Search

final class TabshAgentMarksTests: XCTestCase {
    func testKnownAgentMarksLoadAsImages() {
        for brand in [TabshAgentBrand.claude, .openai, .gemini, .cursor] {
            XCTAssertNotNil(brand.image, "\(brand.rawValue) should draw from its path")
        }
    }

    func testUnknownAgentFallsBackToASymbol() {
        XCTAssertNil(TabshAgentBrand.agent.image)
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
