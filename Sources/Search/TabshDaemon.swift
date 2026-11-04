import AppKit
import Darwin
import Foundation

/// tabsh's daemon, in the app: the Rust process that runs the shells and
/// agents behind the browser's session tabs, started here when nothing else
/// answers for it.
///
/// One app: the binary lives in the bundle's Resources, so installing the
/// browser installs tabsh. It is this browser's own instance, not the tabsh
/// someone runs for the web app, its CLI or a phone: `TABSH_DB` points at
/// state in the app's own folder, on its own port, so the two never share a
/// database (see `stateFolder`). Started with the browser and stopped on
/// quit (`stop()`), so shells and agents do not keep running after Tabs
/// closes.
@MainActor
final class TabshDaemon {
    static let shared = TabshDaemon()

    /// Where this browser's daemon listens.
    /// - 7681: standalone tabsh (`~/.tabsh`, web app / CLI / phone)
    /// - 7682: installed Tabs (`tabs-browser`)
    /// - 7683: SEARCH_DEV Tabs (`tabs-browser-dev`)
    /// - 7684+: SEARCH_PROBE worlds, one port each so two probes never share
    nonisolated static var port: Int {
        if let world = Store.world {
            if world == "test" { return 7684 }
            var hash: UInt32 = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            return 7700 + Int(hash % 100)
        }
        return Store.development ? 7683 : 7682
    }

    nonisolated static var base: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Everything the browser's tabsh keeps: its database, the token beside
    /// it, and the `chats/` and `uploads/` folders the daemon derives from
    /// that path. Lives under `Store.folder`, so a SEARCH_DEV build and a
    /// SEARCH_PROBE world each get their own daemon — never `~/.tabsh`, and
    /// never the installed app's cards.
    nonisolated static var stateFolder: URL {
        Store.folder.appendingPathComponent("tabsh", isDirectory: true)
    }

    /// What `TABSH_DB` names when the daemon is started, and what `/api/about`
    /// must report back before the browser trusts whoever answers the port.
    nonisolated static var databasePath: URL {
        stateFolder.appendingPathComponent("state.db")
    }

    /// The token the daemon pairs with, kept beside its database.
    nonisolated static var tokenPath: URL {
        stateFolder.appendingPathComponent("token")
    }

    /// A folder holding a `tabsh` for the shells to find. Agents run
    /// `tabsh setup` and their hooks run `tabsh status` from inside the
    /// browser's terminals; on a Mac that only has this app, the binary is
    /// not installed anywhere on `PATH`. `start()` puts a link to the copy in
    /// the bundle there and puts this folder first on the daemon's `PATH`,
    /// which its shells and agents inherit. Refreshed at every launch, so
    /// moving the app does not leave a broken link behind.
    nonisolated static var binFolder: URL {
        stateFolder.deletingLastPathComponent().appendingPathComponent("bin", isDirectory: true)
    }

    /// The symlink `start()` keeps in `binFolder`, which shells and hooks
    /// should call so they always reach this app's daemon.
    nonisolated static var cliPath: URL {
        binFolder.appendingPathComponent("tabsh")
    }

    /// Prompt Welcome / Settings hand to a coding agent so it wires hooks to
    /// *this* Tabs daemon (its own port), not a separate `~/.tabsh` install.
    /// Asks which CLI to configure first — nothing is edited until the user
    /// answers. Quoted for a shell paste; `TABSH_URL` is set so `tabsh setup`
    /// embeds the right URL even when run outside a Tabs terminal.
    nonisolated static var setupPrompt: String {
        let quoted = "'\(cliPath.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        return """
        Wire a coding CLI's hooks to the Tabs board. Before you change any \
        config, ask me which CLI to set up (Claude Code, Cursor CLI, Codex, \
        OpenCode, Muse, or another I name). Do not edit files or run setup \
        until I answer. Once I pick one, run \
        `TABSH_URL=http://127.0.0.1:\(port) \(quoted) setup` and follow the \
        guide it prints — configure only that CLI so its cards stay current \
        on Tabs. Also add this to the same persistent instructions the guide \
        has you write: inside a Tabs session, `tabsctl` is on PATH — create a \
        sibling session with `tabsctl new --agent --prompt '<task>'` or \
        `tabsctl new --terminal`, list sessions with `tabsctl sessions`, and \
        reopen one with `tabsctl open <id>`; do not create sessions by \
        calling the tabsh daemon's API directly. Verify it once with \
        `tabsctl sessions` and say in your report that you did.
        """
        .replacingOccurrences(of: "\n", with: " ")
    }

    /// The `PATH` the daemon is given, and through it every shell and agent
    /// it starts.
    ///
    /// An app opened from the Dock or the Finder is launched by `launchd`
    /// with its own `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` — not the one a
    /// terminal has. Agents are installed where their instructions put them,
    /// though: `cursor-agent` and `claude` in `~/.local/bin`, `opencode` and
    /// the rest of Homebrew in `/opt/homebrew/bin`, npm's global `bin` beside
    /// nvm or pnpm. With only `launchd`'s three folders, every ACP chat died
    /// on `failed to spawn ACP agent ...: No such file or directory`, whatever
    /// the agent. A relaunch used to inherit nothing into a daemon left up
    /// from a Dock start; quitting now stops that daemon with the app.
    ///
    /// The app's `tabsh` link comes first, so nothing installed elsewhere can
    /// shadow the copy the hooks are meant to call, then the folders above, in
    /// the order a login shell usually has them, then whatever this process
    /// did inherit (a build run from a shell still finds its own `PATH`).
    nonisolated static var daemonPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = [
            binFolder.path,
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "\(home)/Library/pnpm/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        parts += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        var seen = Set<String>()
        return parts
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// What the daemon reads to know what it is talking to.
    nonisolated static func token() -> String? {
        try? String(contentsOf: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var process: Process?
    private var starting = false

    /// At launch: use this browser's daemon if it is already up, else start
    /// the bundled one.
    func startIfNeeded() {
        // The link is refreshed even when the daemon is already running: a
        // moved or updated app must not leave its shells with a stale `tabsh`.
        if let binary = Bundle.main.url(forResource: "tabsh", withExtension: nil) {
            linkBundledCLI(binary)
        }
        probe { [weak self] running in
            guard let self else { return }
            if running {
                NSLog("tabsh: this browser's daemon is already running on %d", TabshDaemon.port)
            } else {
                self.start()
            }
        }
    }

    /// On quit: stop this browser's daemon so shells and agents leave with it.
    /// SIGTERM lets tabsh flush state; a stuck process is killed after a short
    /// wait. Also clears an orphan left from a previous run (no `Process`
    /// handle when we adopted one already listening on our port).
    func stop() {
        starting = false
        if let task = process {
            process = nil
            if task.isRunning {
                task.terminate()
                Self.waitForExit(task, seconds: 2)
                if task.isRunning {
                    kill(task.processIdentifier, SIGKILL)
                }
            }
        }
        Self.terminateListener(on: Self.port)
    }

    /// Waits until `task` exits or `seconds` elapse. Used on the quit path,
    /// where a short block is better than leaving the daemon behind.
    nonisolated private static func waitForExit(_ task: Process, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Sends SIGTERM to whatever is listening on this browser's port. That
    /// port is only for this Tabs instance's daemon, so an orphan from a
    /// prior launch is safe to take down here when we have no `Process`
    /// handle for it.
    nonisolated private static func terminateListener(on port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return }
        for pid in text.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
            kill(pid, SIGTERM)
        }
    }

    /// Whether the process answering the port is this browser's daemon.
    /// Anything could be listening, and the old behaviour — trust whatever
    /// answers — is what made the browser share another tabsh's database.
    /// `/api/about` names the database the daemon opened, so the browser only
    /// adopts the instance whose state is its own.
    private func probe(_ done: @escaping (Bool) -> Void) {
        guard let token = TabshDaemon.token() else {
            // No token means no daemon of ours has ever run here.
            done(false)
            return
        }
        var request = URLRequest(url: TabshDaemon.base.appendingPathComponent("api/about"))
        request.timeoutInterval = 1
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var ours = false
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let path = object["state_path"] as? String {
                ours = URL(fileURLWithPath: path).standardizedFileURL
                    == TabshDaemon.databasePath.standardizedFileURL
            }
            DispatchQueue.main.async { done(ours) }
        }.resume()
    }

    /// Points `binFolder/tabsh` at the copy in this bundle. A symlink gives
    /// `tabsh setup` a stable path to name and follows the app when it is
    /// updated in place; a moved app gets a new link at the next launch.
    /// `tabsctl`, this browser's own session CLI, is linked the same way so
    /// an agent in any session shell finds it with no separate install.
    private func linkBundledCLI(_ binary: URL) {
        let folder = TabshDaemon.binFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        link(binary, as: "tabsh", in: folder)
        if let tabsctl = Bundle.main.url(forResource: "tabsctl", withExtension: nil) {
            link(tabsctl, as: "tabsctl", in: folder)
        }
    }

    private func link(_ binary: URL, as name: String, in folder: URL) {
        let link = folder.appendingPathComponent(name)
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
           target == binary.path {
            return
        }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: binary.path)
    }

    private func start() {
        guard process == nil, !starting else { return }
        guard let binary = Bundle.main.url(forResource: "tabsh", withExtension: nil) else {
            NSLog("tabsh: this build has no bundled daemon")
            return
        }
        starting = true

        let task = Process()
        task.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        // Tabs opened from Cursor's agent shell inherits that agent's mute
        // flags (`NO_COLOR=1`, `FORCE_COLOR=0`, `CURSOR_AGENT=1`, `TERM=dumb`).
        // The daemon's PTYs would then start every coding CLI without colour.
        for key in ["NO_COLOR", "FORCE_COLOR", "CURSOR_AGENT", "CLAUDECODE"] {
            environment.removeValue(forKey: key)
        }
        if environment["TERM"] == "dumb" {
            environment.removeValue(forKey: "TERM")
        }
        // Its own state, never the user's ~/.tabsh: the database, its token
        // and the chats and uploads beside them all follow TABSH_DB. The
        // shells it starts inherit this, so `tabsh status` in an agent's hook
        // reports to this instance too, whichever tabsh binary is on PATH.
        try? FileManager.default.createDirectory(at: TabshDaemon.stateFolder,
                                                 withIntermediateDirectories: true)
        environment["TABSH_DB"] = TabshDaemon.databasePath.path
        environment["TABSH_URL"] = "http://127.0.0.1:\(TabshDaemon.port)"
        environment["PORT"] = String(TabshDaemon.port)
        // The shells and agents the daemon starts inherit its PATH (see
        // `binFolder` and `daemonPath`): this app's own `tabsh` comes first,
        // so `tabsh setup` and the hooks it writes work with no separate
        // install, and the folders agents are installed into are there even
        // when the app was opened from the Dock and `launchd`'s own PATH
        // holds nothing but `/usr/bin:/bin:/usr/sbin:/sbin`.
        linkBundledCLI(binary)
        environment["PATH"] = TabshDaemon.daemonPath
        // It is not a terminal app when the browser starts it, and it must
        // not try to open a browser of its own.
        environment["TABSH_NO_BROWSER"] = "1"
        task.environment = environment

        // Its own log, beside the browser's data, not in the window.
        let folder = TabshDaemon.stateFolder.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("tabsh.log")

        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            task.standardOutput = handle
            task.standardError = handle
        }

        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.process = nil
                self?.starting = false
                NSLog("tabsh: daemon exited with %d", finished.terminationStatus)
            }
        }

        do {
            try task.run()
            process = task
            starting = false
            NSLog("tabsh: started %@", binary.path)
        } catch {
            starting = false
            NSLog("tabsh: couldn't start the daemon: %@", error.localizedDescription)
        }
    }
}
