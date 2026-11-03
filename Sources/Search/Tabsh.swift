import Foundation

// Talking to the tabsh daemon: the few calls the browser's own chrome makes.
// The token is this browser's own, kept beside its database under the app's
// Application Support folder; the daemon is the copy inside this bundle, run
// on its own port and state (see TabshDaemon.swift).

enum TabshError: LocalizedError {
    case noToken
    case notRunning
    case refused(Int)
    case failed(Int, String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .noToken: return "tabsh isn't paired yet"
        case .notRunning: return "tabsh isn't running"
        case let .refused(code): return "tabsh refused the request (\(code))"
        case let .failed(_, message): return message
        case .malformed: return "tabsh sent something unexpected"
        }
    }
}

enum Tabsh {
    nonisolated static var base: URL { TabshDaemon.base }

    /// One row of `/api/sessions`: enough to name a tab and open it, and to
    /// tell which agent a live chat card runs (`acpCommand`).
    struct Session: Decodable {
        let id: String
        var name: String?
        var status: String?
        var folder: String?
        var acpCommand: String?

        enum CodingKeys: String, CodingKey {
            case id, name, status
            case folder = "cwd"
            case acpCommand = "acp_command"
        }

        init(id: String, name: String? = nil, status: String? = nil, folder: String? = nil,
             acpCommand: String? = nil) {
            self.id = id
            self.name = name
            self.status = status
            self.folder = folder
            self.acpCommand = acpCommand
        }
    }

    /// A new shell, as a card in Backlog; the shell itself starts when its
    /// socket attaches, which is the tab's job.
    static func createTerminal(cwd: String? = nil, name: String? = nil) async throws -> Session {
        var body: [String: Any] = [:]
        body["cwd"] = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        if let name { body["name"] = name }
        let data = try await request("POST", "/api/sessions", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { throw TabshError.malformed }
        return Session(id: id,
                       name: object["name"] as? String,
                       status: object["status"] as? String,
                       folder: object["folder"] as? String)
    }

    /// What the board shows for one card: its title, the status its hooks
    /// move, the note they leave, its folder and agent, and when it moved.
    struct SessionInfo: Decodable, Identifiable, Equatable {
        let id: String
        var name: String
        var status: String
        var statusAt: Int
        var note: String?
        var cwd: String?
        var agent: String?
        var acp: String?
        var mode: String?
        var parent: String?
        var pinned: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, status, note, cwd, mode, parent, pinned
            case statusAt = "status_at"
            case agent = "agent_command"
            case acp = "acp_command"
        }
    }

    static func boardSessions() async throws -> [SessionInfo] {
        let data = try await request("GET", "/api/sessions")
        return try JSONDecoder().decode([SessionInfo].self, from: data)
    }

    /// The daemon's board socket: the status changes its hooks push, and the
    /// activity that names a terminal. Its token travels in the query, as the
    /// web app's does.
    static func boardEventsRequest() -> URLRequest? {
        guard let token = TabshDaemon.token(),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.scheme = "ws"
        parts.path = "/api/board/events"
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.timeoutInterval = 60 * 60
        return request
    }

    /// The ACP agent a UI card should run. The provider list lives with the
    /// daemon, not in this build: the web app's Settings › Agents and the
    /// native agent tab therefore start the same agent.
    struct AgentProvider {
        let name: String
        let acp: String
    }

    static func agentProvider() async -> AgentProvider {
        if let data = try? await request("GET", "/api/settings"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let preferred = object["agentProvider"] as? String
            var choices: [AgentProvider] = []
            for entry in object["providers"] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String,
                      let acp = (entry["acp"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !acp.isEmpty else { continue }
                choices.append(AgentProvider(name: name, acp: acp))
            }
            if let wanted = choices.first(where: { $0.name == preferred }) { return wanted }
            if let first = choices.first { return first }
        }
        // A daemon with no saved providers yet — a fresh install — gets the
        // same stock agent the web app would have chosen.
        return AgentProvider(name: "Claude Code",
                             acp: "npx --yes @agentclientprotocol/claude-agent-acp")
    }

    /// New Agent: a UI card on the daemon, moved to In progress so its ACP
    /// agent starts, then shown by the tab as a native chat. The card keeps
    /// running when the tab closes, as a terminal does.
    static func createAgent(cwd: String? = nil, name: String? = nil) async throws -> Session {
        let provider = await agentProvider()
        let body: [String: Any] = [
            "cwd": cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "mode": "ui",
            "acp_command": provider.acp,
            "name": name ?? provider.name,
        ]
        let data = try await request("POST", "/api/sessions", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { throw TabshError.malformed }
        // A card is born in Backlog. In progress is what launches its agent
        // on the daemon (see board::apply_status), and the tab attaches to it.
        try await setStatus(id, "in_progress")
        return Session(id: id,
                       name: object["name"] as? String,
                       status: "in_progress",
                       folder: object["folder"] as? String)
    }

    static func setStatus(_ session: String, _ status: String) async throws {
        _ = try await request("PATCH", "/api/sessions/\(session)/status",
                              body: ["status": status, "source": "user"])
    }

    /// The model or mode select an ACP agent advertises. Empty until the
    /// agent is live; the chat panel polls for it once the handshake is done.
    struct ChatSelect: Codable {
        struct Choice: Codable, Identifiable {
            let id: String
            let name: String
            let description: String?
        }

        var current: String?
        var options: [Choice]

        init(current: String? = nil, options: [Choice] = []) {
            self.current = current
            self.options = options
        }
    }

    // The chat routes a UI card answers on. Their chunks are rendered by
    // TabshAgent.swift; history and live turns are the same SSE stream.
    static func startChat(_ session: String) async throws {
        _ = try await request("POST", "/api/sessions/\(session)/chat/start")
    }

    /// A file picked in the composer, saved beside the daemon's database so
    /// its path can travel in the message the agent reads.
    static func upload(file: URL) async throws -> String {
        guard let token = TabshDaemon.token() else { throw TabshError.noToken }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/api/uploads"
        parts?.queryItems = [URLQueryItem(name: "name", value: file.lastPathComponent)]
        guard let url = parts?.url else { throw TabshError.malformed }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw TabshError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let message = object?["message"] as? String, !message.isEmpty {
                throw TabshError.failed(http.statusCode, message)
            }
            throw TabshError.refused(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String, !path.isEmpty else {
            throw TabshError.malformed
        }
        return path
    }

    static func chatModels(_ session: String) async throws -> ChatSelect {
        let data = try await request("GET", "/api/sessions/\(session)/chat/models")
        return try JSONDecoder().decode(ChatSelect.self, from: data)
    }

    static func chatModes(_ session: String) async throws -> ChatSelect {
        let data = try await request("GET", "/api/sessions/\(session)/chat/modes")
        return try JSONDecoder().decode(ChatSelect.self, from: data)
    }

    static func setChatModel(_ session: String, id: String) async throws -> ChatSelect {
        let data = try await request("POST", "/api/sessions/\(session)/chat/model",
                                     body: ["id": id])
        return try JSONDecoder().decode(ChatSelect.self, from: data)
    }

    static func setChatMode(_ session: String, id: String) async throws -> ChatSelect {
        let data = try await request("POST", "/api/sessions/\(session)/chat/mode",
                                     body: ["id": id])
        return try JSONDecoder().decode(ChatSelect.self, from: data)
    }

    static func sendChatMessage(_ session: String, text: String) async throws {
        _ = try await request("POST", "/api/sessions/\(session)/chat/message",
                              body: ["text": text])
    }

    static func stopChat(_ session: String) async throws {
        _ = try await request("POST", "/api/sessions/\(session)/chat/stop")
    }

    static func approveChat(_ session: String, requestID: String, allow: Bool) async throws {
        _ = try await request("POST", "/api/sessions/\(session)/chat/approve",
                              body: ["requestId": requestID, "allow": allow])
    }

    /// Answers the question an ACP agent is blocked on: `accept` carries the
    /// form's values, `decline` and `cancel` carry none.
    static func answerChat(_ session: String,
                           requestID: String,
                           action: String,
                           content: [String: Any]? = nil) async throws {
        var body: [String: Any] = ["requestId": requestID, "action": action]
        if let content { body["content"] = content }
        _ = try await request("POST", "/api/sessions/\(session)/chat/answer", body: body)
    }

    /// The SSE request a chat panel reads: same bearer token as every other
    /// call, and no timeout while the agent is quiet between turns.
    static func chatStreamRequest(_ session: String) -> URLRequest? {
        guard let token = TabshDaemon.token(),
              let url = URL(string: "/api/sessions/\(session)/chat/stream", relativeTo: base)
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 * 60
        return request
    }

    /// A provider the agent composer can start: what the daemon needs to
    /// launch it in a terminal, or to speak ACP for a chat card.
    struct Provider: Decodable, Identifiable, Hashable {
        let name: String
        let command: String
        var resume: String?
        var acp: String?
        var id: String { name }

        /// OpenCode only resumes when the launch command named the
        /// conversation (`ses_{session}`). Older stock entries omitted that,
        /// so cards never got `resume_input` and a restart sat at a shell.
        func withOpenCodeSessionMint() -> Provider {
            let isOpenCode = name.localizedCaseInsensitiveContains("opencode")
                || command.split(separator: " ").first.map(String.init) == "opencode"
            guard isOpenCode else { return self }
            if command == "opencode --prompt {prompt}" {
                return Provider(name: name,
                                command: "opencode --session ses_{session} --prompt {prompt}",
                                resume: "opencode --session ses_{session}",
                                acp: acp ?? "opencode acp")
            }
            if resume == "opencode --session {session}" {
                return Provider(name: name, command: command,
                                resume: "opencode --session ses_{session}",
                                acp: acp)
            }
            return self
        }
    }

    struct Settings: Decodable {
        var providers: [Provider]
        var agentProvider: String?
        var agentMode: String?
    }

    /// The agents tabsh starts with, for a daemon that hasn't answered its
    /// settings yet: the same list its own New card offers on a fresh install.
    static let stockProviders: [Provider] = [
        Provider(name: "Claude Code", command: "claude {prompt}",
                 resume: "claude --resume {session}",
                 acp: "npx --yes @agentclientprotocol/claude-agent-acp"),
        Provider(name: "Codex", command: "codex {prompt}",
                 resume: "codex resume {session}",
                 acp: "npx --yes @agentclientprotocol/codex-acp"),
        Provider(name: "Cursor CLI", command: "cursor-agent {prompt}",
                 resume: "cursor-agent --resume={session}",
                 acp: "cursor-agent acp"),
        // `{session}` in the launch command: tabsh names the conversation
        // (`ses_<uuid>`), so a restart can resume without OpenCode's hooks.
        Provider(name: "OpenCode",
                 command: "opencode --session ses_{session} --prompt {prompt}",
                 resume: "opencode --session ses_{session}",
                 acp: "opencode acp"),
        Provider(name: "muse", command: "muse {prompt}",
                 resume: "muse resume {session}",
                 acp: "muse -- --acp"),
        // `grok agent stdio` is Grok's ACP seat; `-r` takes the session id
        // tabsh minted, as the other resumes take theirs.
        Provider(name: "Grok", command: "grok {prompt}",
                 resume: "grok --resume {session}",
                 acp: "grok agent stdio"),
    ]

    static func settings() async throws -> Settings {
        let data = try await request("GET", "/api/settings")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TabshError.malformed
        }
        // Read the fields by hand: a daemon newer or older than this build may
        // add or drop a key, and the composer only needs the providers.
        let providers = (object["providers"] as? [[String: Any]])?.compactMap { item -> Provider? in
            guard let name = item["name"] as? String,
                  let command = item["command"] as? String else { return nil }
            return Provider(name: name, command: command,
                            resume: item["resume"] as? String,
                            acp: item["acp"] as? String)
                .withOpenCodeSessionMint()
        } ?? []
        return Settings(providers: providers,
                        agentProvider: object["agentProvider"] as? String,
                        agentMode: object["agentMode"] as? String)
    }

    /// The whole settings object, for a screen that edits one part of it
    /// (`AgentProviders.swift`). The daemon stores one JSON object and a PUT
    /// replaces it, so the rest of the object has to come back with the part
    /// that changed.
    static func settingsObject() async throws -> [String: Any] {
        let data = try await request("GET", "/api/settings")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TabshError.malformed
        }
        return object
    }

    /// Put the whole object back. The daemon answers 204, so there is
    /// nothing to return.
    static func saveSettingsObject(_ object: [String: Any]) async throws {
        _ = try await request("PUT", "/api/settings", body: object)
    }

    /// A card with an agent: the same body tabsh's New card sends, then the
    /// column it belongs in — In progress starts the agent.
    static func createAgent(cwd: String, prompt: String, provider: Provider,
                            mode: String, status: String) async throws -> Session {
        var body: [String: Any] = [
            "cwd": cwd,
            "prompt": prompt,
            "command": provider.command,
            "resume": provider.resume ?? "",
            "mode": mode,
        ]
        if mode == "ui", let acp = provider.acp, !acp.isEmpty {
            body["acp_command"] = acp
        }
        let data = try await request("POST", "/api/sessions", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { throw TabshError.malformed }
        let session = Session(id: id,
                              name: object["name"] as? String,
                              status: object["status"] as? String,
                              folder: object["cwd"] as? String)
        if status != "backlog" {
            _ = try? await request("PATCH", "/api/sessions/\(id)/status", body: ["status": status])
        }
        return session
    }

    /// A chat card that starts now, with the model and agent mode chosen on
    /// the New Agent card applied *before* the first prompt. The board only
    /// launches a card it was moved to In progress by the user — and it
    /// launches it with the agent's default model. So the card is moved as a
    /// hook would move it (no launch), the chat is brought up here, and its
    /// advertised selects are set. The New Agent page sends the prompt
    /// itself once the chat pane is open (`TabshChat.send`), so the words
    /// show as a pending bubble and ride the same path as a typed message.
    static func createChat(cwd: String, name: String, provider: Provider,
                           model: String?, mode: String?) async throws -> Session {
        // No `name` on create: a named card is pinned, and ACP's
        // `session_info_update` cannot replace a pinned title. The New Agent
        // words are applied as an auto rename below so the header has
        // something until the agent sends a better title.
        var body: [String: Any] = [
            "cwd": cwd,
            "mode": "ui",
            "command": provider.command,
            "resume": provider.resume ?? "",
        ]
        if let acp = provider.acp, !acp.isEmpty {
            body["acp_command"] = acp
        }
        let data = try await request("POST", "/api/sessions", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { throw TabshError.malformed }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? await renameSession(id, name: trimmed, auto: true)
        }
        _ = try await request("PATCH", "/api/sessions/\(id)/status",
                              body: ["status": "in_progress", "source": "hook"])
        try? await startChat(id)

        if let model {
            // The agent advertises its models once `session/new` answers;
            // until then there is nothing to set.
            for _ in 0..<40 {
                if let select = try? await chatModels(id),
                   select.options.contains(where: { $0.id == model }) {
                    _ = try? await setChatModel(id, id: model)
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        if let mode {
            for _ in 0..<10 {
                if let select = try? await chatModes(id),
                   select.options.contains(where: { $0.id == mode }) {
                    _ = try? await setChatMode(id, id: mode)
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        return Session(id: id,
                       name: object["name"] as? String ?? name,
                       status: "in_progress",
                       folder: cwd)
    }

    /// A throwaway card for asking an agent what it can run. It is born in
    /// Backlog and moved to In progress by a hook — which does not launch it
    /// — so `chat/start` may bring its ACP agent up here and its model list
    /// can be read before the card is deleted.
    static func probeSession(cwd: String, provider: Provider) async throws -> String {
        var body: [String: Any] = [
            "cwd": cwd,
            "name": "Checking models",
            "mode": "ui",
            "command": provider.command,
            "resume": provider.resume ?? "",
        ]
        if let acp = provider.acp, !acp.isEmpty {
            body["acp_command"] = acp
        }
        let data = try await request("POST", "/api/sessions", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { throw TabshError.malformed }
        _ = try await request("PATCH", "/api/sessions/\(id)/status",
                              body: ["status": "in_progress", "source": "hook"])
        return id
    }

    /// Kill the shell (or chat agent) and remove the card, as the web board's
    /// Delete session does. A 204 with an empty body is success.
    static func deleteSession(_ id: String) async throws {
        _ = try await request("DELETE", "/api/sessions/\(id)")
    }

    /// Renames a card. `auto` is a shell or ACP title: it does not pin, so a
    /// later agent title can still replace it. A user rename omits `auto`
    /// (or passes false) and pins.
    static func renameSession(_ id: String, name: String, auto: Bool = false) async throws {
        var body: [String: Any] = ["name": name]
        if auto { body["auto"] = true }
        _ = try await request("PATCH", "/api/sessions/\(id)", body: body)
    }

    /// The tree the explorer shows: the tab's project root (its git root,
    /// else its folder) and every path under it, directories ending in `/`.
    /// When `truncated`, `foldersOnly` means a reduced listing — folders plus
    /// first-level files — rather than the whole tree.
    struct Tree: Decodable {
        let root: String
        let paths: [String]
        let truncated: Bool
        let foldersOnly: Bool
    }

    static func tree(session: String) async throws -> Tree {
        try await tree(session: session, path: nil)
    }

    /// The explorer's listing. `path` roots at an absolute folder instead of
    /// the session's project — used when opening a folder under a truncated
    /// home/`/` listing without changing the shell's cwd.
    static func tree(session: String? = nil, path: String?) async throws -> Tree {
        var pairs: [String] = []
        if let session, !session.isEmpty {
            let encoded = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session
            pairs.append("session=\(encoded)")
        }
        if let path, !path.isEmpty {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            pairs.append("path=\(encoded)")
        }
        let query = pairs.isEmpty ? "/api/files/tree" : "/api/files/tree?" + pairs.joined(separator: "&")
        // A home folder can take a moment to reduce to folders-only; five
        // seconds left the sidebar empty with a timeout.
        let data = try await request("GET", query, timeout: 30)
        return try JSONDecoder().decode(Tree.self, from: data)
    }

    /// The folders that complete a typed path, for New Agent's folder search,
    /// and the home folder so the picker can show and expand `~`.
    struct Folders: Decodable {
        let home: String
        let folders: [String]
    }

    static func folders(path: String) async throws -> Folders {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let data = try await request("GET", "/api/files/folders?path=\(encoded)")
        return try JSONDecoder().decode(Folders.self, from: data)
    }

    /// The explorer's live socket: the daemon watches the session's project
    /// and says which paths appeared or went, asks for the listing again
    /// (`reset`), and — every second — reports when the session's own folder
    /// moved to another project (`root`). That last message is what lets the
    /// sidebar follow the folder the agent or shell is in.
    nonisolated static func filesWatchRequest(for session: String) -> URLRequest? {
        guard let token = TabshDaemon.token(),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.scheme = "ws"
        parts.path = "/api/files/watch"
        parts.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.timeoutInterval = 60 * 60
        return request
    }

    static func sessions() async throws -> [Session] {
        let data = try await request("GET", "/api/sessions")
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TabshError.malformed
        }
        return list.compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            return Session(id: id,
                           name: object["name"] as? String,
                           status: object["status"] as? String,
                           folder: object["cwd"] as? String,
                           acpCommand: object["acp_command"] as? String)
        }
    }

    /// The socket a terminal attaches through, with the token the browser's
    /// pages would use. Its Origin is the daemon's own page origin, which is
    /// what the daemon accepts from a local client. `resume` names the epoch
    /// and byte count the screen already holds: the daemon then sends only
    /// what came after, rather than the whole scrollback again.
    nonisolated static func socketURL(
        for session: String,
        resume: (epoch: String, at: Int)? = nil
    ) -> URL? {
        guard let token = TabshDaemon.token() else { return nil }
        return socketURL(session: session, token: token, resume: resume)
    }

    /// [`socketURL(for:resume:)`] with the token passed in, so the URL can be
    /// checked without the daemon's token file.
    nonisolated static func socketURL(
        session: String,
        token: String,
        resume: (epoch: String, at: Int)? = nil
    ) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.scheme = "ws"
        parts?.path = "/ws"
        var items = [
            URLQueryItem(name: "id", value: session),
            URLQueryItem(name: "token", value: token),
        ]
        if let resume {
            items.append(URLQueryItem(name: "resume", value: "\(resume.epoch):\(resume.at)"))
        }
        parts?.queryItems = items
        return parts?.url
    }

    nonisolated static var origin: String { "http://127.0.0.1:\(TabshDaemon.port)" }

    private static func request(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        timeout: TimeInterval = 5
    ) async throws -> Data {
        guard let token = TabshDaemon.token() else { throw TabshError.noToken }
        guard let url = URL(string: path, relativeTo: base) else { throw TabshError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TabshError.malformed }
            guard (200..<300).contains(http.statusCode) else {
                // The daemon's own sentence is what a chat failure should
                // say ("Install the agent…", "Move this card to In progress…").
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let message = object?["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw TabshError.failed(http.statusCode, message)
                }
                throw TabshError.refused(http.statusCode)
            }
            return data
        } catch let error as URLError {
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                throw TabshError.notRunning
            }
            throw error
        }
    }
}
