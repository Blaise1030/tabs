import Darwin
import Foundation

// tabsctl: create and open tabsh sessions in the Tabs browser, from a shell
// or an agent running inside one of its terminals.
//
// This is a separate binary from the bundled `tabsh` daemon on purpose: the
// daemon and its CLI live in the tabsh repository, while this client, the
// browser socket it speaks (`agent.sock`, see TabshAgentSocket.swift) and the
// tabs it opens all live here, versioned and shipped with the browser.
//
// One JSON object per line to the browser's Unix socket, one back. With
// --card-only it skips the browser and creates the card on the daemon
// directly (no tab is opened).

let usage = """
usage:
  tabsctl new --terminal [--cwd DIR] [--name NAME] [--focus] [--json]
  tabsctl new --agent [--cwd DIR] [--prompt TEXT] [--provider NAME]
                      [--model ID] [--mode tui|ui] [--name NAME]
                      [--focus] [--json]
  tabsctl sessions [--json]
  tabsctl open SESSION_ID [--focus] [--json]
  tabsctl --help

Inside a Tabs session the browser is found with no setup: its socket sits in
the browser's own folder, and `TABSH_SESSION_ID` names the calling session so
the new tab lands beside it. Options:
  --card-only   create the card on the tabsh daemon only; open no tab
  --socket PATH speak to a different browser socket (tests)
Environment: TABSCTL_SOCKET overrides the socket path.
"""

struct Failure: Error {
    let message: String
    let code: Int
}

struct Options {
    var json = false
    var focus = false
    var cardOnly = false
    var socket: String?
    var cwd: String?
    var name: String?
    var prompt: String?
    var provider: String?
    var model: String?
    var mode: String?
    var kind: String? // "terminal" | "agent"
    var rest: [String] = []
}

/// Splits flags from positional words. `--prompt` and friends take the next
/// argument; anything else starting with `--` is an error, so a typo never
/// becomes a session name by accident.
func parse(_ args: [String]) throws -> Options {
    var out = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw Failure(message: "\(flag) needs a value", code: 2) }
        return args[i]
    }
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--json": out.json = true
        case "--focus": out.focus = true
        case "--card-only": out.cardOnly = true
        case "--terminal": out.kind = "terminal"
        case "--agent": out.kind = "agent"
        case "--cwd": out.cwd = try value(arg)
        case "--name": out.name = try value(arg)
        case "--prompt": out.prompt = try value(arg)
        case "--provider": out.provider = try value(arg)
        case "--model": out.model = try value(arg)
        case "--mode": out.mode = try value(arg)
        case "--socket": out.socket = try value(arg)
        default:
            if arg.hasPrefix("--") { throw Failure(message: "unknown option \(arg)", code: 2) }
            out.rest.append(arg)
        }
        i += 1
    }
    return out
}

func socketPath(_ options: Options) -> String {
    if let socket = options.socket { return socket }
    if let env = ProcessInfo.processInfo.environment["TABSCTL_SOCKET"], !env.isEmpty { return env }
    // A shell started by Tabs inherits TABSH_DB; the browser socket sits
    // beside that folder, so a SEARCH_DEV or probe shell reaches its own
    // window rather than the installed app's.
    if let db = ProcessInfo.processInfo.environment["TABSH_DB"], !db.isEmpty {
        let folder = URL(fileURLWithPath: db)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return folder.appendingPathComponent("agent.sock").path
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("tabsh-browser/agent.sock").path
}

/// One request to the browser, one answer back. Fails closed with a named
/// error when Tabs is not running rather than leaving an orphan card behind.
func askBrowser(_ request: [String: Any], options: Options) throws -> [String: Any] {
    let path = socketPath(options)
    guard FileManager.default.fileExists(atPath: path) else {
        throw Failure(message: "Tabs isn't running (no socket at \(path)); open Tabs first, or use --card-only", code: 1)
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(message: "could not open a socket", code: 1) }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let room = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < room else { throw Failure(message: "socket path too long", code: 1) }
    withUnsafeMutablePointer(to: &address.sun_path) { sun in
        sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
            _ = strlcpy(bytes, path, room)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard connected == 0 else {
        throw Failure(message: "Tabs isn't running (could not connect to \(path)); open Tabs first, or use --card-only", code: 1)
    }
    var line = try JSONSerialization.data(withJSONObject: request)
    line.append(0x0A)
    try line.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
            if n <= 0 { throw Failure(message: "could not send the request to Tabs", code: 1) }
            sent += n
        }
    }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !data.contains(0x0A) {
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { break }
        data.append(contentsOf: chunk[0..<n])
        if data.count > 4_000_000 { throw Failure(message: "Tabs sent too much back", code: 1) }
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Failure(message: "Tabs sent something unexpected", code: 1)
    }
    if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
        throw Failure(message: message, code: 1)
    }
    if let error = object["error"] as? String {
        throw Failure(message: error, code: 1)
    }
    return object
}

// MARK: - --card-only: the daemon directly

func daemonBase() -> String {
    let env = ProcessInfo.processInfo.environment
    if let url = env["TABSH_URL"], !url.isEmpty { return url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    // Prefer the URL the daemon stamped into the shell. Falling back: a
    // SEARCH_DEV Tabs uses 7683 under tabsh-browser-dev; the installed app
    // uses 7682 under tabsh-browser; standalone tabsh keeps 7681.
    if let db = env["TABSH_DB"] {
        if db.contains("tabsh-browser-dev") { return "http://127.0.0.1:7683" }
        if db.contains("tabsh-browser") { return "http://127.0.0.1:7682" }
    }
    return "http://127.0.0.1:7681"
}

func daemonToken() -> String? {
    let env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    var candidates: [URL] = []
    if let db = env["TABSH_DB"], !db.isEmpty {
        candidates.append(URL(fileURLWithPath: db).deletingLastPathComponent().appendingPathComponent("token"))
    }
    candidates.append(home.appendingPathComponent("Library/Application Support/tabsh-browser-dev/tabsh/token"))
    candidates.append(home.appendingPathComponent("Library/Application Support/tabsh-browser/tabsh/token"))
    candidates.append(home.appendingPathComponent(".tabsh/token"))
    for url in candidates {
        if let token = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

func daemonRequest(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
    guard let token = daemonToken() else {
        throw Failure(message: "no tabsh token found; is the daemon paired?", code: 1)
    }
    guard let url = URL(string: daemonBase() + path) else {
        throw Failure(message: "bad daemon address \(daemonBase())", code: 1)
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let done = DispatchSemaphore(value: 0)
    var result: Result<[String: Any], Failure> = .failure(Failure(message: "no answer from the daemon", code: 1))
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { done.signal() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = .failure(Failure(message: "the tabsh daemon refused the request (\(code))", code: 1))
            return
        }
        if let data, !data.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = .success(object)
        } else {
            result = .success([:])
        }
    }.resume()
    _ = done.wait(timeout: .now() + 35)
    return try result.get()
}

func createCardOnly(kind: String, options: Options) throws -> [String: Any] {
    let cwd = options.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    if kind == "terminal" {
        var body: [String: Any] = ["cwd": cwd]
        if let name = options.name { body["name"] = name }
        let made = try daemonRequest("POST", "/api/sessions", body: body)
        guard let id = made["id"] as? String else { throw Failure(message: "the daemon sent no session id", code: 1) }
        return ["session": id, "cardOnly": true]
    }
    // Agent: pick the provider the daemon's settings name, as the browser
    // does, falling back to its first provider and then the stock agent.
    let settings = (try? daemonRequest("GET", "/api/settings")) ?? [:]
    let providers = settings["providers"] as? [[String: Any]] ?? []
    let wanted = options.provider ?? (settings["agentProvider"] as? String)
    let provider = providers.first { $0["name"] as? String == wanted } ?? providers.first
    let command = provider?["command"] as? String ?? "claude {prompt}"
    let mode = options.mode ?? "ui"
    var body: [String: Any] = [
        "cwd": cwd,
        "prompt": options.prompt ?? "",
        "command": command,
        "resume": provider?["resume"] as? String ?? "",
        "mode": mode,
    ]
    if mode == "ui", let acp = provider?["acp"] as? String, !acp.isEmpty { body["acp_command"] = acp }
    if provider == nil, mode == "ui" { body["acp_command"] = "npx --yes @agentclientprotocol/claude-agent-acp" }
    if let name = options.name { body["name"] = name }
    let made = try daemonRequest("POST", "/api/sessions", body: body)
    guard let id = made["id"] as? String else { throw Failure(message: "the daemon sent no session id", code: 1) }
    _ = try daemonRequest("PATCH", "/api/sessions/\(id)/status", body: ["status": "in_progress", "source": "user"])
    return ["session": id, "cardOnly": true]
}

// MARK: - output

func printAnswer(_ answer: [String: Any], options: Options, fallback: String) {
    if options.json {
        if let data = try? JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            return
        }
    }
    if let sessions = answer["sessions"] as? [[String: Any]] {
        for row in sessions {
            let id = row["id"] as? String ?? "?"
            let status = row["status"] as? String ?? "?"
            let name = row["name"] as? String ?? ""
            print("\(id)  \(status)  \(name)")
        }
        return
    }
    if let session = answer["session"] as? String {
        if answer["cardOnly"] as? Bool == true {
            print("created card \(session) (no tab opened)")
        } else if let tab = answer["tab"] as? String {
            print("created session \(session) (tab \(tab))")
        } else {
            print("opened session \(session)")
        }
        return
    }
    print(fallback)
}

// MARK: - main

func run(_ args: [String]) throws {
    guard let command = args.first, command != "--help", command != "-h" else {
        print(usage)
        return
    }
    let options = try parse(Array(args.dropFirst()))
    let parent = ProcessInfo.processInfo.environment["TABSH_SESSION_ID"] ?? ""
    switch command {
    case "new":
        let kind = options.kind
            ?? ((options.prompt != nil || options.provider != nil || options.model != nil) ? "agent" : "terminal")
        if let mode = options.mode, mode != "tui", mode != "ui" {
            throw Failure(message: "--mode must be tui or ui", code: 2)
        }
        if options.cardOnly {
            printAnswer(try createCardOnly(kind: kind, options: options), options: options, fallback: "created")
            return
        }
        var request: [String: Any] = [
            "do": kind == "agent" ? "session.create.agent" : "session.create.terminal",
            "focus": options.focus,
            "parent": parent,
        ]
        if let cwd = options.cwd { request["cwd"] = cwd }
        if let name = options.name { request["name"] = name }
        if let prompt = options.prompt { request["prompt"] = prompt }
        else if kind == "agent", !options.rest.isEmpty { request["prompt"] = options.rest.joined(separator: " ") }
        if let provider = options.provider { request["provider"] = provider }
        if let model = options.model { request["model"] = model }
        if let mode = options.mode { request["mode"] = mode }
        printAnswer(try askBrowser(request, options: options), options: options, fallback: "created")
    case "sessions":
        if options.cardOnly {
            throw Failure(message: "sessions needs the browser; drop --card-only", code: 2)
        }
        printAnswer(try askBrowser(["do": "session.list"], options: options), options: options, fallback: "")
    case "open":
        guard let id = options.rest.first else { throw Failure(message: "open needs a session id", code: 2) }
        if options.cardOnly {
            throw Failure(message: "open needs the browser; drop --card-only", code: 2)
        }
        printAnswer(try askBrowser(["do": "session.open", "session": id, "focus": options.focus, "parent": parent],
                                   options: options),
                    options: options, fallback: "opened")
    default:
        throw Failure(message: "unknown command \(command)\n\n\(usage)", code: 2)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch let failure as Failure {
    FileHandle.standardError.write(Data("tabsctl: \(failure.message)\n".utf8))
    exit(Int32(failure.code))
} catch {
    FileHandle.standardError.write(Data("tabsctl: \(error.localizedDescription)\n".utf8))
    exit(1)
}
