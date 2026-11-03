import XCTest
@testable import Search

/// Sliding across the model menu's providers is browsing, not choosing:
/// a probe (which makes a throwaway session) may only start for the
/// provider the pointer comes to rest on, and not at all if it leaves
/// before then.
@MainActor
final class TabshModelsTests: XCTestCase {
    func testASlideAcrossProvidersOnlyProbesTheOneItRestsOn() async {
        let dwell = TabshProbeDwell(delay: .milliseconds(60))
        var fired: [String] = []

        for name in ["Claude Code", "Codex", "OpenCode"] {
            dwell.offer(name) { fired.append(name) }
        }
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(fired, ["OpenCode"])
    }

    func testLeavingBeforeTheDwellProbesNothing() async {
        let dwell = TabshProbeDwell(delay: .milliseconds(60))
        var fired: [String] = []

        dwell.offer("Claude Code") { fired.append("Claude Code") }
        dwell.cancel()
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertTrue(fired.isEmpty)
    }
}
