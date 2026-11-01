import XCTest
@testable import Search

final class TabshAgentTests: XCTestCase {
    func testUserTextIsReadFromTheStream() {
        let chunk = TabshChatChunk(
            line: #"{"type":"user_text","session_id":"s1","text":"Hello"}"#
        )
        XCTAssertEqual(chunk?.type, "user_text")
        XCTAssertEqual(chunk?.text, "Hello")
    }

    func testAgentTextAndTurnEndKeepTheirShape() {
        let text = TabshChatChunk(
            line: #"{"type":"text_delta","session_id":"s1","text":"Working"}"#
        )
        XCTAssertEqual(text?.type, "text_delta")
        XCTAssertEqual(text?.text, "Working")

        let end = TabshChatChunk(
            line: #"{"type":"turn_end","session_id":"s1","stop_reason":"end_turn"}"#
        )
        XCTAssertEqual(end?.type, "turn_end")
        XCTAssertEqual(end?.stopReason, "end_turn")
    }

    func testToolCallFoldsToItsNameAndKeepsTheCommandForTheDetail() {
        let chunk = TabshChatChunk(line: #"""
        {"type":"tool_call","session_id":"s1","tool_call":{
          "toolCallId":"call-1",
          "title":"todos",
          "rawInput":{"command":"ls -la","cwd":"/tmp"},
          "rawOutput":"total 0"
        }}
        """#)
        XCTAssertEqual(chunk?.toolID, "call-1")
        XCTAssertEqual(chunk?.toolSummary, "todos")
        XCTAssertEqual(chunk?.toolDetail, "ls -la\n\ncwd: /tmp\n\ntotal 0")
    }

    func testPermissionUsesTheToolTitleAndKeepsItsRequestID() {
        let chunk = TabshChatChunk(line: #"""
        {"type":"permission","session_id":"s1","request_id":"7",
         "tool_call":{"title":"Run the tests?"},"options":[]}
        """#)
        XCTAssertEqual(chunk?.requestID, "7")
        XCTAssertEqual(chunk?.permissionLabel, "Run the tests?")
    }

    func testMalformedOrUnknownLinesAreIgnored() {
        XCTAssertNil(TabshChatChunk(line: "not json"))
        XCTAssertNil(TabshChatChunk(line: #"{"text":"no type"}"#))
    }
}
