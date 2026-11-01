import AppKit
import SwiftUI

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

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        self.type = type
        text = object["text"] as? String ?? ""
        requestID = object["request_id"] as? String ?? ""
        message = object["message"] as? String ?? ""
        stopReason = object["stop_reason"] as? String ?? ""
        tool = object["tool_call"] as? [String: Any]
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

/// A file waiting in the composer. It stays local until send, when it is
/// uploaded and its path travels after the message as tabsh does.
private struct TabshPendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }
    var isImage: Bool {
        tabshImageExtensions.contains(url.pathExtension.lowercased())
    }
}

private let tabshImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp",
    "tif", "tiff", "heic",
]

// MARK: - Transcript

/// One drawn row. Consecutive text deltas become one agent row; a tool's
/// updates keep one row as well, so a long command does not flood the chat.
struct TabshChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, agent, tool, toolGroup, plan, permission, error
    }

    let id: String
    var kind: Kind
    var text: String
    var detail = ""
    var requestID = ""
    var queued = false
    /// A run of consecutive tool calls, folded into one row (see Kind.toolGroup).
    var children: [TabshChatRow] = []
    /// "Delivered" under the newest outgoing bubble, as a message shows it.
    var receipt = ""
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
    private var stopped = false

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
        options?.cancel()
        stream = nil
        refresh = nil
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
                    self.models = answer
                }
                if let answer = try? await Tabsh.chatModes(self.sessionID),
                   !answer.options.isEmpty {
                    self.modes = answer
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
        guard let request = Tabsh.chatStreamRequest(sessionID) else {
            throw TabshError.noToken
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TabshError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw TabshError.refused(http.statusCode)
        }

        // Every connection starts with the finished transcript. The first
        // chunk replaces what the last connection left behind; the rest of
        // the replay (and whatever comes after) appends to it.
        var replacing = true
        for try await line in bytes.lines {
            guard !Task.isCancelled, !stopped else { return }
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let chunk = TabshChatChunk(line: raw) else { continue }
            if replacing {
                chunks.removeAll()
                replacing = false
            }
            accept(chunk)
        }
    }

    private func accept(_ chunk: TabshChatChunk) {
        chunks.append(chunk)
        // The daemon echoes the message it accepted. That echo is the real
        // bubble; the optimistic one goes when it arrives.
        if chunk.type == "user_text",
           let index = pending.firstIndex(where: { $0.text == chunk.text }) {
            pending.remove(at: index)
        }
        schedule()
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

    private func rebuild() {
        let answered = Set(chunks.compactMap {
            $0.type == "permission_answered" ? $0.requestID : nil
        })
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
                let id = chunk.toolID ?? "tool-\(index)"
                if let at = tools[id] {
                    if !chunk.toolSummary.isEmpty { rows[at].text = chunk.toolSummary }
                    if !chunk.toolDetail.isEmpty, !rows[at].detail.contains(chunk.toolDetail) {
                        rows[at].detail = rows[at].detail.isEmpty
                            ? chunk.toolDetail
                            : rows[at].detail + "\n\n" + chunk.toolDetail
                    }
                } else {
                    tools[id] = rows.count
                    rows.append(.init(id: "tool-\(index)",
                                      kind: .tool,
                                      text: chunk.toolSummary,
                                      detail: chunk.toolDetail))
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
        // bubble does in Messages. Older ones stay bare.
        if let last = rows.lastIndex(where: { $0.kind == .user }) {
            rows[last].receipt = rows[last].queued ? "Sending…" : "Delivered"
        }

        self.rows = TabshChat.grouped(rows)
        busy = open || !pending.isEmpty || !queue.isEmpty
        waiting = (open || !pending.isEmpty || !queue.isEmpty) && !sawAgent

        // The agent has finished and nothing is on the wire: the next line
        // waits for exactly this moment.
        if !busy, !posting, !queue.isEmpty {
            post(queue.removeFirst())
        }
    }
}

// MARK: - The tab

/// One agent chat in a tab: transcript, composer, and the card's own state.
struct TabshAgentPane: View {
    let sessionID: String
    @ObservedObject var browser: Browser
    @ObservedObject private var sessions: TabshSessions
    @StateObject private var chat: TabshChat

    @State private var draft = ""
    @State private var pinned = true
    @State private var showingExplorer = true
    @State private var composerHeight: CGFloat = 32
    @State private var focusToken = 0
    @State private var attachments: [TabshPendingAttachment] = []
    @State private var uploading = false
    /// Asks the transcript to go to the bottom from outside its scroll view:
    /// sending a message, or the jump button.
    @State private var scrollToken = 0

    init(sessionID: String, browser: Browser) {
        self.sessionID = sessionID
        _browser = ObservedObject(wrappedValue: browser)
        _sessions = ObservedObject(wrappedValue: .shared)
        _chat = StateObject(wrappedValue: TabshChats.shared.chat(for: sessionID))
    }

    private var sessionInfo: Tabsh.SessionInfo? {
        sessions.info(for: sessionID)
    }

    var body: some View {
        // The chat keeps the same project column a terminal tab has: the
        // session's folder, and the files the agent is working in, beside
        // the conversation rather than in another tab.
        TabshProjectPane(sessionID: sessionID,
                         browser: browser,
                         ground: Palette.ground,
                         showingExplorer: $showingExplorer) {
            VStack(spacing: 0) {
                header
                transcript
                composer
            }
        }
        .onAppear { focusToken += 1 }
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if chat.rows.isEmpty, !chat.busy {
                            empty
                        }
                        ForEach(Array(chat.rows.enumerated()), id: \.element.id) { index, row in
                            TabshChatRowView(row: row, chat: chat)
                                .padding(.top, gap(before: index))
                        }
                        if chat.waiting {
                            TabshThinkingRow()
                                .padding(.top, 12)
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
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                }
                .coordinateSpace(name: "chatScroll")
                .scrollIndicators(.never)
                .onPreferenceChange(ChatBottomKey.self) { bottom in
                    // The bottom marker is inside the visible scroll area
                    // while the reader is near the newest message.
                    pinned = bottom <= outer.size.height + 48
                }
                .onChange(of: chat.rows) { _, _ in follow(proxy) }
                .onChange(of: chat.waiting) { _, _ in follow(proxy) }
                .onChange(of: scrollToken) { _, _ in
                    pinned = true
                    withAnimation(Motion.quick) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
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
                    .padding(.trailing, 26)
                    .padding(.bottom, 12)
                    .help("Scroll to bottom")
                    .accessibilityLabel("Scroll to bottom")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(Motion.quick, value: pinned)
        }
    }

    /// The tab's own bar: the agent's name as plain text, and the selects
    /// its ACP session advertises. The selects stay hidden until the agent
    /// has answered; a mode is shown only when the agent has one.
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let info = sessionInfo {
                        TabshStatusMark(status: info.state, size: 11)
                    }
                    Text(chat.agentName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let info = sessionInfo, !info.meta.isEmpty {
                    Text(info.meta)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .help(sessionInfo?.tooltip ?? chat.agentName)

            Spacer(minLength: 10)

            if let models = chat.models, !models.options.isEmpty {
                TabshModelPicker(select: models,
                                 busy: chat.busy || chat.changingOption,
                                 choose: chat.selectModel)
            }
            if let modes = chat.modes, !modes.options.isEmpty {
                optionMenu(.mode, modes)
            }
            if !showingExplorer {
                ExplorerShowButton { showingExplorer = true }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }

    private enum OptionKind {
        case model, mode

        var title: String { self == .model ? "Model" : "Agent mode" }
        var symbol: String { self == .model ? "cpu" : "shield.lefthalf.filled" }
    }

    private func optionMenu(_ kind: OptionKind, _ select: Tabsh.ChatSelect) -> some View {
        let current = select.options.first { $0.id == select.current }?.name
            ?? select.current
            ?? kind.title

        return Menu {
            ForEach(select.options) { option in
                Button {
                    if kind == .model {
                        chat.selectModel(option.id)
                    } else {
                        chat.selectMode(option.id)
                    }
                } label: {
                    if option.id == select.current {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.symbol)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(kind.title)
        .disabled(chat.busy || chat.changingOption)
    }

    /// Messages by one sender sit close; a change of sender gets a breath,
    /// the way a thread separates one person's run from the other's.
    private func gap(before index: Int) -> CGFloat {
        guard index > 0, chat.rows.indices.contains(index) else { return 0 }
        let previous = chat.rows[index - 1]
        let row = chat.rows[index]
        if previous.kind == row.kind, (row.kind == .user || row.kind == .agent) {
            return 3
        }
        return 14
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard pinned else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
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
        .padding(.horizontal, 32)
    }

    private var composer: some View {
        VStack(spacing: 7) {
            if let notice = chat.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The composer is one card: the attachments, the plus, the
            // field and the send all live inside its squircle.
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty { attachmentBar }

                HStack(alignment: .bottom, spacing: 6) {
                    Button(action: chooseFiles) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Palette.ground))
                            .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(uploading)
                    .help("Attach images or files")
                    .accessibilityLabel("Attach images or files")

                    ZStack(alignment: .topLeading) {
                        TabshComposerField(text: $draft,
                                           height: $composerHeight,
                                           focus: focusToken,
                                           onSubmit: send)
                        if draft.isEmpty {
                            Text("Message")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                // Lines up with the field's own text inset,
                                // so the placeholder does not jump when the
                                // first character lands.
                                .padding(.leading, 13)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: composerHeight)

                    if chat.busy {
                        Button(action: chat.stopTurn) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 27, height: 27)
                                .background(Circle().fill(Palette.ground))
                        }
                        .buttonStyle(.plain)
                        .help("Stop the agent")
                        .accessibilityLabel("Stop the agent")
                    }

                    if uploading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Palette.ground))
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(canSend ? .white : Palette.faint)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill(canSend
                                        ? Color(nsColor: .controlAccentColor)
                                        : Palette.ground)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send")
                        .accessibilityLabel("Send")
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Superellipse().fill(Palette.hover))
            .overlay(Superellipse().stroke(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(CardEdge.shadow), radius: 2, y: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .background(Palette.ground)
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
            for url in panel.urls
            where !attachments.contains(where: { $0.url == url }) {
                attachments.append(TabshPendingAttachment(url: url))
            }
            focusToken += 1
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }
}

/// One file waiting in the composer: a picture of itself, or a small paper
/// chip, with the cross that takes it back out.
private struct TabshAttachmentChip: View {
    let attachment: TabshPendingAttachment
    let remove: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if attachment.isImage, let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Palette.hairline, lineWidth: 1)
                    )
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(attachment.name)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.ground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.hairline, lineWidth: 1)
                )
            }

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
            guard attachment.isImage else { return }
            image = NSImage(contentsOf: attachment.url)
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

private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Rows

private struct TabshChatRowView: View {
    let row: TabshChatRow
    @ObservedObject var chat: TabshChat

    @Environment(\.colorScheme) private var scheme
    @State private var unfolded = false
    @State private var answered = false

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
                    TabshMarkdownBubble(text: body, color: Palette.ink)
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
        scheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.17)
            : Color(red: 0.90, green: 0.90, blue: 0.92)
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
/// panel; Shift-Return and Option-Return write a line break.
private struct TabshComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focus: Int
    let onSubmit: () -> Void

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

        let text = NSTextView()
        text.delegate = context.coordinator
        text.isRichText = false
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = NSFont.systemFont(ofSize: 12.5)
        text.textColor = .labelColor
        text.insertionPointColor = .controlAccentColor
        text.textContainerInset = NSSize(width: 13, height: 8)
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
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        context.coordinator.updateHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TabshComposerField
        weak var textView: NSTextView?
        var lastFocus = 0

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
            let wanted = min(150, max(32, ceil(used)))
            guard abs(parent.height - wanted) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.height = wanted
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
/// again how tall its wrapped text is.
private final class ComposerScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private struct TabshThinkingRow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(Palette.muted.opacity(dot == 0 ? 0.9 : dot == 1 ? 0.6 : 0.32))
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
    }
}


// MARK: - Pictures in a message

/// Image references a message carries: a markdown image, or a bare path the
/// tabsh app wrote when a screenshot was attached. Only files and web
/// addresses; nothing else is opened.
@MainActor
/// The message without the trailing image paths the composer appended.
/// The paths still go to the agent; the bubble was showing them as words
/// above the pictures they already stand for.
private func textWithoutImagePaths(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(
        pattern: #"(?i)^\s*(?:file://)?(?:/|~/)[^\s)\]\"']+\.(?:png|jpe?g|gif|webp|heic|tiff?|svg|bmp)\s*$"#
    ) else { return text }

    let kept = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { line in
            let string = String(line)
            let range = NSRange(location: 0, length: (string as NSString).length)
            return regex.firstMatch(in: string, range: range) == nil
        }
    return kept.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func imageRefs(in text: String) -> [URL] {
    var found: [URL] = []
    var seen = Set<String>()

    func add(_ raw: String) {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"' "))
        text = text.removingPercentEncoding ?? text
        guard !text.isEmpty else { return }
        let url: URL?
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            url = URL(string: text)
        } else if text.hasPrefix("file://") {
            url = URL(string: text)
        } else if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return }
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        guard let url, seen.insert(url.absoluteString).inserted else { return }
        found.append(url)
    }

    if let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) {
        let ns = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let range = match?.range(at: 1) { add(ns.substring(with: range)) }
        }
    }
    if let regex = try? NSRegularExpression(pattern: #"(?i)(?:file://)?(?:/|~/)[^\s)\]\"']+\.(?:png|jpe?g|gif|webp|heic|tiff?)\b"#) {
        let ns = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let range = match?.range { add(ns.substring(with: range)) }
        }
    }
    return found
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
