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

    /// The ACP question arrives as an `elicitation`: its words, the form's
    /// fields, and the id the answer goes back on. The card is built from
    /// this, so the pick's value is what is sent, not its label.
    func testAnAgentQuestionIsReadAsAForm() throws {
        let chunk = TabshChatChunk(line: #"""
        {"type":"elicitation","session_id":"s1","request_id":"7000",
         "message":"Where should the draft live?","tool_call_id":"tc-1",
         "schema":{"type":"object",
           "properties":{"store":{"type":"string","title":"Draft storage",
             "description":"Where should it live?",
             "oneOf":[{"const":"session","title":"On the session",
                       "description":"Kept with the session"},
                      {"const":"memory","title":"In memory"}]}},
           "required":["store"]}}
        """#)
        XCTAssertEqual(chunk?.type, "elicitation")
        XCTAssertEqual(chunk?.requestID, "7000")
        XCTAssertEqual(chunk?.toolCallID, "tc-1")

        let form = try XCTUnwrap(
            TabshQuestionForm(message: chunk?.message ?? "", schema: chunk?.schema)
        )
        XCTAssertEqual(form.message, "Where should the draft live?")
        let field = try XCTUnwrap(form.fields.first)
        XCTAssertEqual(field.title, "Draft storage")
        XCTAssertEqual(field.detail, "Where should it live?")
        XCTAssertTrue(field.required)
        guard case let .pick(choices) = field.kind else {
            return XCTFail("a oneOf should be a pick, got \(field.kind)")
        }
        XCTAssertEqual(choices.map(\.id), ["session", "memory"])
        XCTAssertEqual(choices.map(\.title), ["On the session", "In memory"])
        XCTAssertEqual(choices.first?.detail, "Kept with the session")
    }

    func testPlainEnumsNumbersBoolsAndArraysEachGetTheirControl() throws {
        let form = try XCTUnwrap(TabshQuestionForm(message: "A few things", schema: [
            "type": "object",
            "properties": [
                "count": ["type": "integer", "title": "How many"],
                "needed": ["type": "boolean", "title": "Required?"],
                "files": ["type": "array", "title": "Files",
                          "items": ["type": "string", "enum": ["a.swift", "b.swift"]]],
                "note": ["type": "string", "title": "Anything else"],
                "unknown": ["type": "object", "title": "A future kind"],
            ],
            "required": ["count"],
        ]))
        XCTAssertEqual(form.fields.map(\.id), ["count", "files", "needed", "note", "unknown"])
        XCTAssertEqual(form.fields.first { $0.id == "count" }?.kind, .number(integer: true))
        XCTAssertEqual(form.fields.first { $0.id == "needed" }?.kind, .yesNo)
        XCTAssertEqual(form.fields.first { $0.id == "note" }?.kind, .text)
        XCTAssertEqual(form.fields.first { $0.id == "unknown" }?.kind, .text)
        guard case let .picks(choices)? = form.fields.first(where: { $0.id == "files" })?.kind else {
            return XCTFail("an array of enum should be picks")
        }
        XCTAssertEqual(choices.map(\.id), ["a.swift", "b.swift"])
        XCTAssertEqual(form.fields.filter(\.required).map(\.id), ["count"])
    }

    /// A schema this build cannot read keeps the agent's words rather than
    /// dropping the turn: the card falls back to a message.
    func testAQuestionWithoutFormFieldsKeepsItsMessage() {
        XCTAssertNil(TabshQuestionForm(message: "hi", schema: nil))
        XCTAssertNil(TabshQuestionForm(message: "hi", schema: ["type": "object"]))
    }

    /// An answered card says what was chosen, named by the field rather than
    /// by the value the agent reads, and keeps the question in the transcript.
    func testAnAnsweredQuestionReadsAsItsFieldAndValue() throws {
        let form = try XCTUnwrap(TabshQuestionForm(message: "Questions", schema: [
            "type": "object",
            "properties": [
                "q0": ["type": "string", "title": "Draft storage",
                       "oneOf": [["const": "session", "title": "On the session"],
                                 ["const": "memory", "title": "In memory"]]],
            ],
        ]))
        XCTAssertEqual(
            TabshQuestionForm.answerText("accept", content: ["q0": "memory"], form: form),
            "Draft storage: In memory"
        )
        XCTAssertEqual(TabshQuestionForm.answerText("decline", content: nil, form: form),
                       "Declined")
        XCTAssertEqual(TabshQuestionForm.answerText("cancel", content: nil, form: form),
                       "Dismissed")
        // A key the form never named still reads as itself.
        XCTAssertEqual(
            TabshQuestionForm.answerText("accept", content: ["q0_custom": "sqlite"], form: form),
            "q0_custom: sqlite"
        )
    }

    /// The composer's pane is built again whenever its tab comes back to the
    /// front, so a draft has to outlive the view that held it: it is kept for
    /// the session, and the next instance of the store hands it back.
    @MainActor
    func testADraftWaitsForTheSessionThatTypedIt() {
        let session = "s-draft-test"
        let drafts = TabshDrafts()
        XCTAssertEqual(drafts.text(for: session), "")

        drafts.set("half a thought", for: session)
        XCTAssertEqual(drafts.text(for: session), "half a thought")
        XCTAssertEqual(TabshDrafts().text(for: session), "half a thought")
        XCTAssertEqual(drafts.text(for: "another-session"), "")

        // Sent, or emptied by hand: the key goes rather than staying blank.
        drafts.set("", for: session)
        XCTAssertEqual(TabshDrafts().text(for: session), "")
    }

    /// Uploads are saved beside the daemon's database, under Application
    /// Support, so the path a sent message carries has a space in it. The
    /// bubble has to read that line as the picture rather than repeat it as
    /// words, and find the picture to draw.
    func testAPictureWhosePathHasSpacesIsShownAsAPictureOnly() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabsh-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("Screenshot 2026-11-01 at 2.23.09 PM.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: picture)

        let sent = "What is this?\n\n\(picture.path)"
        XCTAssertEqual(textWithoutImagePaths(sent), "What is this?")
        XCTAssertEqual(imageRefs(in: sent), [picture])
    }

    func testMarkdownPicturesAreFoundAndMissingFilesAreNot() {
        XCTAssertEqual(imageRefs(in: "![shot](https://example.com/shot.png)"),
                       [URL(string: "https://example.com/shot.png")])
        XCTAssertEqual(imageRefs(in: "![shot](/nowhere/shot.png)"), [])
        // A path inside a sentence is left alone, not eaten as picture.
        XCTAssertEqual(textWithoutImagePaths("look at /nowhere/shot.png please"),
                       "look at /nowhere/shot.png please")
    }

    /// The queue lets the next line go at the one moment the agent is free:
    /// no turn open, nothing on the wire, and the last line's echo in. Asking
    /// `busy` instead never drains it — a queued line keeps `busy` lit.
    func testTheQueueDrainsOnlyWhenTheAgentIsFree() {
        XCTAssertTrue(TabshChat.canDrain(open: false, posting: false, pending: 0, queued: 1))
        XCTAssertFalse(TabshChat.canDrain(open: true, posting: false, pending: 0, queued: 1))
        XCTAssertFalse(TabshChat.canDrain(open: false, posting: true, pending: 0, queued: 1))
        XCTAssertFalse(TabshChat.canDrain(open: false, posting: false, pending: 1, queued: 1))
        XCTAssertFalse(TabshChat.canDrain(open: false, posting: false, pending: 0, queued: 0))
    }
}
