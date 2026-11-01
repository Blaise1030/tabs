import AppKit
import Foundation

/// tabsh's daemon, in the app: the Rust process that runs the shells and
/// agents behind the browser's session tabs, started here when nothing else
/// answers for it.
///
/// One app: the binary lives in the bundle's Resources, so installing the
/// browser installs tabsh. It is this browser's own instance, not the tabsh
/// someone runs for the web app, its CLI or a phone: `TABSH_DB` points at
/// state in the app's own folder, on its own port, so the two never share a
/// database (see `stateFolder`). Started here, it outlives the browser on
/// purpose: tabsh's promise is that shells stay up when the tab, the window
/// and the app go away.
@MainActor
final class TabshDaemon {
    static let shared = TabshDaemon()

    /// Where this browser's daemon listens. Distinct from tabsh's own default
    /// (7681), which may already be serving the user's web app.
    nonisolated static let port = 7682

    nonisolated static var base: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Everything the browser's tabsh keeps: its database, the token beside
    /// it, and the `chats/` and `uploads/` folders the daemon derives from
    /// that path. Separate from `~/.tabsh`, so the browser's cards, sessions
    /// and tokens are its own.
    nonisolated static var stateFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("tabsh-browser/tabsh", isDirectory: true)
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
    private func linkBundledCLI(_ binary: URL) {
        let folder = TabshDaemon.binFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("tabsh")
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
        // Its own state, never the user's ~/.tabsh: the database, its token
        // and the chats and uploads beside them all follow TABSH_DB. The
        // shells it starts inherit this, so `tabsh status` in an agent's hook
        // reports to this instance too, whichever tabsh binary is on PATH.
        try? FileManager.default.createDirectory(at: TabshDaemon.stateFolder,
                                                 withIntermediateDirectories: true)
        environment["TABSH_DB"] = TabshDaemon.databasePath.path
        environment["PORT"] = String(TabshDaemon.port)
        // The shells and agents the daemon starts inherit its PATH (see
        // `binFolder`): this app's own `tabsh` comes first, so `tabsh setup`
        // and the hooks it writes work with no separate install.
        linkBundledCLI(binary)
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = TabshDaemon.binFolder.path + ":" + path
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
