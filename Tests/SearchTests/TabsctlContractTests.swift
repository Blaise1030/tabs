import XCTest
@testable import Search

/// The `tabsctl` contract: the verbs and fields Sources/TabsCLI sends must
/// be the ones TabshAgentSocket answers. The CLI is a separate SwiftPM
/// executable and cannot import Search, so its copy of the protocol strings
/// is pinned against this one by reading its source.
final class TabsctlContractTests: XCTestCase {
    func testVerbsMatchTheCLISource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = try String(contentsOf: root.appendingPathComponent("Sources/TabsCLI/main.swift"), encoding: .utf8)
        for verb in TabsctlProtocol.verbs {
            XCTAssertTrue(cli.contains("\"\(verb)\""), "tabsctl must send \(verb)")
        }
        XCTAssertTrue(cli.contains("agent.sock"))
        XCTAssertTrue(cli.contains("TABSH_SESSION_ID"))
    }

    func testCreateRequestsParse() {
        let agent = TabsctlRequest.parse([
            "do": TabsctlProtocol.createAgent, "cwd": "/tmp/work", "prompt": "fix it",
            "provider": "Codex", "mode": "ui", "focus": true, "parent": "s1",
        ])
        XCTAssertEqual(agent?.verb, TabsctlProtocol.createAgent)
        XCTAssertEqual(agent?.cwd, "/tmp/work")
        XCTAssertEqual(agent?.prompt, "fix it")
        XCTAssertEqual(agent?.focus, true)
        XCTAssertEqual(agent?.parent, "s1")

        let terminal = TabsctlRequest.parse(["do": TabsctlProtocol.createTerminal])
        XCTAssertEqual(terminal?.focus, false)
    }

    func testMalformedRequestsAreRefused() {
        XCTAssertNil(TabsctlRequest.parse(["do": "session.delete", "session": "s1"]))
        XCTAssertNil(TabsctlRequest.parse(["do": TabsctlProtocol.open]))
        XCTAssertNil(TabsctlRequest.parse(["do": TabsctlProtocol.open, "session": ""]))
        XCTAssertNil(TabsctlRequest.parse(["do": TabsctlProtocol.createAgent, "mode": "sideways"]))
        XCTAssertNil(TabsctlRequest.parse([:]))
    }

    func testFailureShape() {
        let answer = TabsctlProtocol.failure("session_not_found", "no session x", hint: "tabsctl sessions")
        let error = answer["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "session_not_found")
        XCTAssertEqual(error?["message"] as? String, "no session x")
        XCTAssertEqual(error?["hint"] as? String, "tabsctl sessions")
    }
}
