import AppKit
import Darwin
import Foundation

// The browser side of `tabsctl` (daemon/src/bin/tabsctl.rs): a narrow Unix socket
// an agent in a session uses to create a sibling session and have its tab
// opened here, without stealing focus.
//
// Separate from the bench on purpose: the bench needs Settings consent
// because it can eval and click in pages. This socket can only create, list
// and open tabsh sessions — no more than the daemon API already allows any
// same-user process holding the token — so it is on without a switch, with
// the bench's own discipline: a socket only this user can reach (0600),
// the peer's uid checked again before a word is read, one JSON object per
// line in, one per line out, one request per connection.

/// The verbs `tabsctl` may ask for. The Rust CLI duplicates these strings;
/// TabsctlContractTests pins the two copies together.
enum TabsctlProtocol {
    static let createTerminal = "session.create.terminal"
    static let createAgent = "session.create.agent"
    static let open = "session.open"
    static let list = "session.list"
    static let verbs = [createTerminal, createAgent, open, list]

    static func failure(_ code: String, _ message: String, hint: String = "") -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if !hint.isEmpty { error["hint"] = hint }
        return ["error": error]
    }
}

/// One parsed request. Parsing lives here, not in the socket loop, so the
/// contract can be tested without a listening socket.
struct TabsctlRequest: Equatable {
    var verb: String
    var cwd: String?
    var name: String?
    var prompt: String?
    var provider: String?
    var model: String?
    var mode: String?
    var session: String?
    var parent: String?
    var focus = false

    static func parse(_ object: [String: Any]) -> TabsctlRequest? {
        guard let verb = object["do"] as? String, TabsctlProtocol.verbs.contains(verb) else { return nil }
        var request = TabsctlRequest(verb: verb)
        request.cwd = object["cwd"] as? String
        request.name = object["name"] as? String
        request.prompt = object["prompt"] as? String
        request.provider = object["provider"] as? String
        request.model = object["model"] as? String
        request.mode = object["mode"] as? String
        request.session = object["session"] as? String
        request.parent = object["parent"] as? String
        request.focus = object["focus"] as? Bool ?? false
        if verb == TabsctlProtocol.open, request.session?.isEmpty != false { return nil }
        if let mode = request.mode, mode != "tui", mode != "ui" { return nil }
        return request
    }
}

@MainActor
final class TabshAgentSocket {
    static let shared = TabshAgentSocket()

    private weak var browser: Browser?
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private(set) var running = false

    /// Beside the session file, like the bench's socket, so a test run's
    /// agent socket is as separate as everything else in its world.
    static var socket: URL { Store.file("agent.sock") }

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        let path = Self.socket.path
        try? FileManager.default.createDirectory(
            at: Self.socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(Self.socket.path)
        clients.values.forEach { $0.drop() }
        clients = [:]
        running = false
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        let client = Client(fd: fd) { [weak self] request, answer in
            self?.handle(request, answer)
        } gone: { [weak self] fd in
            self?.clients[fd] = nil
        }
        clients[fd] = client
    }

    /// Reads until a newline, hands the line up, writes the answer, closes.
    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let handle: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
        private let gone: (Int32) -> Void
        private var answered = false

        init(fd: Int32,
             handle: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
             gone: @escaping (Int32) -> Void) {
            self.fd = fd
            self.handle = handle
            self.gone = gone
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            if bytes.count > 1_000_000 {
                say(TabsctlProtocol.failure("request_too_long", "the request was too long"))
                return
            }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data()
            source.cancel()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(TabsctlProtocol.failure("bad_request", "not a JSON object"))
                return
            }
            handle(json) { [weak self] answer in self?.say(answer) }
        }

        private func say(_ answer: [String: Any]) {
            guard !answered else { return }
            answered = true
            var out = (try? JSONSerialization.data(withJSONObject: answer))
                ?? Data("{\"error\":{\"code\":\"unwritable\",\"message\":\"unwritable answer\"}}".utf8)
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 {
                        if errno == EAGAIN { usleep(2000); continue }
                        break
                    }
                    sent += n
                }
            }
            drop()
        }

        func drop() {
            if !source.isCancelled { source.cancel() }
            close(fd)
            gone(fd)
        }
    }

    // MARK: - the verbs

    /// The window a new tab belongs in: the caller's own, when the calling
    /// session has a tab somewhere; the front window otherwise.
    private func targetBrowser(parent: String?) -> Browser? {
        if let parent, !parent.isEmpty {
            for candidate in Browsers.all
            where (candidate.tabs + candidate.parkedTabs).contains(where: { $0.tabshSessionID == parent }) {
                return candidate
            }
        }
        return browser.flatMap { own in Browsers.all.contains { $0 === own } ? own : nil }
            ?? Browsers.front ?? Browsers.primary
    }

    private func handle(_ object: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard let request = TabsctlRequest.parse(object) else {
            answer(TabsctlProtocol.failure("bad_request", "unknown or malformed request",
                                           hint: "tabsctl --help lists the commands"))
            return
        }
        guard let browser = targetBrowser(parent: request.parent) else {
            answer(TabsctlProtocol.failure("no_browser", "Tabs has no window open"))
            return
        }
        Task { @MainActor in
            do {
                switch request.verb {
                case TabsctlProtocol.list:
                    let sessions = try await Tabsh.boardSessions()
                    answer(["sessions": sessions.map { info in
                        ["id": info.id, "name": info.name, "status": info.status,
                         "cwd": info.cwd as Any, "mode": info.mode as Any]
                    }])
                case TabsctlProtocol.createTerminal:
                    let session = try await Tabsh.createTerminal(cwd: request.cwd, name: request.name)
                    let tab = browser.show(InternalPage(.tabsh, session.id), focus: request.focus)
                    answer(["session": session.id, "tab": tab.id.uuidString, "focused": request.focus])
                case TabsctlProtocol.createAgent:
                    let session = try await Self.createAgent(request)
                    let kind: InternalPage.Kind = (request.mode ?? "ui") == "ui" ? .agent : .tabsh
                    let tab = browser.show(InternalPage(kind, session.id), focus: request.focus)
                    // As the composer does: the prompt goes in as the first
                    // chat message once the pane exists.
                    if kind == .agent, let prompt = request.prompt, !prompt.isEmpty {
                        TabshChats.shared.chat(for: session.id).send(prompt)
                    }
                    answer(["session": session.id, "tab": tab.id.uuidString, "focused": request.focus])
                case TabsctlProtocol.open:
                    guard let id = request.session else {
                        answer(TabsctlProtocol.failure("bad_request", "open needs a session id"))
                        return
                    }
                    let sessions = try await Tabsh.boardSessions()
                    guard let info = sessions.first(where: { $0.id == id }) else {
                        answer(TabsctlProtocol.failure("session_not_found", "no session \(id)",
                                                       hint: "tabsctl sessions lists them"))
                        return
                    }
                    let kind: InternalPage.Kind = info.mode == "ui" ? .agent : .tabsh
                    let tab = browser.show(InternalPage(kind, id), focus: request.focus)
                    answer(["session": id, "tab": tab.id.uuidString, "focused": request.focus])
                default:
                    answer(TabsctlProtocol.failure("bad_request", "unknown request"))
                }
            } catch {
                answer(TabsctlProtocol.failure("failed", error.localizedDescription))
            }
        }
    }

    /// An agent card for the CLI, through the same paths the composer uses:
    /// a chat card with its first prompt for `ui`, a terminal agent for
    /// `tui`. The provider is the daemon settings' choice unless named.
    private static func createAgent(_ request: TabsctlRequest) async throws -> Tabsh.Session {
        let settings = try? await Tabsh.settings()
        let providers = settings?.providers ?? []
        let provider = providers.first { $0.name == request.provider }
            ?? settings?.agentProvider.flatMap { name in providers.first { $0.name == name } }
            ?? providers.first
            ?? Tabsh.stockProviders[0]
        let cwd = request.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let mode = request.mode ?? settings?.agentMode ?? "ui"
        if mode == "ui" {
            return try await Tabsh.createChat(cwd: cwd, name: request.name ?? "",
                                              provider: provider, model: request.model, mode: nil)
        }
        return try await Tabsh.createAgent(cwd: cwd, prompt: request.prompt ?? "",
                                           provider: provider, mode: mode, status: "in_progress")
    }
}
