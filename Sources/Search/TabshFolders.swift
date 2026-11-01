import Foundation

// The New Agent folder field: showing and expanding `~`, the recent folders
// offered before anything is typed, and the daemon call that completes a path
// the way a shell does (see tabsh's /api/files/folders).

enum TabshFolders {
    /// How many recent folders the picker offers before a search.
    static let recentLimit = 8

    /// A folder with the home folder written as `~`.
    static func tildify(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// `~` and `~/x` read with the home folder: the daemon only takes
    /// absolute paths. Anything else, `~bob` too, is left as typed.
    static func expandHome(_ input: String, home: String) -> String {
        if input == "~" || input.hasPrefix("~/") {
            return home + input.dropFirst()
        }
        return input
    }

    /// The folders cards are in, most recently moved first, without repeats.
    static func recent(from sessions: [Tabsh.SessionInfo], limit: Int = recentLimit) -> [String] {
        let sorted = sessions.sorted { $0.statusAt > $1.statusAt }
        var seen = Set<String>()
        var out: [String] = []
        for session in sorted {
            guard let cwd = session.cwd, !cwd.isEmpty, seen.insert(cwd).inserted else { continue }
            out.append(cwd)
            if out.count == limit { break }
        }
        return out
    }

    /// The highlighted result after an arrow key, wrapping around; -1 for none.
    static func moveActive(_ active: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        if active < 0 { return delta > 0 ? 0 : count - 1 }
        return (active + delta + count) % count
    }
}
