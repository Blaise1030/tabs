import XCTest
@testable import Search

/// AgentNotify: which card moves are worth a Mac notification, and what one
/// says. A test run posts nothing (see Store.testing); it keeps what it would
/// have posted, which is what these read.
@MainActor
final class AgentNotifyTests: XCTestCase {
    private var prefs: Preferences { Shared.prefs }

    override func setUp() {
        super.setUp()
        AgentNotify.clearRecorded()
    }

    override func tearDown() {
        AgentNotify.clearRecorded()
        super.tearDown()
    }

    private func card(note: String? = nil) -> Tabsh.SessionInfo {
        Tabsh.SessionInfo(id: "s1", name: "Fix the login flow", status: "in_progress",
                          statusAt: 1, note: note, cwd: "/tmp/project",
                          agent: "claude", acp: nil, mode: "ui", parent: nil, pinned: false)
    }

    /// Keeps the switches as they were: these are the app's own prefs.
    private func switches(needs: Bool, done: Bool, background: Bool = false, sound: Bool = true,
                          _ body: () -> Void) {
        let before = (prefs.agentNotifyNeeds, prefs.agentNotifyDone,
                      prefs.agentNotifyBackground, prefs.agentNotifySound)
        defer {
            prefs.agentNotifyNeeds = before.0
            prefs.agentNotifyDone = before.1
            prefs.agentNotifyBackground = before.2
            prefs.agentNotifySound = before.3
        }
        prefs.agentNotifyNeeds = needs
        prefs.agentNotifyDone = done
        prefs.agentNotifyBackground = background
        prefs.agentNotifySound = sound
        body()
    }

    func testNeedsInputSaysSoWithTheCardAndItsAgent() {
        switches(needs: true, done: true) {
            AgentNotify.moved(card(), to: .needsInput)
        }
        XCTAssertEqual(AgentNotify.recorded.count, 1)
        XCTAssertEqual(AgentNotify.recorded.first?["title"], "Fix the login flow")
        XCTAssertEqual(AgentNotify.recorded.first?["body"], "Needs input")
        XCTAssertEqual(AgentNotify.recorded.first?["session"], "s1")
    }

    func testTheHooksNoteIsWhatTheNotificationSays() {
        switches(needs: true, done: false) {
            AgentNotify.moved(card(note: "Which branch should I use?"), to: .needsInput)
        }
        XCTAssertEqual(AgentNotify.recorded.first?["body"], "Which branch should I use?")
    }

    func testFinishedSaysFinished() {
        switches(needs: false, done: true) {
            AgentNotify.moved(card(), to: .completed)
        }
        XCTAssertEqual(AgentNotify.recorded.first?["body"], "Finished")
    }

    func testASwitchThatIsOffKeepsQuiet() {
        switches(needs: false, done: true) {
            AgentNotify.moved(card(), to: .needsInput)
        }
        XCTAssertTrue(AgentNotify.recorded.isEmpty)

        AgentNotify.clearRecorded()
        switches(needs: true, done: false) {
            AgentNotify.moved(card(), to: .completed)
        }
        XCTAssertTrue(AgentNotify.recorded.isEmpty)
    }

    func testMovesThatAreNotNewsAreQuiet() {
        switches(needs: true, done: true) {
            for status in [TabshStatus.backlog, .inProgress, .archived] {
                AgentNotify.moved(card(), to: status)
            }
        }
        XCTAssertTrue(AgentNotify.recorded.isEmpty)
    }
}
