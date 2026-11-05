import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// A tabsh agent in a tab of the browser, drawn natively instead of in the
// web app's panel: the daemon streams the same `UiChunk`s, and this file
// turns them into chat bubbles. A user line is the accent-coloured bubble on
// the right; the agent writes from the left under its mark; tool calls fold
// to one quiet row and a permission request stays a card you can answer.
//
// The conversation belongs to the card on the daemon, not to the view. One
// object is kept per session (TabshChats), so switching tabs or relaunching
// reconnects and replays the transcript without losing the live turn.

// MARK: - The daemon's chunks

/// One SSE line from `/api/sessions/{id}/chat/stream`. The shape is the
/// daemon's `UiChunk`: a flat, `type`-tagged JSON object. Fields that belong
/// to other kinds are empty; only `type` is ever required.
struct TabshChatChunk {
    let type: String
    var text = ""
    var requestID = ""
    var message = ""
    var stopReason = ""
    var tool: [String: Any]?
    /// An `elicitation`'s form (`requestedSchema`), and the `action` an
    /// `elicitation_answered` chose with the `content` it sent back.
    var schema: [String: Any]?
    var action = ""
    var content: [String: Any]?
    var toolCallID = ""

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        self.init(object: object)
    }

    init?(object: [String: Any]) {
        guard let type = object["type"] as? String else { return nil }
        self.type = type
        text = object["text"] as? String ?? ""
        requestID = object["request_id"] as? String ?? ""
        message = object["message"] as? String ?? ""
        stopReason = object["stop_reason"] as? String ?? ""
        tool = object["tool_call"] as? [String: Any]
        schema = object["schema"] as? [String: Any]
        action = object["action"] as? String ?? ""
        content = object["content"] as? [String: Any]
        toolCallID = object["tool_call_id"] as? String ?? ""
    }

    var toolID: String? {
        guard let tool else { return nil }
        let id = tool["toolCallId"] as? String ?? tool["tool_call_id"] as? String
        return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The folded label: the tool's name or title, and only when those say
    /// nothing, its kind. The command itself belongs in the expanded body.
    var toolSummary: String {
        guard let tool else { return "Tool" }
        if let name = nonEmpty(tool["name"]) { return name }
        let title = nonEmpty(tool["title"])
        let command = toolCommand
        if let title, title != command, !title.contains(" ") { return title }
        if let title, command == nil { return title }
        return nonEmpty(tool["kind"]) ?? "Tool"
    }

    /// The command, working directory and output the tool row unfolds to.
    var toolDetail: String {
        guard let tool else { return "" }
        var parts: [String] = []
        if let command = toolCommand { parts.append(command) }
        if let cwd = nonEmpty(toolInput?["cwd"]) { parts.append("cwd: \(cwd)") }
        if let output = nonEmpty(tool["rawOutput"]) {
            parts.append(output)
        } else if let content = tool["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                let inner = item["content"] as? [String: Any] ?? item
                return nonEmpty(inner["text"])
            }
            if !texts.isEmpty { parts.append(texts.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    var permissionLabel: String {
        if let tool {
            if let title = nonEmpty(tool["title"]) { return title }
            if let name = nonEmpty(tool["name"]) { return name }
        }
        return "Permission requested"
    }

    private var toolInput: [String: Any]? {
        (tool?["rawInput"] as? [String: Any]) ?? (tool?["input"] as? [String: Any])
    }

    private var toolCommand: String? {
        nonEmpty(toolInput?["command"]) ?? nonEmpty(toolInput?["cmd"])
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - The agent's question

/// A question the agent asked as an ACP form (`elicitation/create`): the
/// words, and the fields it wants answered. The daemon relays the raw
/// `requestedSchema`; this reads the shapes the ACP spec allows (text,
/// number, yes/no, a pick from a list, picks from a list) and treats an
/// unknown kind as plain text, so a newer agent still gets answered.
struct TabshQuestionForm: Equatable {
    struct Choice: Identifiable, Equatable {
        /// The value sent back: an option's `const`, or its `enum` string.
        let id: String
        let title: String
        let detail: String?
    }

    struct Field: Identifiable, Equatable {
        enum Kind: Equatable {
            case text
            case number(integer: Bool)
            case yesNo
            case pick([Choice])
            case picks([Choice])
        }

        let id: String
        let title: String
        let detail: String
        let required: Bool
        let kind: Kind
    }

    var message: String
    var fields: [Field]

    init?(message: String, schema: [String: Any]?) {
        guard let schema, let properties = schema["properties"] as? [String: Any] else {
            return nil
        }
        self.message = message
        let required = Set(schema["required"] as? [String] ?? [])
        // JSON objects arrive unordered. Sorting keeps the fields steady
        // across rebuilds of the transcript, which is all a form needs.
        fields = properties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { key in
                guard let property = properties[key] as? [String: Any] else { return nil }
                return Field(id: key,
                             title: Self.text(property["title"]) ?? key,
                             detail: Self.text(property["description"]) ?? "",
                             required: required.contains(key),
                             kind: Self.kind(of: property))
            }
    }

    /// What an answered question's card says: the values it was given, named
    /// by their fields, or the word for a decline.
    static func answerText(_ action: String,
                           content: [String: Any]?,
                           form: TabshQuestionForm?) -> String {
        switch action {
        case "decline": return "Declined"
        case "cancel": return "Dismissed"
        default: break
        }
        guard let content, !content.isEmpty else { return "Answered" }
        if let form {
            let lines = form.fields.compactMap { field -> String? in
                guard let value = content[field.id] else { return nil }
                return "\(field.title): \(answerValue(field, value))"
            }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        // A key the form did not name (a custom answer, a newer shape).
        return content.keys.sorted().compactMap { key in
            content[key].map { "\(key): \(Self.plainAnswer($0))" }
        }
        .joined(separator: "\n")
    }

    private static func answerValue(_ field: TabshQuestionForm.Field, _ value: Any) -> String {
        switch field.kind {
        case let .pick(choices):
            if let id = value as? String {
                return choices.first { $0.id == id }?.title ?? id
            }
        case let .picks(choices):
            if let ids = value as? [String] {
                return ids.map { id in
                    choices.first { $0.id == id }?.title ?? id
                }
                .joined(separator: ", ")
            }
        case .yesNo:
            if let flag = value as? Bool { return flag ? "Yes" : "No" }
        case .text, .number:
            break
        }
        return plainAnswer(value)
    }

    private static func plainAnswer(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let flag as Bool: return flag ? "Yes" : "No"
        case let number as NSNumber: return number.stringValue
        case let list as [Any]: return list.map(plainAnswer).joined(separator: ", ")
        default: return String(describing: value)
        }
    }

    /// A yes to one field is a form that can be sent, not a form with no
    /// fields: an empty schema still shows its message, with nothing to fill.
    var isEmpty: Bool { fields.isEmpty }

    private static func kind(of property: [String: Any]) -> Field.Kind {
        switch text(property["type"]) {
        case "boolean":
            return .yesNo
        case "number":
            return .number(integer: false)
        case "integer":
            return .number(integer: true)
        case "array":
            let items = property["items"] as? [String: Any]
            let choices = Self.choices(in: items ?? property)
            return choices.isEmpty ? .text : .picks(choices)
        default:
            let choices = Self.choices(in: property)
            return choices.isEmpty ? .text : .pick(choices)
        }
    }

    /// A single select is `oneOf`/`anyOf` of `{const, title, description}`,
    /// or a plain `enum` of values; a multi select puts the same lists
    /// inside the array's `items`.
    private static func choices(in property: [String: Any]) -> [Choice] {
        for key in ["oneOf", "anyOf"] {
            if let list = property[key] as? [[String: Any]] {
                return list.compactMap { option in
                    guard let value = text(option["const"]) ?? text(option["enum"]) else {
                        return nil
                    }
                    return Choice(id: value,
                                  title: text(option["title"]) ?? value,
                                  detail: text(option["description"]))
                }
            }
        }
        let values = (property["enum"] as? [Any])?.compactMap(text) ?? []
        let names = property["enumNames"] as? [Any] ?? []
        return values.enumerated().map { index, value in
            let name = index < names.count ? text(names[index]) : nil
            return Choice(id: value, title: name ?? value, detail: nil)
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

// MARK: - Transcript

/// One drawn row. Consecutive text deltas become one agent row; a tool's
/// updates keep one row as well, so a long command does not flood the chat.
struct TabshChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, agent, tool, toolGroup, plan, permission, question, error
    }

    let id: String
    var kind: Kind
    var text: String
    var detail = ""
    var requestID = ""
    var queued = false
    /// A question's fields, when the agent asked one.
    var form: TabshQuestionForm?
    /// The answer a question was given, already worded for the card
    /// ("Draft storage: memory", "Declined"). Empty while it is open.
    var answer = ""
    /// A run of consecutive tool calls, folded into one row (see Kind.toolGroup).
    var children: [TabshChatRow] = []
    /// "Delivered" under the newest outgoing bubble, as a message shows it.
    var receipt = ""
    /// True while this agent bubble is still growing from the stream. The
    /// row draws plain text then, and only parses markdown once the turn
    /// settles — re-parsing the whole bubble on every token was the costly
    /// part of a long answer.
    var streaming = false
}

@MainActor
final class TabshChats {
    static let shared = TabshChats()

    private var live: [String: TabshChat] = [:]

    func chat(for session: String) -> TabshChat {
        if let open = live[session] { return open }
        let made = TabshChat(sessionID: session)
        live[session] = made
        return made
    }

    /// The tab was closed. The card and its agent stay on the daemon; only
    /// this window's stream, and the transcript it was holding, are let go.
    func close(_ session: String) {
        live.removeValue(forKey: session)?.stop()
    }
}

/// What has been typed into a session's composer and not sent yet, kept for
/// the session rather than for the view. The pane is built again every time
/// its tab comes back to the front, and a tab can be closed and reopened, so
/// a half-written message — its attached files and pictures too — lives here
/// and is handed back when the composer is built, this launch or the next.
@MainActor
final class TabshDrafts {
    static let shared = TabshDrafts()

    /// Dictation (menu or ⌥D) wrote into a session's draft from outside the
    /// composer: the open composer reloads so the field shows the words.
    static let dictatedName = Notification.Name("tabsh.draft.dictated")

    private static let key = "tabshDrafts"
    /// The files and pictures waiting on each session's message, kept apart
    /// from the words so a draft without attachments costs one dictionary
    /// lookup and nothing else.
    private static let filesKey = "tabshDraftFiles"

    private let store = Store.settings
    private var texts: [String: String]
    private var files: [String: [String]]

    init() {
        texts = store.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        files = store.dictionary(forKey: Self.filesKey) as? [String: [String]] ?? [:]
    }

    func text(for session: String) -> String {
        texts[session] ?? ""
    }

    /// An empty draft is no draft: the key goes, so a sent message leaves
    /// nothing behind and the map does not grow with every session touched.
    func set(_ text: String, for session: String) {
        guard texts[session] != text else { return }
        if text.isEmpty {
            texts.removeValue(forKey: session)
        } else {
            texts[session] = text
        }
        store.set(texts, forKey: Self.key)
    }

    /// The chips still waiting on a session's message, in the order they
    /// were attached. A file that has gone from disk since is dropped
    /// quietly rather than restored as a chip that cannot be sent.
    func attachments(for session: String) -> [TabshPendingAttachment] {
        (files[session] ?? []).compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return TabshPendingAttachment(url: url)
        }
    }

    /// Kept beside the words for the same reason: the composer is built
    /// again whenever the tab comes back, and the attachments have to come
    /// with the half-written message. Sending clears them.
    func setAttachments(_ attachments: [TabshPendingAttachment], for session: String) {
        let paths = attachments.map(\.url.path)
        guard files[session] != paths else { return }
        if paths.isEmpty {
            files.removeValue(forKey: session)
        } else {
            files[session] = paths
        }
        store.set(files, forKey: Self.filesKey)
    }

    /// Appends settled dictation to a draft and tells any open composer.
    func appendDictated(_ words: String, for session: String) {
        guard !words.isEmpty else { return }
        let current = text(for: session)
        let gap = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : " "
        set(current + gap + words, for: session)
        NotificationCenter.default.post(name: Self.dictatedName, object: session)
    }
}

@MainActor
final class TabshChat: ObservableObject {
    let sessionID: String

    @Published private(set) var rows: [TabshChatRow] = []

    /// Consecutive tool calls as one row: an agent that has read twelve files
    /// is one "12 operations", open to the calls themselves. A run of one
    /// stays the tool's own row.
    private static func grouped(_ rows: [TabshChatRow]) -> [TabshChatRow] {
        var out: [TabshChatRow] = []
        var run: [TabshChatRow] = []
        func flush() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                out.append(run[0])
            } else {
                out.append(TabshChatRow(id: "group-\(run[0].id)", kind: .toolGroup,
                                        text: "\(run.count) operations", children: run))
            }
            run.removeAll()
        }
        for row in rows {
            if row.kind == .tool { run.append(row) }
            else { flush(); out.append(row) }
        }
        flush()
        return out
    }
    @Published private(set) var busy = false
    @Published private(set) var waiting = false
    /// True while the SSE connection is still dumping its history replay.
    /// The pane keeps the scroll pinned to the bottom and holds off a
    /// full row-by-row paint until the burst goes quiet.
    @Published private(set) var loadingHistory = true
    @Published private(set) var agentName = "Agent"
    @Published private(set) var models: Tabsh.ChatSelect?
    @Published private(set) var modes: Tabsh.ChatSelect?
    @Published private(set) var changingOption = false
    @Published var notice: String?

    private struct Pending {
        let id = UUID()
        let text: String
    }

    private var chunks: [TabshChatChunk] = []
    private var pending: [Pending] = []
    /// Sent while a turn is open wait here, as they do in the web panel:
    /// the daemon takes one prompt at a time.
    private var queue: [Pending] = []
    private var posting = false
    private var stream: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var options: Task<Void, Never>?
    /// Ends `loadingHistory` once the replay has been quiet for a beat.
    private var historyIdle: Task<Void, Never>?
    private var stopped = false
    /// Text deltas folded into the last agent chunk since the last paint.
    /// Drained by `schedulePatch` so a fast stream does not walk the whole
    /// transcript on every token — only the growing bubble is updated.
    private var agentDelta = ""

    init(sessionID: String) {
        self.sessionID = sessionID
        start()
        loadOptions()
        // The card's name is the agent's name, as the board shows it. The
        // header uses it once it has been read; "Agent" until then.
        Task { @MainActor [weak self] in
            guard let self,
                  let sessions = try? await Tabsh.sessions(),
                  let card = sessions.first(where: { $0.id == self.sessionID }),
                  let name = card.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return }
            self.agentName = name
        }
    }

    func start() {
        guard stream == nil, !stopped else { return }
        stream = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func stop() {
        stopped = true
        stream?.cancel()
        refresh?.cancel()
        historyIdle?.cancel()
        options?.cancel()
        stream = nil
        refresh = nil
        historyIdle = nil
        options = nil
    }

    // MARK: The agent's own selects

    /// The model and mode lists only exist once the ACP agent is live.
    /// Wake it with no prompt, then poll until the handshake has answered.
    /// A mode is a config option, not a requirement: if models are there
    /// and modes stay empty, the agent simply has none.
    private func loadOptions() {
        options?.cancel()
        options = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await Tabsh.startChat(self.sessionID)

            for attempt in 0..<20 {
                if Task.isCancelled || self.stopped { return }
                if let answer = try? await Tabsh.chatModels(self.sessionID),
                   !answer.options.isEmpty {
                    withAnimation(Motion.settle) { self.models = answer }
                }
                if let answer = try? await Tabsh.chatModes(self.sessionID),
                   !answer.options.isEmpty {
                    withAnimation(Motion.settle) { self.modes = answer }
                }
                if self.models != nil,
                   self.modes != nil || attempt >= 3 {
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func selectModel(_ id: String) {
        guard let models, models.current != id, !changingOption else { return }
        changingOption = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.models = try await Tabsh.setChatModel(self.sessionID, id: id)
                self.notice = nil
            } catch {
                self.notice = error.localizedDescription
            }
            self.changingOption = false
        }
    }

    func selectMode(_ id: String) {
        guard let modes, modes.current != id, !changingOption else { return }
        changingOption = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.modes = try await Tabsh.setChatMode(self.sessionID, id: id)
                self.notice = nil
            } catch {
                self.notice = error.localizedDescription
            }
            self.changingOption = false
        }
    }

    // MARK: Sending

    /// Whether the next queued line may go: no turn is open, nothing is on
    /// the wire, and the agent's echo of the last line has arrived. `busy`
    /// cannot say so — a queued line is itself what keeps `busy` lit — so
    /// these three are asked directly, or nothing would ever drain the queue.
    nonisolated static func canDrain(open: Bool, posting: Bool, pending: Int, queued: Int) -> Bool {
        !open && !posting && pending == 0 && queued > 0
    }

    /// Soft cap for tool output kept on a row. Unfolded views still show
    /// enough to read; multi‑MB diffs stay out of the SwiftUI list.
    private static let detailLimit = 12_000

    nonisolated private static func clipDetail(_ text: String) -> String {
        guard text.count > detailLimit else { return text }
        let end = text.index(text.startIndex, offsetBy: detailLimit)
        return String(text[..<end]) + "\n…"
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notice = nil
        // A turn (or a message still on its way) owns the agent; this line
        // joins the queue and goes when the turn ends.
        if busy || posting || !pending.isEmpty {
            queue.append(Pending(text: text))
            schedule()
            return
        }
        post(Pending(text: text))
    }

    private func post(_ message: Pending) {
        pending.append(message)
        posting = true
        schedule()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Tabsh.sendChatMessage(self.sessionID, text: message.text)
            } catch {
                if let index = self.pending.firstIndex(where: { $0.id == message.id }) {
                    self.pending.remove(at: index)
                }
                self.notice = error.localizedDescription
            }
            self.posting = false
            self.schedule()
        }
    }

    func stopTurn() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Tabsh.stopChat(self.sessionID)
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    func approve(_ requestID: String, allow: Bool) {
        guard !requestID.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Tabsh.approveChat(self.sessionID, requestID: requestID, allow: allow)
                self.notice = nil
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    /// Answers an ACP question: `accept` with the form's values, or
    /// `decline`/`cancel` with none. The daemon records the answer, so the
    /// card stops offering one in every window and after a relaunch.
    func answer(_ requestID: String,
                action: String,
                content: [String: Any]? = nil) {
        guard !requestID.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Tabsh.answerChat(self.sessionID,
                                           requestID: requestID,
                                           action: action,
                                           content: content)
                self.notice = nil
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    // MARK: The stream

    private func run() async {
        while !Task.isCancelled && !stopped {
            do {
                try await readStream()
                // A clean end is a daemon restart or a dropped connection;
                // either way the transcript is replayed when we come back.
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled || stopped { return }
                notice = error.localizedDescription
            }
            if Task.isCancelled || stopped { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func readStream() async throws {
        // Paint from the REST snapshot first. A multi‑MB transcript dripped
        // through SSE used to arm an 80ms "history quiet" timer before any
        // byte arrived; that timer committed an empty row list, the empty
        // state stuck on screen, and the live stream never repaired it.
        let painted = await loadHistorySnapshot()
        var skipReplay = painted

        guard let request = Tabsh.chatStreamRequest(sessionID) else {
            throw TabshError.noToken
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TabshError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw TabshError.refused(http.statusCode)
        }

        // SSE still replays history then lives. Skip the replay when REST
        // already painted it; fall through to the quiet-timer path when it
        // did not (brand-new card, or the snapshot failed).
        if painted == 0 {
            loadingHistory = true
        }
        var replacing = painted == 0
        var replayed = 0
        for try await line in bytes.lines {
            guard !Task.isCancelled, !stopped else { return }
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let chunk = TabshChatChunk(line: raw) else { continue }
            if skipReplay > 0 {
                replayed += 1
                if replayed <= skipReplay {
                    continue
                }
                skipReplay = 0
            }
            if replacing {
                chunks.removeAll()
                replacing = false
            }
            accept(chunk)
        }
    }

    /// Pull `/chat` once and rebuild. Returns how many SSE replay events to
    /// skip (the snapshot size), or 0 when there was nothing to paint.
    private func loadHistorySnapshot() async -> Int {
        loadingHistory = true
        do {
            let messages = try await Tabsh.chatHistory(sessionID)
            guard !Task.isCancelled, !stopped else { return 0 }
            guard !messages.isEmpty else {
                // Brand-new card: nothing to paint; SSE will append live.
                loadingHistory = false
                return 0
            }
            var loaded: [TabshChatChunk] = []
            loaded.reserveCapacity(min(messages.count, 4096))
            for object in messages {
                guard let chunk = TabshChatChunk(object: object) else { continue }
                if let last = loaded.last,
                   (chunk.type == "text_delta" || chunk.type == "thought_delta"),
                   last.type == chunk.type {
                    loaded[loaded.count - 1].text += chunk.text
                } else {
                    loaded.append(chunk)
                }
            }
            chunks = loaded
            rebuild()
            loadingHistory = false
            return messages.count
        } catch {
            // Fall back to SSE-only history below.
            return 0
        }
    }

    private func accept(_ chunk: TabshChatChunk) {
        // Fold consecutive token/thought deltas into one chunk so a long
        // replay is hundreds of entries rather than tens of thousands —
        // rebuild walks stay cheap enough for the main thread.
        var folded = false
        if let last = chunks.last,
           (chunk.type == "text_delta" || chunk.type == "thought_delta"),
           last.type == chunk.type {
            chunks[chunks.count - 1].text += chunk.text
            folded = true
        } else {
            chunks.append(chunk)
        }
        // The daemon echoes the message it accepted. That echo is the real
        // bubble; the optimistic one goes when it arrives.
        if chunk.type == "user_text",
           let index = pending.firstIndex(where: { $0.text == chunk.text }) {
            pending.remove(at: index)
        }
        if loadingHistory {
            // Hold the row list still until the history burst pauses, then
            // paint once and unpin the loading flag.
            noteHistoryChunk()
        } else if folded, chunk.type == "text_delta", !chunk.text.isEmpty {
            // The common path while the agent writes: grow the last bubble
            // without rebuilding every earlier row.
            agentDelta += chunk.text
            schedulePatch()
        } else {
            // A tool, permission, turn end, or a new bubble: drop any pending
            // patch so it cannot paint only the last text and miss this row.
            agentDelta = ""
            refresh?.cancel()
            refresh = nil
            schedule()
        }
    }

    /// History arrives as a tight SSE burst with no "done" marker. A short
    /// quiet window is the end of the replay; live turns restart the clock
    /// on each token via `schedule` instead. An empty commit is avoided by
    /// only arming this timer from `accept` (after a chunk exists) or from
    /// the REST fallback path after a failed snapshot.
    private func noteHistoryChunk() {
        historyIdle?.cancel()
        historyIdle = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.historyIdle = nil
            self.rebuild()
            self.loadingHistory = false
        }
    }

    // The stream can send a token at a time. Rebuilding on each one would
    // walk the whole transcript thousands of times a turn; one frame is
    // enough for the eye, and keeps the list steady.
    private func schedule() {
        guard refresh == nil else { return }
        refresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refresh = nil
            self.rebuild()
        }
    }

    /// Same cadence as `schedule`, but only syncs the growing agent bubble
    /// from the folded chunk. Falls back to a full rebuild when the list
    /// has no agent row yet (the first token of a turn).
    private func schedulePatch() {
        guard refresh == nil else { return }
        refresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refresh = nil
            if !self.patchLastAgent() {
                self.rebuild()
            }
        }
    }

    /// Copies the folded text_delta onto the last agent row. Returns false
    /// when the list still needs a full rebuild (no agent bubble to grow).
    @discardableResult
    private func patchLastAgent() -> Bool {
        agentDelta = ""
        guard let last = chunks.last, last.type == "text_delta",
              let index = rows.lastIndex(where: { $0.kind == .agent })
        else { return false }
        var next = rows
        if next[index].text != last.text || !next[index].streaming {
            next[index].text = last.text
            next[index].streaming = true
            rows = next
        }
        // Tokens mean the agent has started answering.
        if !busy { busy = true }
        if waiting { waiting = false }
        return true
    }

    private func rebuild() {
        agentDelta = ""
        let answered = Set(chunks.compactMap {
            $0.type == "permission_answered" ? $0.requestID : nil
        })
        // A question's answer, by the request it answers, so the card keeps
        // showing what was chosen after the agent has moved on.
        var answers: [String: (action: String, content: [String: Any]?)] = [:]
        for chunk in chunks where chunk.type == "elicitation_answered" {
            answers[chunk.requestID] = (chunk.action,
                                       chunk.content as? [String: Any])
        }
        // The tool call behind a question would repeat its card.
        let askedTools = Set(chunks.compactMap {
            $0.type == "elicitation" ? $0.toolCallID : nil
        }).filter { !$0.isEmpty }
        var rows: [TabshChatRow] = []
        var tools: [String: Int] = [:]
        var lastType = ""
        var open = false
        var sawAgent = false

        for (index, chunk) in chunks.enumerated() {
            switch chunk.type {
            case "user_text":
                rows.append(.init(id: "user-\(index)", kind: .user, text: chunk.text))
                open = true
                sawAgent = false
            case "text_delta":
                if lastType == "text_delta", let last = rows.last, last.kind == .agent {
                    rows[rows.count - 1].text += chunk.text
                } else {
                    rows.append(.init(id: "agent-\(index)", kind: .agent, text: chunk.text))
                }
                if open { sawAgent = true }
            case "tool_call", "tool_call_update":
                if !chunk.toolCallID.isEmpty, askedTools.contains(chunk.toolCallID) {
                    break
                }
                let id = chunk.toolID ?? "tool-\(index)"
                // Cap stored detail: some tool payloads are multi‑MB diffs.
                // Keeping them all in every row made the list refuse to paint.
                let detail = Self.clipDetail(chunk.toolDetail)
                if let at = tools[id] {
                    if !chunk.toolSummary.isEmpty { rows[at].text = chunk.toolSummary }
                    if !detail.isEmpty, !rows[at].detail.contains(detail) {
                        rows[at].detail = rows[at].detail.isEmpty
                            ? detail
                            : Self.clipDetail(rows[at].detail + "\n\n" + detail)
                    }
                } else {
                    tools[id] = rows.count
                    rows.append(.init(id: "tool-\(index)",
                                      kind: .tool,
                                      text: chunk.toolSummary,
                                      detail: detail))
                }
                if open { sawAgent = true }
            case "plan":
                rows.append(.init(id: "plan-\(index)", kind: .plan, text: "Plan updated"))
                if open { sawAgent = true }
            case "permission":
                if open { sawAgent = true }
                guard !answered.contains(chunk.requestID) else { break }
                rows.append(.init(id: "permission-\(index)",
                                  kind: .permission,
                                  text: chunk.permissionLabel,
                                  requestID: chunk.requestID))
            case "permission_answered":
                break
            case "elicitation":
                if open { sawAgent = true }
                let form = TabshQuestionForm(message: chunk.message, schema: chunk.schema)
                var answer = ""
                if let given = answers[chunk.requestID] {
                    answer = TabshQuestionForm.answerText(given.action,
                                                          content: given.content,
                                                          form: form)
                }
                rows.append(.init(id: "question-\(index)",
                                  kind: .question,
                                  text: chunk.message,
                                  requestID: chunk.requestID,
                                  form: form,
                                  answer: answer))
            case "elicitation_answered":
                break
            case "turn_end":
                open = false
                sawAgent = false
            case "error":
                rows.append(.init(id: "error-\(index)",
                                  kind: .error,
                                  text: chunk.message.isEmpty ? chunk.text : chunk.message))
                open = false
                sawAgent = false
            case "thought_delta", "unknown":
                break
            default:
                break
            }
            lastType = chunk.type
        }

        for message in pending + queue {
            rows.append(.init(id: "pending-\(message.id.uuidString)",
                              kind: .user,
                              text: message.text,
                              queued: true))
        }
        // The newest outgoing message carries the receipt, as the last blue
        // bubble does in Messages. Older ones stay bare. A line behind an
        // open turn is queued, not sent, and says so: "Sending" there was a
        // promise the daemon had not been asked to keep yet.
        if let last = rows.lastIndex(where: { $0.kind == .user }) {
            if !queue.isEmpty {
                rows[last].receipt = "Queuing…"
            } else if !pending.isEmpty {
                rows[last].receipt = "Sending…"
            } else {
                rows[last].receipt = "Delivered"
            }
        }

        // The bubble still receiving tokens draws as plain text; settled
        // ones keep full markdown. Only the open turn's last agent row.
        if open, let last = rows.lastIndex(where: { $0.kind == .agent }) {
            rows[last].streaming = true
        }

        let nextRows = TabshChat.grouped(rows)
        let nextBusy = open || !pending.isEmpty || !queue.isEmpty
        let nextWaiting = nextBusy && !sawAgent
        // Must write `self.rows` — a bare `rows =` assigns the local rebuild
        // buffer and leaves the published transcript empty forever (the
        // "No messages yet" blank on long chats).
        self.rows = nextRows
        if nextBusy != busy { busy = nextBusy }
        if nextWaiting != waiting { waiting = nextWaiting }

        // The agent has finished and nothing is on the wire: the next line
        // waits for exactly this moment. See `canDrain` for why `busy` is
        // not the test.
        if Self.canDrain(open: open, posting: posting, pending: pending.count, queued: queue.count) {
            post(queue.removeFirst())
        }
    }

}

// MARK: - The tab

/// One agent chat in a tab: transcript, composer, and the card's own state.
struct TabshAgentPane: View {
    let sessionID: String
    @ObservedObject var browser: Browser
    @ObservedObject private var sessions = TabshSessions.shared
    @StateObject private var chat: TabshChat

    @State private var pinned = true
    /// The files column, shut until asked for: an agent's conversation is the
    /// tab, and a column nobody opened shouldn't take half of it. What was
    /// last chosen is kept for the next pane, this launch or the next, as the
    /// column's width is (see TabshProjectPane) — the pane itself is built
    /// again every time its tab comes back to the front.
    @AppStorage("tabsh.agent.explorer") private var showingExplorer = false
    /// Asks the transcript to go to the bottom from outside its scroll view:
    /// sending a message, or the jump button.
    @State private var scrollToken = 0
    /// Until the first transcript has been scrolled into place. The bottom
    /// marker's preference can fire while the list is still empty or mid-
    /// layout and clear `pinned`, after which row updates no longer follow —
    /// so a freshly opened chat stayed at the top. Held true through the
    /// first non-empty layout, ignoring those early unpin signals.
    @State private var settlingScroll = true
    /// How many older rows stay hidden above the viewport. After history
    /// lands we keep only the newest `pageSize`; scrolling up lowers this
    /// and reveals the next page without rebuilding the whole thread.
    @State private var hiddenPrefix = 0
    @State private var loadingMore = false
    /// The first visible row id before an older page is prepended, so the
    /// scroll can re-anchor there and the viewport does not jump.
    @State private var loadAnchorID: String?

    /// Newest messages shown first; older ones arrive a page at a time.
    private static let pageSize = 30

    init(sessionID: String, browser: Browser) {
        self.sessionID = sessionID
        _browser = ObservedObject(wrappedValue: browser)
        _chat = StateObject(wrappedValue: TabshChats.shared.chat(for: sessionID))
    }

    /// The slice of the transcript currently in the list.
    private var displayedRows: [TabshChatRow] {
        let rows = chat.rows
        // History finishes by publishing the whole thread, then `onChange`
        // windows to the newest page. The first SwiftUI pass still sees
        // `hiddenPrefix == 0` and used to mount every bubble at once — a
        // multi‑MB chat painted nothing (and beachballed) until that caught
        // up. While we are still settling, never hand the list more than
        // one page even if the prefix has not been written yet.
        var prefix = hiddenPrefix
        if settlingScroll, prefix == 0, rows.count > Self.pageSize {
            prefix = rows.count - Self.pageSize
        }
        guard prefix > 0, prefix < rows.count else { return rows }
        return Array(rows[prefix...])
    }

    private var hasOlder: Bool { hiddenPrefix > 0 }

    var body: some View {
        // Same project column a terminal tab has: the session's folder beside
        // the conversation. The header lives in the chat column only, so the
        // explorer runs the full height of the tab (over where the bar was).
        TabshProjectPane(sessionID: sessionID,
                         browser: browser,
                         ground: Palette.ground,
                         showingExplorer: $showingExplorer) {
            VStack(spacing: 0) {
                header
                transcript
                // Draft state lives here, not on the pane: a keystroke used
                // to rebuild the whole transcript (and beachball) because
                // `@State draft` sat on TabshAgentPane above.
                TabshAgentComposer(sessionID: sessionID,
                                   browser: browser,
                                   chat: chat,
                                   scrollToken: $scrollToken)
            }
        }
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if chat.loadingHistory {
                            historySpinner
                        } else if chat.rows.isEmpty, !chat.busy {
                            empty
                        } else {
                            if hasOlder || loadingMore {
                                loadOlderHeader
                                    .background {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: ChatTopKey.self,
                                                value: geo.frame(in: .named("chatScroll")).minY
                                            )
                                        }
                                    }
                            }
                            ForEach(Array(displayedRows.enumerated()), id: \.element.id) { index, row in
                                // Equatable: a streamed token only redraws the
                                // growing bubble, not every earlier message.
                                TabshChatRowView(row: row, chat: chat)
                                    .equatable()
                                    .id(row.id)
                                    .padding(.top, gap(before: index, in: displayedRows))
                            }
                            if chat.waiting {
                                TabshThinkingRow()
                                    .padding(.top, 12)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ChatBottomKey.self,
                                        value: geo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    // Inset past the composer's card (also 22) so bubbles
                    // sit inside its width rather than flush with its edges.
                    .padding(.horizontal, 36)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    // The bottom marker cannot tell a token growing the list
                    // from the reader scrolling up: both push it down. The
                    // scroll view's own offset can, and it is what unpins the
                    // follow while the agent is still writing.
                    .background {
                        ChatScrollWatch {
                            guard !settlingScroll, !chat.loadingHistory, pinned else { return }
                            pinned = false
                        }
                    }
                }
                // The list slides into the bar above and the composer
                // below: a hard edge cut the text off mid-line, so each end
                // of the viewport fades to the pane's own ground instead, as
                // the editor's text fades under its header (see Editor).
                .overlay(alignment: .top) { edgeFade(top: true) }
                .overlay(alignment: .bottom) { edgeFade(top: false) }
                .coordinateSpace(name: "chatScroll")
                .scrollIndicators(.never)
                .onPreferenceChange(ChatBottomKey.self) { bottom in
                    // The bottom marker is inside the visible scroll area
                    // while the reader is near the newest message.
                    guard !settlingScroll, !chat.loadingHistory else { return }
                    let nearBottom = bottom <= outer.size.height + 48
                    if nearBottom {
                        pinned = true
                    } else if pinned, chat.busy || chat.waiting {
                        // A streamed token grew the list under a pinned
                        // viewport before follow could catch up — keep the
                        // pin and chase the marker rather than treating it
                        // as the reader scrolling away.
                        follow(proxy)
                    } else {
                        pinned = false
                    }
                }
                .onPreferenceChange(ChatTopKey.self) { top in
                    // The older-page header crossed into view: ask for the
                    // next page. Ignore while history is still settling.
                    guard !settlingScroll, !chat.loadingHistory, !loadingMore, hasOlder else { return }
                    if top > -40, top < outer.size.height {
                        loadOlder(using: proxy)
                    }
                }
                .onChange(of: chat.rows) { _, after in
                    // A shorter rebuild (rare) must not leave the window
                    // past the end; growing at the bottom keeps the prefix.
                    if hiddenPrefix > after.count {
                        hiddenPrefix = max(0, after.count - Self.pageSize)
                    }
                    if settlingScroll || chat.loadingHistory {
                        jumpToBottom(proxy)
                    } else if pinned {
                        // Streamed `text_delta` rewrites the last agent row
                        // in place (same count); follow on any change while
                        // pinned, not only when a new row appears.
                        follow(proxy)
                    }
                }
                .onChange(of: chat.loadingHistory) { _, loading in
                    // History painted in one shot: window to the newest
                    // page, pin to the bottom, then let follow-vs-unpin run.
                    if !loading {
                        windowToLatest()
                        jumpToBottom(proxy)
                        DispatchQueue.main.async {
                            jumpToBottom(proxy)
                            settlingScroll = false
                        }
                    } else {
                        settlingScroll = true
                        pinned = true
                        hiddenPrefix = 0
                    }
                }
                .onChange(of: chat.waiting) { _, _ in follow(proxy) }
                .onChange(of: scrollToken) { _, _ in
                    pinned = true
                    withAnimation(Motion.quick) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: loadingMore) { was, now in
                    // After older rows land, snap back to the row that was
                    // at the top so the viewport does not leap upward.
                    guard was, !now, let id = loadAnchorID else { return }
                    proxy.scrollTo(id, anchor: .top)
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .top)
                        loadAnchorID = nil
                    }
                }
                .onAppear {
                    settlingScroll = true
                    pinned = true
                    if !chat.loadingHistory {
                        windowToLatest()
                    }
                    jumpToBottom(proxy)
                    // Already past the history burst (a revisited chat):
                    // settle after the next layout rather than waiting for
                    // a loading edge that will not come.
                    if !chat.loadingHistory, !chat.rows.isEmpty {
                        DispatchQueue.main.async {
                            jumpToBottom(proxy)
                            settlingScroll = false
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    // The chat's own "back to the newest message", floating
                    // above the composer while the thread is scrolled up.
                    Button { scrollToken += 1 } label: {
                        ZStack {
                            Circle().fill(Palette.ground)
                            Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 40)
                    .padding(.bottom, 12)
                    .help("Scroll to bottom")
                    .accessibilityLabel("Scroll to bottom")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(Motion.quick, value: pinned)
        }
    }

    /// Spinner at the top of the list while an older page is requested, or
    /// a quiet placeholder so the header still has a drop target when there
    /// is more history above.
    private var loadOlderHeader: some View {
        HStack {
            Spacer(minLength: 0)
            if loadingMore {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Scroll for earlier messages")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .padding(.bottom, 8)
        .accessibilityLabel(loadingMore ? "Loading earlier messages" : "Scroll for earlier messages")
    }

    private var historySpinner: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.regular)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
        .accessibilityLabel("Loading conversation")
    }

    /// Keep only the newest page on screen after a history burst.
    private func windowToLatest() {
        hiddenPrefix = max(0, chat.rows.count - Self.pageSize)
        loadingMore = false
        loadAnchorID = nil
    }

    /// Reveal the next older page and remember the row that was at the top
    /// so the scroll can re-anchor after layout.
    private func loadOlder(using proxy: ScrollViewProxy) {
        guard !loadingMore, hiddenPrefix > 0 else { return }
        loadAnchorID = displayedRows.first?.id
        loadingMore = true
        let step = min(Self.pageSize, hiddenPrefix)
        Task { @MainActor in
            // Let the spinner paint before the list grows; the rows are
            // already in memory from the history stream.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            hiddenPrefix = max(0, hiddenPrefix - step)
            loadingMore = false
            _ = proxy
        }
    }

    /// How far the conversation fades before it meets the chrome: solid at
    /// the edge the bar or the composer sits against, gone by the first line
    /// that shows.
    private static let fade: CGFloat = 18

    /// One end of the transcript, faded to the ground the pane is drawn on.
    private func edgeFade(top: Bool) -> some View {
        LinearGradient(
            colors: top
                ? [Palette.ground, Palette.ground.opacity(0)]
                : [Palette.ground.opacity(0), Palette.ground],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.fade)
        .allowsHitTesting(false)
    }

    /// The tab's own bar: shared with the TUI agent pane. The agent's model
    /// and mode are not up here: they sit in the composer, beside the field
    /// they change (see `selects`). The status select is the card's, not the
    /// agent's — the terminal header wears the same one.
    private var header: some View {
        TabshSessionHeader(sessionID: sessionID,
                           title: sessions.info(for: sessionID)?.label ?? chat.agentName,
                           showingExplorer: $showingExplorer,
                           statusInMenu: false) {
            TabshHeaderStatusSelect(sessionID: sessionID)
        }
    }

    /// Messages by one sender sit close; a change of sender gets a breath,
    /// the way a thread separates one person's run from the other's.
    private func gap(before index: Int, in rows: [TabshChatRow]) -> CGFloat {
        guard index > 0, rows.indices.contains(index) else { return 0 }
        let previous = rows[index - 1]
        let row = rows[index]
        if previous.kind == row.kind, (row.kind == .user || row.kind == .agent) {
            return 3
        }
        return 14
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard pinned else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// Scroll to the newest message, then once more on the next turn so
    /// LazyVStack's deferred row heights do not leave the view short.
    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        pinned = true
        proxy.scrollTo("bottom", anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Text("No messages yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text("Ask the agent to work in this folder. It keeps going when the tab closes.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
    }

}

/// The agent chat's input card. Kept as its own view so typing the draft
/// does not rebuild the transcript above on every keystroke.
private struct TabshAgentComposer: View {
    let sessionID: String
    @ObservedObject var browser: Browser
    @ObservedObject var chat: TabshChat
    @Binding var scrollToken: Int

    /// What is in the composer. Kept for the session rather than the view:
    /// the pane is built again every time its tab comes back to the front (and
    /// the tab can be closed and restored), so a message half typed has to
    /// wait somewhere that outlives the view — its files and pictures too,
    /// not only its words.
    @State private var draft: String
    @State private var composerHeight: CGFloat = 32
    @State private var focusToken = 0
    @State private var attachments: [TabshPendingAttachment]
    @State private var uploading = false
    @State private var droppingFiles = false
    /// `@` opens a searchable list of the session's project files; the + disc
    /// still uses the system open panel for anything outside the tree.
    @State private var filesOpen = false
    /// `/` opens skills from the project and ~/.cursor/skills.
    @State private var skillsOpen = false
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var sessions = TabshSessions.shared

    init(sessionID: String, browser: Browser, chat: TabshChat, scrollToken: Binding<Int>) {
        self.sessionID = sessionID
        _browser = ObservedObject(wrappedValue: browser)
        _chat = ObservedObject(wrappedValue: chat)
        _scrollToken = scrollToken
        _draft = State(initialValue: TabshDrafts.shared.text(for: sessionID))
        _attachments = State(initialValue: TabshDrafts.shared.attachments(for: sessionID))
    }

    var body: some View {
        VStack(spacing: 7) {
            if let notice = chat.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The composer is one card: the attachments, the plus, the
            // mic, the field and the send all live inside its squircle.
            // Drops and pasted images land as chips here, not as raw
            // paths in the field (see TabshDrop). `@` / `/` float above
            // the card so opening them does not shift the layout.
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty { attachmentBar }

                // The plus, mic and the field sit close: the field's own
                // text inset is small too (see TabshComposerField), so the
                // placeholder starts a few points in from the disc.
                HStack(alignment: .bottom, spacing: 4) {
                    Button(action: chooseFiles) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .composerDisc()
                    }
                    .buttonStyle(.plain)
                    .disabled(uploading)
                    .help("Attach images or files")
                    .accessibilityLabel("Attach images or files")

                    // Same on-device dictation as the New Agent card and
                    // session terminals: settled words append to the draft.
                    Button(action: dictate) {
                        Image(systemName: dictation.busy ? "mic.fill" : "mic")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(dictation.busy ? Color(nsColor: .systemRed) : Palette.muted)
                            .composerDisc()
                    }
                    .buttonStyle(.plain)
                    .disabled(uploading)
                    .help(dictation.busy ? "Stop dictating" : "Dictate the message")
                    .accessibilityLabel(dictation.busy ? "Stop dictating" : "Dictate the message")

                    TabshComposerField(text: $draft,
                                       height: $composerHeight,
                                       focus: focusToken,
                                       placeholder: "Message",
                                       onSubmit: send,
                                       onFiles: attach,
                                       onPickFiles: {
                                           skillsOpen = false
                                           filesOpen = true
                                       },
                                       onPickSkills: {
                                           filesOpen = false
                                           skillsOpen = true
                                       })
                        .frame(height: composerHeight)

                    // Always keep the stop disc's width. Dropping it when the
                    // turn ends widened the field, remasured height, and could
                    // beachball the same way typing after a restart did.
                    Button(action: chat.stopTurn) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .composerDisc()
                    }
                    .buttonStyle(.plain)
                    .opacity(chat.busy ? 1 : 0)
                    .disabled(!chat.busy)
                    .allowsHitTesting(chat.busy)
                    .accessibilityHidden(!chat.busy)
                    .help("Stop the agent")
                    .accessibilityLabel("Stop the agent")

                    if uploading {
                        ProgressView()
                            .controlSize(.small)
                            .composerDisc()
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(canSend ? .white : Palette.faint)
                                .composerDisc(
                                    fill: canSend ? Color(nsColor: .controlAccentColor) : Palette.ground,
                                    ring: !canSend
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send")
                        .accessibilityLabel("Send")
                    }
                }

                // The agent's model and mode sit under the field, in reach of
                // the words they will send but out of the way of writing them.
                // Both stay hidden until the agent has answered: an ACP
                // session says what it offers only after its first turn.
                if chat.models != nil || chat.modes != nil {
                    selects
                        .padding(.bottom, 2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.settle, value: chat.models != nil || chat.modes != nil)
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            // The shadow is cast by the card's shape behind the field, never
            // by the card's own layers: laid over them, it fell from the plus,
            // the stop and the send as well, and the round buttons read as
            // raised on a card that is meant to be flat (see CardEdge).
            .background(
                Superellipse()
                    .fill(droppingFiles ? Palette.wash : composerGround)
                    .shadow(color: .black.opacity(CardEdge.shadow), radius: 2, y: 1)
            )
            .overlay(Superellipse().stroke(
                droppingFiles ? Color(nsColor: .controlAccentColor).opacity(0.55) : Palette.hairline,
                lineWidth: 1
            ))
            .onDrop(of: [.fileURL, .image, .png, .jpeg, .gif, .webP, .tiff],
                    isTargeted: $droppingFiles) { providers in
                TabshDrop.urls(from: providers) { attach($0) }
                return true
            }
            .overlay(alignment: .top) {
                Group {
                    if skillsOpen {
                        TabshComposerSkillPicker(
                            projectPath: sessions.sessions[sessionID]?.cwd
                        ) { skill in
                            applySkill(skill)
                            skillsOpen = false
                        } dismiss: {
                            skillsOpen = false
                        }
                        .frame(maxWidth: .infinity)
                        .composerMenuChrome()
                    } else if filesOpen {
                        TabshComposerFilePicker(sessionID: sessionID) { url in
                            attach([url])
                            filesOpen = false
                        } dismiss: {
                            filesOpen = false
                        }
                        .frame(maxWidth: .infinity)
                        .composerMenuChrome()
                    }
                }
                .floatAboveComposer()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .animation(Motion.settle, value: skillsOpen || filesOpen)
        }
        // No bar behind the field: the composer's own card is the only
        // surface, so the conversation runs down to the same ground rather
        // than ending on a grey footer. zIndex keeps the floating `@` / `/`
        // menu above the transcript when it draws past the card's top.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .zIndex((skillsOpen || filesOpen) ? 2 : 0)
        .onAppear {
            draft = TabshDrafts.shared.text(for: sessionID)
            focusToken += 1
        }
        // Every keystroke is kept: the store writes the map through
        // UserDefaults, which holds it in memory and flushes it on its own.
        .onChange(of: draft) { _, text in
            TabshDrafts.shared.set(text, for: sessionID)
        }
        // The chips wait with the words. Sending clears the array, and that
        // clears the draft too (see send), so a sent message leaves none.
        .onChange(of: attachments) { _, waiting in
            TabshDrafts.shared.setAttachments(waiting, for: sessionID)
        }
        .onReceive(NotificationCenter.default.publisher(for: TabshDrafts.dictatedName)) { note in
            guard (note.object as? String) == sessionID else { return }
            draft = TabshDrafts.shared.text(for: sessionID)
        }
    }

    /// Speaks the message, on device (see Dictation.swift). Each settled
    /// piece is appended to the draft, with a space between; the field
    /// keeps the keyboard throughout.
    private func dictate() {
        if dictation.busy {
            dictation.stop()
            return
        }
        dictation.begin { words in
            guard !words.isEmpty else { return }
            let gap = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
            draft += gap + words
        }
    }

    private var composerGround: Color {
        if let theme = browser.chromeTheme { return Color(nsColor: theme.color) }
        return browser.asCards ? Palette.frame : Palette.ground
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    TabshAttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
        .frame(height: 58)
    }

    /// The model and the mode the agent advertises, the same muted capsules
    /// the header used to wear, under the composer's field.
    private var selects: some View {
        HStack(spacing: 6) {
            if let models = chat.models, !models.options.isEmpty {
                TabshModelPicker(select: models,
                                 busy: chat.busy || chat.changingOption,
                                 choose: chat.selectModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
            if let modes = chat.modes, !modes.options.isEmpty {
                TabshModePicker(select: modes,
                                busy: chat.busy || chat.changingOption,
                                choose: chat.selectMode)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 1)
        // Modes often arrive a beat after models; each capsule eases in on
        // its own rather than popping beside the one already there.
        .animation(Motion.settle, value: chat.models != nil)
        .animation(Motion.settle, value: chat.modes != nil)
    }

    private var canSend: Bool {
        !uploading
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !attachments.isEmpty else {
            draft = ""
            chat.send(text)
            focusToken += 1
            // A message sent from up the thread is still the newest thing,
            // so the view goes to it as a chat does.
            scrollToken += 1
            return
        }

        let picking = attachments
        let draftAtSend = draft
        uploading = true
        Task { @MainActor in
            do {
                var paths: [String] = []
                for attachment in picking {
                    paths.append(try await Tabsh.upload(file: attachment.url))
                }
                let combined = Self.withImages(text, paths)
                attachments.removeAll()
                // The chips are gone with the message, and so is what the
                // next build of this composer would have restored.
                TabshDrafts.shared.setAttachments([], for: sessionID)
                // Keep anything typed while the files were going up.
                if draft == draftAtSend { draft = "" }
                uploading = false
                chat.send(combined)
                focusToken += 1
                scrollToken += 1
            } catch {
                uploading = false
                chat.notice = error.localizedDescription
            }
        }
    }

    /// The web's shape: the prompt, a blank line, then one path a line, so
    /// the agent reads the images beside what was asked.
    private static func withImages(_ text: String, _ paths: [String]) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty else { return body }
        let files = paths.joined(separator: "\n")
        return body.isEmpty ? files : body + "\n\n" + files
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Attach images or files to the message"
        let add: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            attach(panel.urls)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls where !attachments.contains(where: { $0.url == url }) {
            attachments.append(TabshPendingAttachment(url: url))
        }
        focusToken += 1
    }

    /// Mentions the skill in the draft and attaches its `SKILL.md`, so the
    /// agent both sees `/name` and can read the instructions.
    private func applySkill(_ skill: TabshSkill) {
        let mention = "/\(skill.name)"
        let gap = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        draft += gap + mention + " "
        attach([skill.url])
    }
}

/// One file waiting in the composer: a square thumbnail — the picture itself
/// for images, a Quick Look preview (or a doc mark and extension) for
/// everything else — with the cross that takes it back out. Shared by the
/// agent chat and New Agent so a drop looks the same in both.
struct TabshAttachmentChip: View {
    let attachment: TabshPendingAttachment
    let remove: () -> Void

    @State private var image: NSImage?

    private static let size: CGFloat = 48
    private static let radius: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    fileTile
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Palette.muted, Palette.ground)
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove \(attachment.name)")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
        .help(attachment.name)
        .task(id: attachment.url) {
            image = nil
            if attachment.isImage {
                image = NSImage(contentsOf: attachment.url)
            } else {
                image = await Self.preview(of: attachment.url)
            }
        }
    }

    /// Same 48pt square as an image thumb: a paper mark over the short
    /// extension (or the filename when there is none), so a row of mixed
    /// attachments reads as one strip of tiles when Quick Look has nothing.
    private var fileTile: some View {
        let ext = attachment.url.pathExtension
        let label = ext.isEmpty
            ? attachment.name
            : ext.uppercased()
        return VStack(spacing: 3) {
            Image(systemName: "doc")
                .font(.system(size: 16, weight: .medium))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }

    /// A Quick Look page of the file, sized for the chip — so a PDF sits at
    /// the same height as a screenshot instead of a shorter name pill.
    private static func preview(of url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: 2,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// `@` on the composer: a searchable list of the project's files (the same
/// tree the explorer reads), so attaching stays inside the card instead of
/// bouncing out to the system open panel. The + disc still opens that panel
/// for files outside the tree.
struct TabshComposerFilePicker: View {
    var sessionID: String? = nil
    var rootPath: String? = nil
    let pick: (URL) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var root = ""
    @State private var files: [String] = []
    @State private var active = 0
    @State private var loading = true
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var filtered: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading project files…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            } else if filtered.isEmpty {
                Text(files.isEmpty ? "No files in this project yet." : "No files match.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                optionsList
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
        .onChange(of: query) { _, _ in
            active = filtered.isEmpty ? -1 : 0
        }
        .onKeyPress(.upArrow) {
            active = TabshFolders.moveActive(active, by: -1, count: filtered.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            active = TabshFolders.moveActive(active, by: 1, count: filtered.count)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            TextField("Search project files…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { chooseActive() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.hover)
        )
        .onAppear { focused = true }
    }

    private var optionsList: some View {
        let rows = filtered
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, path in
                        optionRow(index: index, path: path)
                    }
                }
                .padding(4)
            }
            // Same as the model wheel: a legacy scroller in a popover reads
            // as a thick grey strip beside the rows.
            .scrollIndicators(.never)
            .frame(height: listHeight(for: rows.count))
            .onChange(of: active) {
                guard active >= 0, active < rows.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
    }

    private static let rowHeight: CGFloat = 25
    private static let listMaxHeight: CGFloat = 240

    private func listHeight(for count: Int) -> CGFloat {
        let rows = CGFloat(count) * Self.rowHeight + CGFloat(max(count - 1, 0)) + 8
        return min(rows, Self.listMaxHeight)
    }

    private func optionRow(index: Int, path: String) -> some View {
        let lit = index == active
        return Button { choose(path) } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Text(path)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lit ? Palette.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: Self.rowHeight)
        .id(index)
        .help(absoluteURL(path)?.path ?? path)
    }

    private func chooseActive() {
        let rows = filtered
        guard active >= 0, active < rows.count else { return }
        choose(rows[active])
    }

    private func choose(_ path: String) {
        guard let url = absoluteURL(path) else { return }
        pick(url)
    }

    private func absoluteURL(_ relative: String) -> URL? {
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root)
            .appendingPathComponent(relative)
            .standardizedFileURL
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            let tree: Tabsh.Tree
            if let sessionID, !sessionID.isEmpty {
                tree = try await Tabsh.tree(session: sessionID)
            } else if let rootPath, !rootPath.isEmpty {
                tree = try await Tabsh.tree(path: rootPath)
            } else {
                failure = "No project folder to list."
                loading = false
                return
            }
            root = tree.root
            files = tree.paths
                .filter { !$0.hasSuffix("/") }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            active = files.isEmpty ? -1 : 0
            loading = false
        } catch {
            failure = error.localizedDescription
            loading = false
        }
    }
}

/// The model select, opened as a searchable list rather than a menu of every
/// model the agent advertises. The right of each row says who makes it; the
/// current one keeps its tick.
private struct TabshModelPicker: View {
    let select: Tabsh.ChatSelect
    let busy: Bool
    let choose: (String) -> Void

    @State private var open = false
    @State private var query = ""
    @FocusState private var searching: Bool

    private var current: String {
        select.options.first { $0.id == select.current }?.name
            ?? select.current
            ?? "Model"
    }

    private var filtered: [Tabsh.ChatSelect.Choice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return select.options }
        return select.options.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.id.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .medium))
                Text(current)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.hover))
        }
        .buttonStyle(.plain)
        .help("Model")
        .disabled(busy)
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("Search models… (Esc to go back)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                    .onExitCommand { open = false }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rule()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("MODEL")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(filtered) { option in
                        Button {
                            choose(option.id)
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(option.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if option.id == select.current {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(Palette.muted)
                                }
                                Text(brand(for: option))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Palette.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(option.id == select.current ? Palette.hover : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text("No models match.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 360, height: 380)
        .onAppear {
            DispatchQueue.main.async { searching = true }
        }
    }

    private func brand(for option: Tabsh.ChatSelect.Choice) -> String {
        let text = "\(option.id) \(option.name)".lowercased()
        if text.contains("claude") { return "Anthropic" }
        if text.contains("gpt") || text.contains("openai") || text.contains("codex") {
            return "OpenAI"
        }
        if text.contains("gemini") { return "Google" }
        if text.contains("cursor") || text.contains("composer") { return "Cursor" }
        if text.contains("grok") { return "xAI" }
        if text.contains("kimi") { return "Moonshot" }
        if text.contains("glm") { return "Zhipu" }
        if text.contains("deepseek") { return "DeepSeek" }
        return ""
    }
}

/// The agent's mode, opened the way the model picker opens: a pill in the
/// header and a list under it. A `Menu` here drew the label in the system's
/// own type — a raw shield and a larger, darker word — so the two selects
/// side by side were two shapes. A button keeps the pill the pill.
private struct TabshModePicker: View {
    let select: Tabsh.ChatSelect
    let busy: Bool
    let choose: (String) -> Void

    @State private var open = false

    private var current: String {
        select.options.first { $0.id == select.current }?.name
            ?? select.current
            ?? "Mode"
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 9, weight: .medium))
                Text(current)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.hover))
        }
        .buttonStyle(.plain)
        .help("Agent mode")
        .disabled(busy)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TabshModeList(options: select.options,
                          current: select.current) { id in
                choose(id)
                open = false
            }
        }
    }
}

/// The modes' list, shared by the chat's header and the New Agent card: the
/// same heading, rows and tick the model picker uses, without the search a
/// two- or three-item list does not need.
struct TabshModeList: View {
    let options: [Tabsh.ChatSelect.Choice]
    let current: String?
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODE")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(options) { option in
                Button { choose(option.id) } label: {
                    HStack(spacing: 8) {
                        Text(option.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if option.id == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(option.id == current ? Palette.hover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 240)
    }
}

private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Where the "load older" header sits in the transcript's scroll space.
private struct ChatTopKey: PreferenceKey {
    static var defaultValue: CGFloat = -.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Tracks the transcript scroll view's clip offset between its bounds
/// notifications, and says when a change is the reader going back up the
/// conversation.
///
/// A precise trackpad moves the clip in fractions of a point, so a slow
/// scroll is added up over notifications rather than reset by each one. A
/// resize is not a scroll even though the reflow can move the clip.
struct ChatScrollTravel {
    private var last: CGFloat?
    private var size: NSSize?

    /// Feed each clip-bounds change. True means upward travel far enough to
    /// count: the reader has taken the list from the agent.
    mutating func moved(to y: CGFloat, in size: NSSize) -> Bool {
        let resized = self.size.map { $0 != size } ?? false
        self.size = size
        guard !resized, let last else {
            self.last = y
            return false
        }
        if y < last - 0.5 {
            // Up the conversation: the content slid down, so the clip's
            // origin went back towards zero.
            self.last = y
            return true
        }
        if y > last + 0.5 {
            // Down towards the newest line. Track it so an earlier run of
            // upward travel does not count later.
            self.last = y
        }
        // Either side within half a point: leave `last` where it is, so a
        // slow scroll adds up.
        return false
    }
}

/// Hears the transcript's own scroll view when the reader moves the list up.
///
/// The bottom marker alone cannot tell the two ways it travels: a streamed
/// token grows the list under a pinned viewport and a hand scrolling back
/// through the conversation both push the marker down. While the agent is
/// busy the pane therefore used to chase the marker and pull itself back to
/// the newest line on every token, so past messages could not be read until
/// the turn ended. The scroll view's offset is the difference: a token never
/// moves it, and a reader going up is the only thing that moves it towards
/// the start. Our own `scrollTo` only ever goes the other way.
///
/// It sits as a background inside the content, never in front of it: the
/// watch view takes no click, no selection and no scroll.
private struct ChatScrollWatch: NSViewRepresentable {
    let onScrollUp: () -> Void

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.onScrollUp = onScrollUp
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) {
        view.onScrollUp = onScrollUp
    }

    final class WatchView: NSView {
        var onScrollUp: (() -> Void)?

        private weak var watched: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var travel = ChatScrollTravel()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }

        /// The nearest scroll view is the transcript. SwiftUI builds the
        /// background before it is in a window, hence both hooks above.
        private func attach() {
            guard let scroll = enclosingScrollView, scroll !== watched else { return }
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            watched = scroll
            travel = ChatScrollTravel()
            let bounds = scroll.contentView.bounds
            _ = travel.moved(to: bounds.origin.y, in: bounds.size)
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                // Synchronously, on the scroll's own thread (the main one):
                // the pin has to be dropped before SwiftUI's next layout
                // pass can read it and chase the newest line.
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.moved() }
            }
        }

        private func moved() {
            guard let scroll = watched else { return }
            let bounds = scroll.contentView.bounds
            if travel.moved(to: bounds.origin.y, in: bounds.size) {
                onScrollUp?()
            }
        }
    }
}

/// One of the round buttons that end the composer. The plus, the stop, the
/// spinner and the send are all this disc, so they sit on one centre line —
/// they used to be 26 and 28 points, bottom-aligned in the field's row,
/// which put them a point apart and both of them low.
extension View {
    func composerDisc(fill: Color = Palette.ground, ring: Bool = true) -> some View {
        self
            .frame(width: ComposerDisc.size, height: ComposerDisc.size)
            .background(Circle().fill(fill))
            .overlay {
                if ring {
                    Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                }
            }
            // Bottom-aligned in the field's row: lifted the two points that
            // put the disc's centre on the text's line rather than its floor.
            .padding(.bottom, ComposerDisc.lift)
    }

    /// Card chrome for the `@` / `/` menus that sit above the composer.
    /// Prefer this over `.popover` — the AppKit field anchors those wrong.
    func composerMenuChrome() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )
    }

    /// Pin this view just above a parent's top edge in an `.overlay(alignment:
    /// .top)`, without taking vertical layout space in the parent.
    func floatAboveComposer(gap: CGFloat = 6) -> some View {
        self
            .padding(.bottom, gap)
            .alignmentGuide(.top) { $0[.bottom] }
    }
}

enum ComposerDisc {
    static let size: CGFloat = 28
    static let lift: CGFloat = 2
}

// MARK: - Rows

private struct TabshChatRowView: View, Equatable {
    let row: TabshChatRow
    /// Not `@ObservedObject`: busy/waiting flips on stop must not rebuild
    /// every bubble. Approve/answer only need a reference to call into.
    let chat: TabshChat

    @Environment(\.colorScheme) private var scheme
    @State private var unfolded = false
    @State private var answered = false

    /// The chat handle is identity for actions; what is drawn is the row.
    static func == (lhs: TabshChatRowView, rhs: TabshChatRowView) -> Bool {
        lhs.row == rhs.row
    }

    @ViewBuilder
    var body: some View {
        switch row.kind {
        case .user:
            user
        case .agent:
            agent
        case .tool:
            tool
        case .toolGroup:
            toolGroup
        case .plan:
            HStack {
                Spacer(minLength: 0)
                Text(row.text)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
        case .permission:
            permission
        case .question:
            TabshQuestionCard(row: row, chat: chat)
        case .error:
            error
        }
    }

    /// The blue bubble on the right, and the newest one carrying a receipt
    /// the way a sent message does.
    private var user: some View {
        let body = textWithoutImagePaths(row.text)
        return HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 2) {
                if !body.isEmpty {
                    TabshMarkdownBubble(text: body, color: .white, onAccent: true)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(userBubble)
                        )
                        // The cap belongs outside the bubble: it wraps a long
                        // line, but a short one still makes a short bubble.
                        .frame(maxWidth: 720, alignment: .trailing)
                        .opacity(row.queued ? 0.7 : 1)
                }

                ForEach(imageRefs(in: row.text), id: \.self) { url in
                    ChatImage(url: url)
                        .frame(maxWidth: 520, alignment: .trailing)
                        .padding(.top, 4)
                }

                if !row.receipt.isEmpty {
                    Text(row.receipt)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                        .padding(.trailing, 5)
                }
            }
        }
    }

    /// The agent's grey bubble on the left. One header names the agent, so
    /// the messages themselves need no avatar.
    private var agent: some View {
        let body = textWithoutImagePaths(row.text)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if !body.isEmpty {
                    // While tokens arrive, skip markdown parsing: AttributedString
                    // and the block parser on every delta were the expensive part
                    // of a long answer. Settled rows keep the full bubble.
                    Group {
                        if row.streaming {
                            Text(body)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TabshMarkdownBubble(text: body, color: Palette.ink)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(agentBubble)
                    )
                    .frame(maxWidth: 720, alignment: .leading)
                }

                ForEach(imageRefs(in: row.text), id: \.self) { url in
                    ChatImage(url: url)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            Spacer(minLength: 56)
        }
    }

    /// A tool call, drawn as the attachment cards in a message thread: a
    /// glyph, a name, and the command underneath. It unfolds to the output.
    private var tool: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolLine(row, expandable: true)
            if unfolded, !row.detail.isEmpty {
                Text(row.detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(agentBubble.opacity(0.42))
                    )
            }
        }
        .frame(maxWidth: 430, alignment: .leading)
        .animation(Motion.quick, value: unfolded)
    }

    /// A run of tool calls as one fold, as an agent's activity reads: how many
    /// operations, opened to the calls themselves.
    private var toolGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.quick) { unfolded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(unfolded ? 0 : -90))
                    Text(row.text.isEmpty ? "\(row.children.count) operations" : row.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if unfolded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(row.children) { child in
                        toolLine(child, expandable: false)
                    }
                }
                .padding(.leading, 15)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 430, alignment: .leading)
    }

    private func toolLine(_ item: TabshChatRow, expandable: Bool) -> some View {
        Button {
            if expandable, !item.detail.isEmpty { unfolded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(item))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .frame(width: 12)
                Text(item.text.isEmpty ? "Tool" : item.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !toolSubtitle(item).isEmpty {
                    Text(toolSubtitle(item))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if expandable, !item.detail.isEmpty {
                    Image(systemName: unfolded ? "chevron.up" : "ellipsis")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agentBubble.opacity(0.55))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(item.detail)
    }

    private var permission: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(row.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            if answered {
                Text("Answered")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.faint)
            } else {
                Button("Deny") { answer(false) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("Allow") { answer(true) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 430, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(agentBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.hairline)
        )
        .padding(.leading, 5)
    }

    private var error: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(row.text)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
        }
        .foregroundStyle(Palette.unsafe)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.unsafe.opacity(0.1))
        )
        .padding(.leading, 5)
    }

    private var userBubble: Color {
        Color(nsColor: .controlAccentColor)
    }

    private var agentBubble: Color {
        agentSurface(scheme)
    }

    private func toolSubtitle(_ item: TabshChatRow) -> String {
        item.detail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "Tool call"
    }

    private func toolIcon(_ item: TabshChatRow) -> String {
        let text = (item.text + " " + item.detail).lowercased()
        if text.contains("read") || text.contains("write")
            || text.contains("edit") || text.contains("file") {
            return "doc.text"
        }
        if text.contains("search") || text.contains("grep") || text.contains("find") {
            return "magnifyingglass"
        }
        if text.contains("terminal") || text.contains("shell")
            || text.contains("bash") || text.contains("command") {
            return "terminal"
        }
        return "wrench.and.screwdriver"
    }

    private func answer(_ allow: Bool) {
        guard !answered else { return }
        answered = true
        chat.approve(row.requestID, allow: allow)
    }
}

// MARK: - A question

/// The agent's question, drawn as a form instead of a folded tool row: its
/// words, one control per field, and the answer. What has been typed or
/// picked lives in the card until it is sent, so the transcript rebuilding
/// on every streamed token does not wipe a half-filled answer.
private struct TabshQuestionCard: View {
    let row: TabshChatRow
    /// Reference only — see `TabshChatRowView.chat`.
    let chat: TabshChat

    @Environment(\.colorScheme) private var scheme
    @State private var values: [String: Value] = [:]
    /// The answer was sent from here and the transcript has not echoed it
    /// yet; the row's own `answer` takes over once it does.
    @State private var sent = false

    /// What a field holds before it becomes JSON. `number` fields type into
    /// `.text` and are parsed on send, so a half-typed "1." is not lost.
    private enum Value: Equatable {
        case text(String)
        case yesNo(Bool)
        case pick(String)
        case picks(Set<String>)
    }

    private var form: TabshQuestionForm? { row.form }
    private var fields: [TabshQuestionForm.Field] { form?.fields ?? [] }
    private var isAnswered: Bool { sent || !row.answer.isEmpty }
    private var message: String {
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The agent has a question" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isAnswered {
                answer
            } else {
                ForEach(fields) { field in
                    fieldView(field)
                }
                footer
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(agentSurface(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.hairline)
        )
        .padding(.leading, 5)
    }

    /// The card once it has been answered: the question stays, with what was
    /// chosen under it, as a permission that says "Answered" does.
    private var answer: some View {
        let declined = row.answer == "Declined" || row.answer == "Dismissed"
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: declined ? "xmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(declined ? Palette.muted : Color(nsColor: .controlAccentColor))
                .padding(.top, 0.5)
            Text(row.answer.isEmpty ? "Answered" : row.answer)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.ground)
        )
    }

    @ViewBuilder
    private func fieldView(_ field: TabshQuestionForm.Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // The header often repeats the message ("Draft storage" over a
            // question about drafts); say it once.
            if field.title != message {
                Text(field.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            if !field.detail.isEmpty, field.detail != message {
                Text(field.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch field.kind {
            case let .pick(choices):
                choiceList(field, choices: choices, multiple: false)
            case let .picks(choices):
                choiceList(field, choices: choices, multiple: true)
            case .yesNo:
                yesNo(field)
            case .text, .number:
                textField(field)
            }        }
    }

    private func choiceList(_ field: TabshQuestionForm.Field,
                            choices: [TabshQuestionForm.Choice],
                            multiple: Bool) -> some View {
        VStack(spacing: 3) {
            ForEach(choices) { choice in
                let picked = isPicked(choice.id, in: field, multiple: multiple)
                Button {
                    pick(choice.id, in: field, multiple: multiple)
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: picked
                              ? (multiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                              : (multiple ? "square" : "circle"))
                            .font(.system(size: 11))
                            .foregroundStyle(picked
                                             ? Color(nsColor: .controlAccentColor)
                                             : Palette.faint)
                            .padding(.top, 0.5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            if let detail = choice.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(picked ? Palette.hover : Palette.ground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(picked
                                    ? Color(nsColor: .controlAccentColor).opacity(0.45)
                                    : Palette.hairline,
                                    lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }

    private func yesNo(_ field: TabshQuestionForm.Field) -> some View {
        HStack(spacing: 6) {
            ForEach([true, false], id: \.self) { flag in
                let picked = values[field.id] == .yesNo(flag)
                Button {
                    values[field.id] = .yesNo(flag)
                } label: {
                    Text(flag ? "Yes" : "No")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(picked ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(picked ? Palette.hover : Palette.ground)
                        )
                        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
            }
            Spacer(minLength: 0)
        }
    }

    private func textField(_ field: TabshQuestionForm.Field) -> some View {
        let binding = Binding<String>(
            get: {
                if case let .text(text)? = values[field.id] { return text }
                return ""
            },
            set: { values[field.id] = .text($0) }
        )
        return TextField(field.required ? "Your answer" : "Optional",
                         text: binding,
                         axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ink)
            .lineLimit(1...4)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.ground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )
            .disabled(isAnswered)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            Button("Decline") { send("decline") }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button(action: { send("accept") }) {
                    Text("Send")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(canSend
                                           ? Color(nsColor: .controlAccentColor)
                                           : Color(nsColor: .controlAccentColor).opacity(0.35))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(canSend ? "Send the answer" : "Answer a field first")
        }
    }

    // MARK: Filling and sending

    private func isPicked(_ id: String,
                          in field: TabshQuestionForm.Field,
                          multiple: Bool) -> Bool {
        switch values[field.id] {
        case let .pick(picked)?: return !multiple && picked == id
        case let .picks(picked)?: return multiple && picked.contains(id)
        default: return false
        }
    }

    private func pick(_ id: String,
                      in field: TabshQuestionForm.Field,
                      multiple: Bool) {
        guard multiple else {
            values[field.id] = .pick(id)
            return
        }
        var picked: Set<String>
        if case let .picks(current)? = values[field.id] {
            picked = current
        } else {
            picked = []
        }
        if picked.contains(id) {
            picked.remove(id)
        } else {
            picked.insert(id)
        }
        values[field.id] = .picks(picked)
    }

    /// Every required field must be answered, and a form needs at least one
    /// answer to send: an empty accept tells the agent nothing, and "Decline"
    /// is the honest way to say nothing.
    private var canSend: Bool {
        guard !fields.isEmpty else { return false }
        let answeredAll = fields.allSatisfy { field in
            guard field.required else { return true }
            switch (field.kind, values[field.id]) {
            case (.pick, .pick), (.picks, .picks), (.yesNo, .yesNo):
                return true
            case (.number, let .text(raw)?):
                return Double(raw.trimmingCharacters(in: .whitespaces)) != nil
            case (_, let .text(raw)?):
                return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
        return answeredAll && fields.contains { isAnswered($0) }
    }

    private func isAnswered(_ field: TabshQuestionForm.Field) -> Bool {
        switch values[field.id] {
        case let .text(raw)?:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if case .number = field.kind { return Double(trimmed) != nil }
            return true
        case .yesNo?, .pick?: return true
        case let .picks(ids)?: return !ids.isEmpty
        case nil: return false
        }
    }

    private func send(_ action: String) {
        guard action == "decline" || canSend else { return }
        sent = true
        chat.answer(row.requestID,
                    action: action,
                    content: action == "accept" ? content() : nil)
    }

    private func content() -> [String: Any] {
        var content: [String: Any] = [:]
        for field in fields {
            switch (field.kind, values[field.id]) {
            case let (.number(integer), .text(raw)?):
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if let number = Double(trimmed) {
                    if integer {
                        content[field.id] = Int(number) ?? number
                    } else {
                        content[field.id] = number
                    }
                }
            case let (_, .text(raw)?):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { content[field.id] = trimmed }
            case let (_, .yesNo(flag)?):
                content[field.id] = flag
            case let (_, .pick(id)?):
                content[field.id] = id
            case let (_, .picks(ids)?):
                if !ids.isEmpty { content[field.id] = ids.sorted() }
            default:
                break
            }
        }
        return content
    }
}

/// The grey an agent's own surface sits on: its bubbles, and the cards that
/// ask something.
private func agentSurface(_ scheme: ColorScheme) -> Color {
    scheme == .dark
        ? Color(red: 0.16, green: 0.16, blue: 0.17)
        : Color(red: 0.90, green: 0.90, blue: 0.92)
}

// MARK: - Markdown

/// A message's markdown, block by block. SwiftUI's Text understands inline
/// markdown but not block structure: headings, lists, code fences, quotes,
/// rules and tables all run into one another when the whole document is one
/// attributed string. Parsing the blocks here lets each one keep its own
/// shape inside the bubble.
private struct TabshMarkdownBubble: View {
    private let blocks: [MarkdownBlock]
    private let color: Color
    private let onAccent: Bool

    @Environment(\.colorScheme) private var scheme

    init(text: String, color: Color, onAccent: Bool = false) {
        self.color = color
        self.onAccent = onAccent
        blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inline(text, size: 12.5)
        case let .heading(level, text):
            inline(text, size: headingSize(level), weight: .semibold)
                .padding(.top, 2)
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(item)
                }
            }
        case let .code(code, language):
            codeBlock(code, language: language)
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color.opacity(0.35))
                    .frame(width: 2)
                inline(text, size: 12.5)
                    .foregroundStyle(color.opacity(0.82))
            }
        case .rule:
            Rectangle()
                .fill(color.opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, 4)
        case let .table(header, rows):
            table(header, rows)
        }
    }

    private func inline(_ text: String,
                        size: CGFloat,
                        weight: Font.Weight = .regular) -> some View {
        Text(attributed(text, size: size))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func listRow(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let checked = item.checked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(color.opacity(0.85))
                    .frame(width: 14, alignment: .trailing)
            } else if item.ordered {
                Text("\(item.number ?? 1).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(color.opacity(0.8))
                    .frame(minWidth: 18, alignment: .trailing)
            } else {
                Text("•")
                    .font(.system(size: 12.5))
                    .foregroundStyle(color.opacity(0.8))
                    .frame(width: 14, alignment: .trailing)
            }
            inline(item.text, size: 12.5)
        }
        .padding(.leading, CGFloat(item.depth) * 14)
    }

    private func codeBlock(_ code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color.opacity(0.5))
            }
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(codeBackground)
                )
        }
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        VStack(spacing: 0) {
            tableRow(header, heading: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Rectangle()
                    .fill(color.opacity(0.16))
                    .frame(height: 1)
                tableRow(row, heading: false)
            }
        }
        .padding(.vertical, 2)
    }

    private func tableRow(_ cells: [String], heading: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inline(cell, size: 11.5, weight: heading ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private var codeBackground: Color {
        if onAccent { return Color.white.opacity(0.16) }
        return scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        let sizes: [CGFloat] = [17, 15.5, 14, 13, 12.5, 12.5]
        return sizes[min(max(level, 1), 6) - 1]
    }

    /// Inline markdown only: bold, italic, inline code and links. Setting a
    /// monospaced font on code runs is the one thing AttributedString leaves
    /// to the view. On the accent colour every run turns white, and links
    /// keep an underline so they remain visible.
    private func attributed(_ text: String, size: CGFloat) -> AttributedString {
        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            attributed = AttributedString(text)
        }

        for run in attributed.runs
        where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: size - 1, design: .monospaced)
        }

        if onAccent {
            for run in attributed.runs {
                attributed[run.range].foregroundColor = .white
                if run.link != nil {
                    attributed[run.range].underlineStyle = .single
                }
            }
        }
        return attributed
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case list([MarkdownListItem])
    case code(String, String?)
    case quote(String)
    case rule
    case table([String], [[String]])
}

struct MarkdownListItem {
    let depth: Int
    let ordered: Bool
    let number: Int?
    let checked: Bool?
    let text: String
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listOpen = false
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: " ")))
            quote.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                listOpen = false
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                listOpen = false
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                flushQuote()
                listOpen = false
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3)
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    code.append(next)
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n"),
                                    language.isEmpty ? nil : language))
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                flushQuote()
                listOpen = false
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                flushQuote()
                listOpen = false
                blocks.append(.rule)
                index += 1
                continue
            }

            if let table = table(lines, at: index) {
                flushParagraph()
                flushQuote()
                listOpen = false
                blocks.append(.table(table.header, table.rows))
                index = table.next
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                if listOpen,
                   case .list(var items) = blocks.last,
                   items.last?.ordered == item.ordered {
                    items.append(item)
                    blocks[blocks.count - 1] = .list(items)
                } else {
                    blocks.append(.list([item]))
                    listOpen = true
                }
                index += 1
                continue
            }

            flushQuote()
            listOpen = false
            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        flushQuote()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        var leading = 0
        for character in line {
            if character == " " {
                leading += 1
            } else if character == "\t" {
                leading += 4
            } else {
                break
            }
        }
        let text = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(text)
        guard !characters.isEmpty else { return nil }

        if characters.count > 2, "-*+".contains(characters[0]), characters[1] == " " {
            var content = String(characters.dropFirst(2))
            var checked: Bool?
            if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                checked = true
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[ ] ") {
                checked = false
                content = String(content.dropFirst(4))
            }
            return MarkdownListItem(depth: leading / 2,
                                    ordered: false,
                                    number: nil,
                                    checked: checked,
                                    text: content)
        }

        var digits = ""
        var at = 0
        while at < characters.count, characters[at].isNumber {
            digits.append(characters[at])
            at += 1
        }
        if !digits.isEmpty, at < characters.count,
           characters[at] == "." || characters[at] == ")",
           at + 1 < characters.count, characters[at + 1] == " " {
            return MarkdownListItem(depth: leading / 2,
                                    ordered: true,
                                    number: Int(digits),
                                    checked: nil,
                                    text: String(characters.dropFirst(at + 2)))
        }
        return nil
    }

    private static func table(_ lines: [String],
                              at index: Int) -> (header: [String],
                                                 rows: [[String]],
                                                 next: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        let alignLine = lines[index + 1]
        guard headerLine.contains("|"), alignLine.contains("|") else { return nil }

        let header = cells(headerLine)
        let aligns = cells(alignLine)
        guard !header.isEmpty, aligns.count == header.count,
              aligns.allSatisfy(isSeparator) else { return nil }

        var rows: [[String]] = []
        var at = index + 2
        while at < lines.count {
            let line = lines[at]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard line.contains("|") else { break }
            var row = cells(line)
            if row.count < header.count {
                row += Array(repeating: "", count: header.count - row.count)
            } else if row.count > header.count {
                row = Array(row.prefix(header.count))
            }
            rows.append(row)
            at += 1
        }
        return (header, rows, at)
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ cell: String) -> Bool {
        let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }
}

/// A growing message field: one line when there is one, up to eight when
/// there are more, and a scroll beyond that. Return sends, as in the web
/// panel; Shift-Return and Option-Return write a line break. Files dropped
/// or images pasted become attachments rather than raw paths in the text.
/// Shared by the agent chat and the New Agent page.
struct TabshComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focus: Int
    var placeholder: String
    let onSubmit: () -> Void
    var onFiles: (([URL]) -> Void)? = nil
    /// `@` at a token boundary — project file list on the composer.
    var onPickFiles: (() -> Void)? = nil
    /// `/` at a token boundary — skills under the project and ~/.cursor.
    var onPickSkills: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.focusRingType = .none
        scroll.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }

        let text = TabshAttachTextView()
        text.delegate = context.coordinator
        text.onFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onFiles?(urls)
        }
        text.onPickFiles = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPickFiles?()
        }
        text.onPickSkills = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPickSkills?()
        }
        text.isRichText = false
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = NSFont.systemFont(ofSize: 12.5)
        text.textColor = .labelColor
        text.insertionPointColor = .controlAccentColor
        // A small inset: the plus disc and the send disc already hold the
        // text off the card's edge, and a wide one left a gap between the
        // plus and the placeholder that read as two separate controls.
        text.textContainerInset = NSSize(width: 5, height: 8)
        // Drawn by the field itself, so it starts exactly where the caret
        // does (see TabshAttachTextView.draw).
        text.placeholder = placeholder
        text.placeholderColor = NSColor(Palette.muted)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            text.writingToolsBehavior = .none
            text.mathExpressionCompletionType = .no
        }
        text.string = self.text
        text.registerFileDrops()

        scroll.documentView = text
        context.coordinator.textView = text
        context.coordinator.lastFocus = focus
        DispatchQueue.main.async {
            text.window?.makeFirstResponder(text)
            context.coordinator.updateHeight()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? TabshAttachTextView else { return }
        context.coordinator.parent = self
        textView.onFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onFiles?(urls)
        }
        textView.onPickFiles = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPickFiles?()
        }
        textView.onPickSkills = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPickSkills?()
        }
        // Remeasure only when the binding pushed different text in (dictation,
        // restore). Keystrokes already remeasure in textDidChange; calling
        // updateHeight on every SwiftUI pass fed height ↔ layout forever and
        // beachballed the first character after a restart.
        var remounted = false
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
            remounted = true
        }
        textView.placeholder = placeholder
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        if remounted {
            context.coordinator.updateHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TabshComposerField
        weak var textView: NSTextView?
        var lastFocus = 0
        /// Coalesce height writes so a layout pass cannot chase its own
        /// `.frame(height:)` update on the next tick.
        private var pendingHeight: CGFloat?

        init(_ parent: TabshComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView,
                  textView.bounds.width > 20,
                  let container = textView.textContainer,
                  let layout = textView.layoutManager
            else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            // Whole points only: a 32↔33 oscillation from fractional usedRect
            // used to pass the old 0.5ε guard on every layout and freeze input.
            let wanted = min(150, max(32, ceil(used)))
            guard wanted != parent.height, pendingHeight != wanted else { return }
            pendingHeight = wanted
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingHeight = nil
                guard self.parent.height != wanted else { return }
                self.parent.height = wanted
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if flags.contains(.shift) || flags.contains(.option) {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}

/// A scroll view that says when its width changed, so the field can work out
/// again how tall its wrapped text is. Height changes also call layout — those
/// must not remeasure, or the height binding and the frame chase each other.
private final class ComposerScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let width = bounds.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        onLayout?()
    }
}

private struct TabshThinkingRow: View {
    @Environment(\.colorScheme) private var scheme
    /// Which dot is brightest right now. The three take turns, so the bubble
    /// reads as an agent working rather than a frozen ellipsis.
    @State private var step = 0

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(Palette.muted.opacity(fade(for: dot)))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(
                        scheme == .dark
                            ? Color(red: 0.16, green: 0.16, blue: 0.17)
                            : Color(red: 0.90, green: 0.90, blue: 0.92)
                    )
            )
            Spacer(minLength: 56)
        }
        // A slow turn: a third of a second a dot, then round again. Reduced
        // motion keeps the first dot lit instead of pulsing at all.
        .task {
            guard !Motion.reduced else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.26)) {
                    step = (step + 1) % 3
                }
            }
        }
    }

    /// The lit dot, then a trail behind it: how far a dot is from the step
    /// says how bright it stays.
    private func fade(for dot: Int) -> Double {
        switch (dot - step + 3) % 3 {
        case 0: return 0.9
        case 1: return 0.55
        default: return 0.3
        }
    }
}


// MARK: - Pictures in a message

/// The extensions a message's pictures carry, in the shape a regular
/// expression wants them.
private let imageFileExtensions = #"(?:png|jpe?g|gif|webp|heic|tiff?|svg|bmp)"#

/// A markdown image anywhere in a line: `![what it is](/where it is.png)`.
private let markdownImage = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)

/// A bare path or address in the middle of a line, which cannot hold a
/// space: a whole line is read separately, spaces and all (see imageLine).
private let bareImagePath = try? NSRegularExpression(
    pattern: #"(?i)(?:file://)?(?:/|~/)[^\s)\]\"']+\."# + imageFileExtensions + #"\b"#
)

/// The message without the trailing image paths the composer appended.
/// The paths still go to the agent; the bubble was showing them as words
/// above the pictures they already stand for.
func textWithoutImagePaths(_ text: String) -> String {
    let kept = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { imageLine(String($0)) == nil }
    return kept.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Picture references a message carries: a markdown image, or a bare path
/// the tabsh app wrote when a screenshot was attached. Only files that are
/// there and web addresses; nothing else is opened.
func imageRefs(in text: String) -> [URL] {
    var found: [URL] = []
    var seen = Set<String>()

    func add(_ url: URL?) {
        guard let url, seen.insert(url.absoluteString).inserted else { return }
        found.append(url)
    }

    func add(_ raw: String) {
        add(imageURL(raw))
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let string = String(line)
        // The composer writes one path a line after what was asked, so a
        // line that is only a picture is taken whole: uploads live under
        // Application Support, and that folder's name has a space in it.
        if let picture = imageLine(string) {
            add(picture)
            continue
        }
        let ns = string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        markdownImage?.enumerateMatches(in: string, range: whole) { match, _, _ in
            if let range = match?.range(at: 1) { add(ns.substring(with: range)) }
        }
        bareImagePath?.enumerateMatches(in: string, range: whole) { match, _, _ in
            if let range = match?.range { add(ns.substring(with: range)) }
        }
    }
    return found
}

/// The picture a whole line names, or nil when the line is words. A path
/// may have spaces in it — the daemon saves uploads under Application
/// Support — so the line is read as one thing rather than split on spaces.
private func imageLine(_ line: String) -> URL? {
    let text = line.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    let ns = text as NSString
    let whole = NSRange(location: 0, length: ns.length)
    if text.hasPrefix("!["),
       let match = markdownImage?.firstMatch(in: text, range: whole),
       match.range == whole,
       let url = imageURL(ns.substring(with: match.range(at: 1))) {
        return url
    }
    return imageURL(text)
}

/// The URL a path or address names, when it names a picture: an extension
/// an image has, and a file that is really there for a local path. The
/// punctuation a path picks up (markdown's brackets, a shell's quotes) is
/// taken off first.
private func imageURL(_ raw: String) -> URL? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    text = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'"))
    text = text.removingPercentEncoding ?? text
    guard !text.isEmpty,
          text.range(of: #"(?i)\."# + imageFileExtensions + #"$"#,
                     options: .regularExpression) != nil
    else { return nil }

    if text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("file://") {
        return URL(string: text)
    }
    guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
    let path = (text as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return URL(fileURLWithPath: path)
}

@MainActor
private final class ChatImages {
    static let shared = ChatImages()
    private var cache: [String: NSImage] = [:]

    func image(at path: String) -> NSImage? {
        if let held = cache[path] { return held }
        guard let loaded = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = loaded
        return loaded
    }
}

private struct ChatImage: View {
    let url: URL

    var body: some View {
        if url.isFileURL {
            if let image = ChatImages.shared.image(at: url.path) {
                picture(Image(nsImage: image))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help(url.path)
            }
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    picture(image)
                } else if phase.error != nil {
                    EmptyView()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func picture(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 520, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
