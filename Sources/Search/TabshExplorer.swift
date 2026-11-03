import AppKit
import SwiftUI

/// Opens or focuses the project column from a menu or key. Only the front
/// terminal/agent tab answers — every open pane listens, and the one whose
/// session is on screen acts.
enum TabshExplorerActions {
    static let toggleName = Notification.Name("tabsh.explorer.toggle")
    static let searchName = Notification.Name("tabsh.explorer.search")
    /// The explorer column itself: focus its search field after it opens.
    static let focusSearch = Notification.Name("tabsh.explorer.focusSearch")

    static func toggle() {
        NotificationCenter.default.post(name: toggleName, object: nil)
    }

    /// Show the project column (if shut) and put the caret in Search….
    static func searchFiles() {
        NotificationCenter.default.post(name: searchName, object: nil)
    }
}

// A terminal tab's project, down the side: the tree the daemon builds from
// the session's own folder (see Tabsh.tree), with a field that filters it.
// A folder row folds and unfolds; a file row opens in an editor tab. The
// sidebar is part of the terminal's tab, so close or restore brings the
// explorer back with the same session, rooted where the daemon last had it.
//
// The agent's tab wears the same column: see TabshProjectPane, which both
// panes share so the tree, its width and its edge behave identically.
//
// The tree follows the session: it is read once, then kept live from the
// daemon's watch socket (Tabsh.filesWatchRequest) — files that appear or go
// are patched in, and when the session's folder moves to another project the
// listing is read again at the new root. That is what makes the sidebar
// follow a `cd` in the shell, or whatever folder the agent has moved to.
struct TabshTerminalPane: View {
    let sessionID: String
    /// The tab this pane is drawn in. What it is for is the keys: a pane that
    /// is not the page on show must not ask for them — see claimsKeys.
    let tab: Tab
    @ObservedObject var browser: Browser
    @ObservedObject private var sessions = TabshSessions.shared
    @ObservedObject private var terminalSettings = TerminalPreferences.shared
    /// The shell behind the pane, watched for the state its own title
    /// reports (see TabshAgentActivity): the header reacts to the agent
    /// itself, with no tabsh hooks in between.
    @ObservedObject private var terminal: TabshTerminal

    init(sessionID: String, tab: Tab, browser: Browser) {
        self.sessionID = sessionID
        self.tab = tab
        _browser = ObservedObject(wrappedValue: browser)
        _terminal = ObservedObject(wrappedValue: TabshTerminals.shared.terminal(for: sessionID))
    }
    /// Files column stays shut until asked for — agent TUI shares the UI
    /// agent pane's choice; a plain shell starts closed each time too.
    @AppStorage("tabsh.agent.explorer") private var agentShowingExplorer = false
    @State private var shellShowingExplorer = false
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { browser.chromeTheme?.dark ?? (scheme == .dark) }
    private var tint: NSColor? { browser.chromeTheme?.color }
    /// The ground under both halves, so the explorer is part of the
    /// terminal rather than a panel of its own (see TabshTerminalTheme).
    private var ground: Color {
        Color(nsColor: terminalSettings.colours(dark: dark, tint: tint).background)
    }
    /// Ink in the header follows the terminal's ground, not the window —
    /// a dark theme in a light window would otherwise paint dark text on
    /// dark ground (Palette resolves against the window's appearance).
    private var terminalScheme: ColorScheme {
        let bg = terminalSettings.colours(dark: dark, tint: tint).background
        guard let rgb = bg.usingColorSpace(.sRGB) else { return dark ? .dark : .light }
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return lum > 0.5 ? .light : .dark
    }

    private var session: Tabsh.SessionInfo? { sessions.info(for: sessionID) }
    /// An agent in a terminal still wears the chat's header — name,
    /// move/delete — so a TUI card and a UI card read the same way. The
    /// card's status select is the chat's alone; this header instead wears
    /// the live state the agent's own terminal title reports (see
    /// `terminal.activity`), which needs no hooks and never moves the card.
    /// A plain shell has none of that, and only floats the explorer button
    /// when shut.
    private var hasAgent: Bool { session?.hasAgent == true }
    /// Whether the keys belong to the shell: this pane's tab is the page on
    /// show, and the address field or the find bar isn't over it waiting to
    /// be typed into. A shell that claimed them anyway took them from the
    /// field of the tab opening behind it — ⌘T from an agent tab left the new
    /// tab's caret nowhere, with what was typed going to the shell instead.
    private func claimsKeys() -> Bool {
        browser.activeID == tab.id && !browser.editing && !browser.finding
    }

    private var showingExplorer: Binding<Bool> {
        Binding(
            get: { hasAgent ? agentShowingExplorer : shellShowingExplorer },
            set: { if hasAgent { agentShowingExplorer = $0 } else { shellShowingExplorer = $0 } }
        )
    }

    var body: some View {
        TabshProjectPane(sessionID: sessionID,
                         browser: browser,
                         ground: ground,
                         showingExplorer: showingExplorer) {
            VStack(spacing: 0) {
                if hasAgent {
                    // Same status select the chat header wears; activity stays
                    // beside it when the agent is working.
                    TabshSessionHeader(
                        sessionID: sessionID,
                        title: session?.label ?? "Agent",
                        showingExplorer: showingExplorer,
                        statusInMenu: false
                    ) {
                        HStack(spacing: 8) {
                            if let activity = terminal.activity {
                                TabshAgentActivityPill(activity: activity,
                                                       title: terminal.agentTitle)
                            }
                            TabshHeaderStatusSelect(sessionID: sessionID)
                        }
                    }
                    // Same ground as the shell and explorer, so the header
                    // is part of the TUI column rather than a chrome strip.
                    .background(ground)
                    .environment(\.colorScheme, terminalScheme)
                }
                TabshTerminalView(sessionID: sessionID, browser: browser,
                                  claimsKeys: claimsKeys)
                    // Air around the shell: text that touches the tab's edges
                    // reads as clipped rather than as a terminal. No rounding
                    // on the shell itself (see TabshTerminalView): the padding
                    // is the only frame it needs.
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(alignment: .topTrailing) { floatingChrome }
            }
        }
    }

    /// A plain terminal has no header, so the project toggle floats over
    /// the shell. Agent shells put the same list mark in the header.
    @ViewBuilder
    private var floatingChrome: some View {
        if !hasAgent {
            ExplorerToggleButton(showing: $shellShowingExplorer, ground: ground)
        }
    }
}

/// A tab's project column, shared by the terminal and the agent chat: the
/// caller's content on the left, the explorer on the right, and the drag
/// edge between them. It is the same tree either way — the session's folder —
/// so a file opens the same way from a shell or from a conversation.
struct TabshProjectPane<Content: View>: View {
    let sessionID: String
    @ObservedObject var browser: Browser
    /// The ground under both halves (the terminal's, or the chat's).
    let ground: Color
    @Binding var showingExplorer: Bool
    @ViewBuilder let content: Content

    @AppStorage("tabsh.explorerWidth") private var explorerWidth: Double = 200

    /// This pane belongs to the tab on screen: keys and menus only open its
    /// explorer, not every terminal sitting behind it.
    private var isFront: Bool {
        browser.active?.tabshSessionID == sessionID
    }

    var body: some View {
        HStack(spacing: 0) {
            content
            if showingExplorer {
                // Edge is an overlay on the column's leading side (as the
                // tab column's grip is), not a sibling above it — otherwise
                // the pill paints through the search field. The chrome keeps
                // a higher z-index so the field stays on top of the grip.
                TabshExplorer(sessionID: sessionID, browser: browser, ground: ground)
                    .frame(width: explorerWidth)
                    .background(ground)
                    .overlay(alignment: .leading) { explorerEdge }
                    .zIndex(1)
            }
        }
        .background(ground)
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: TabshExplorerActions.toggleName)) { _ in
            guard isFront else { return }
            showingExplorer.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: TabshExplorerActions.searchName)) { _ in
            guard isFront else { return }
            showingExplorer = true
            // After the column is in the tree — focusing in the same turn
            // as opening misses the field.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: TabshExplorerActions.focusSearch,
                                                object: sessionID)
            }
        }
    }

    /// The explorer's edge: nine points to take hold of, starting under the
    /// title and search so those stay above the grip. AppKit owns the drag:
    /// a SwiftUI gesture here lost the pointer to the split stage.
    private var explorerEdge: some View {
        ExplorerEdge(width: $explorerWidth)
            .frame(width: 9)
            .padding(.top, TabshExplorer.chromeHeight)
            .allowsHitTesting(true)
    }
}

/// Opens and closes the project column: a folder mark in the agent header,
/// and the same control floating over a plain terminal that has no header.
struct ExplorerToggleButton: View {
    @Binding var showing: Bool
    /// Painted behind the floating form so the shell's text does not read
    /// through it. Nil leaves it bare, as in a header.
    var ground: Color? = nil

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: showing ? "folder.fill" : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(showing ? Palette.ink : Palette.muted)
                .frame(width: 24, height: 24)
                .background {
                    if let ground {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ground.opacity(0.85))
                    } else if showing {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.hover)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showing ? "Hide the project" : "Show the project")
        .padding(ground == nil ? 0 : 8)
        .accessibilityLabel(showing ? "Hide the project" : "Show the project")
    }
}

private struct TabshExplorer: View {
    let sessionID: String
    @ObservedObject var browser: Browser
    /// Same ground as the pane, so the chrome strip above the resize grip
    /// matches the column (a terminal theme's background, or Palette.ground).
    let ground: Color

    @ObservedObject private var sessions = TabshSessions.shared
    @State private var root = ""
    @State private var paths: [String] = []
    @State private var truncated = false
    @State private var foldersOnly = false
    @State private var loading = true
    @State private var failure: String?
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var hovered: String?
    /// Folders whose children are being fetched (truncated listings start
    /// empty under each folder until opened).
    @State private var loadingFolders: Set<String> = []
    @FocusState private var searchFocused: Bool

    /// Title row + search field + the padding above them: the resize grip
    /// starts below this so the search paints over it, not under it.
    static let chromeHeight: CGFloat = 62

    /// What this session's tree had open, kept per session so switching a
    /// tab or relaunching the browser comes back to the same folders.
    private var expandedKey: String { "tabsh.explorer.expanded.\(sessionID)" }

    private var rootName: String {
        root.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init) ?? "/"
    }

    private var dirs: Set<String> {
        Set(paths.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) })
    }

    private var tree: [Node] { build() }

    private var matches: [Node] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return paths
            .filter { relative in
                let name = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
                return name.split(separator: "/").last
                    .map { $0.localizedCaseInsensitiveContains(needle) } ?? false
            }
            .sorted()
            .map { relative in
                let clean = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
                return Node(path: clean,
                            name: clean.split(separator: "/").last.map(String.init) ?? clean,
                            isDir: relative.hasSuffix("/"))
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Above the resize grip (see TabshProjectPane.explorerEdge): an
            // opaque strip so the edge pill cannot show through the field.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.faint)
                    Text(rootName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(root)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    TextField("Search…", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.hover)
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ground)
            .zIndex(1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 10)
        }
        .onReceive(NotificationCenter.default.publisher(for: TabshExplorerActions.focusSearch)) { note in
            guard (note.object as? String) == sessionID else { return }
            searchFocused = true
        }
        .padding(.bottom, 6)
        .task(id: sessionID) {
            restoreFolders()
            await load()
            // Read once above, then kept in step with the daemon until the
            // tab (or the column) goes away.
            await follow()
        }
        .onChange(of: expanded) { _, open in
            UserDefaults.standard.set(Array(open), forKey: expandedKey)
            // Truncated / folders-only listings only carry the first level:
            // opening a folder loads what is under it.
            Task { await loadOpenedFolders(open) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        } else if let failure {
            Text(failure)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
        } else if paths.isEmpty {
            Text(truncated ? "Too many files here to list." : "Nothing here.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if matches.isEmpty {
                        Text("No matches.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .padding(.top, 8)
                    }
                    ForEach(matches) { node in
                        FileRow(node: node, depth: 0, showsPath: true, expanded: false,
                                base: root, hovered: hovered == node.path,
                                onHover: { hover($0, node) },
                                onTap: { tapped(node, inSearch: true) })
                    }
                }
            }
            .scrollIndicators(.never)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // A reduced listing still draws: folders (and top-level
                    // files) rather than an empty column when the tree is huge.
                    if truncated || foldersOnly {
                        Text("Folders and top-level files — open a folder to explore it.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.faint)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                            .padding(.horizontal, 4)
                    }
                    ForEach(tree) { node in
                        TreeRows(node: node, depth: 0, base: root,
                                 expanded: $expanded, hovered: $hovered,
                                 loadingFolders: loadingFolders, open: open)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func hover(_ over: Bool, _ node: Node) {
        if over { hovered = node.path }
        else if hovered == node.path { hovered = nil }
    }

    private func tapped(_ node: Node, inSearch: Bool) {
        if node.isDir {
            guard inSearch else { return }
            // A folder found by search: clear the field and open its way in
            // the tree, so it is where it belongs rather than alone in a list.
            var walked = ""
            for part in node.path.split(separator: "/") {
                walked += walked.isEmpty ? String(part) : "/" + part
                expanded.insert(walked)
            }
            search = ""
        } else {
            open(node)
        }
    }

    private func open(_ node: Node) {
        // Pictures and Markdown open as documents; everything else as text.
        let type = (node.name as NSString).pathExtension.lowercased()
        let preview = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "md", "markdown", "mdown", "mkd"]
        browser.showBeside(InternalPage(preview.contains(type) ? .preview : .editor, absolute(node.path)),
                           of: browser.active)
    }

    private func absolute(_ path: String) -> String {
        let base = root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.isEmpty ? "/" + path : "/" + base + "/" + path
    }

    private func restoreFolders() {
        expanded = Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? [])
    }

    private func load(quiet: Bool = false) async {
        if !quiet { loading = true }
        failure = nil
        do {
            let tree = try await Tabsh.tree(session: sessionID)
            apply(tree)
            loading = false
            // Restored open folders under a truncated root need their
            // children fetched the same way a fresh click would.
            await loadOpenedFolders(expanded)
        } catch {
            // A timeout on a huge root used to leave the column empty with
            // "/" in the header. Fall back to a shallow listing of the
            // session folder (or home, or `/`) so folders are still there
            // to open.
            if let tree = await shallowFallback() {
                apply(tree)
                failure = nil
                await loadOpenedFolders(expanded)
            } else {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func apply(_ tree: Tabsh.Tree) {
        root = tree.root
        paths = tree.paths
        truncated = tree.truncated
        foldersOnly = tree.foldersOnly
    }

    /// Shallow listing when the session tree fails: cwd, then home, then `/`.
    private func shallowFallback() async -> Tabsh.Tree? {
        var candidates: [String] = []
        if let cwd = sessions.sessions[sessionID]?.cwd, !cwd.isEmpty {
            candidates.append(cwd)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !candidates.contains(home) { candidates.append(home) }
        if !candidates.contains("/") { candidates.append("/") }
        for path in candidates {
            if let tree = try? await Tabsh.tree(path: path), !tree.paths.isEmpty {
                return tree
            }
        }
        return nil
    }

    /// Whether `folder` already has a direct child in the listing.
    private func hasDirectChild(_ folder: String) -> Bool {
        paths.contains { relative in
            let clean = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
            guard !clean.isEmpty, clean != folder else { return false }
            let parent = clean.contains("/")
                ? String(clean[..<clean.lastIndex(of: "/")!])
                : ""
            return parent == folder
        }
    }

    /// Fetch what sits under each newly opened folder when the listing is
    /// only a summary (home, `/`, or any truncated root).
    private func loadOpenedFolders(_ open: Set<String>) async {
        guard foldersOnly || truncated else { return }
        for folder in open where dirs.contains(folder) {
            guard !hasDirectChild(folder), !loadingFolders.contains(folder) else { continue }
            loadingFolders.insert(folder)
            defer { loadingFolders.remove(folder) }
            let abs = absolute(folder)
            guard let tree = try? await Tabsh.tree(path: abs) else { continue }
            let prefix = folder.isEmpty ? "" : folder + "/"
            let added = tree.paths.map { prefix + $0 }
            paths = TabshTreePaths.applying(add: added, remove: [], to: paths)
            // A subfolder that is itself huge stays a summary: keep the
            // truncated flag so opening its children still loads.
            if tree.truncated || tree.foldersOnly {
                truncated = true
                foldersOnly = true
            }
        }
    }

    // MARK: - Following the session

    /// The daemon's watch socket, read until the tab goes away. It follows
    /// the session's own folder, so a `cd` into another project roots the
    /// tree there; and it names the files that appeared or went, so the tree
    /// tracks the agent's work without asking for the whole listing again.
    private func follow() async {
        var retrying = false
        while !Task.isCancelled {
            if retrying {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                // Whatever happened while the socket was down was missed:
                // read the listing once before listening again.
                await load(quiet: true)
            }
            retrying = true
            guard let request = Tabsh.filesWatchRequest(for: sessionID) else { return }
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()
            do {
                try await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        await apply(message)
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                // The daemon restarted, or the Mac slept: reconnect below.
            }
            socket.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { return }
        }
    }

    /// One watch message: a new root, a request to read the tree again, or
    /// the paths that went and came.
    private func apply(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case let .data(bytes): data = bytes
        case let .string(text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let moved = object["root"] as? String, !moved.isEmpty {
            // The session's folder is in another project now: the paths we
            // hold are relative to the old root and mean nothing here.
            await load(quiet: true)
        } else if object["reset"] as? Bool == true {
            await load(quiet: true)
        } else {
            await patch(add: object["add"] as? [String] ?? [],
                        remove: object["remove"] as? [String] ?? [])
        }
    }

    /// Applies the watch's changes to the listing in place. A truncated tree
    /// is a summary (folders only, or past the limit), so any change there
    /// means reading it again rather than guessing what it holds now.
    private func patch(add: [String], remove: [String]) async {
        guard !add.isEmpty || !remove.isEmpty else { return }
        guard !truncated else {
            await load(quiet: true)
            return
        }
        paths = TabshTreePaths.applying(add: add, remove: remove, to: paths)
    }

    // MARK: - The tree

    private func build() -> [Node] {
        let folders = dirs
        var byParent: [String: [String]] = [:]
        for path in paths {
            let isDir = path.hasSuffix("/")
            let clean = isDir ? String(path.dropLast()) : path
            guard !clean.isEmpty else { continue }
            let parent = clean.contains("/") ? String(clean[..<clean.lastIndex(of: "/")!]) : ""
            byParent[parent, default: []].append(clean)
        }
        func make(_ path: String) -> Node {
            let isDir = folders.contains(path)
            let children = (byParent[path] ?? [])
                .sorted { a, b in
                    let da = folders.contains(a), db = folders.contains(b)
                    if da != db { return da }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
                .map { make($0) }
            return Node(path: path,
                        name: path.split(separator: "/").last.map(String.init) ?? path,
                        isDir: isDir, children: children)
        }
        return (byParent[""] ?? [])
            .sorted { a, b in
                let da = folders.contains(a), db = folders.contains(b)
                if da != db { return da }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { make($0) }
    }
}

// MARK: - The watch's changes

/// What a watch message leaves of a listing: the paths that came, without
/// the ones that went. A removed directory takes everything under it with
/// it, and the watch names it without the trailing slash a directory path
/// carries in the listing.
enum TabshTreePaths {
    static func applying(add: [String], remove: [String], to paths: [String]) -> [String] {
        var set = Set(paths)
        for gone in remove {
            set.remove(gone)
            set.remove(gone + "/")
            let under = gone + "/"
            set = set.filter { !$0.hasPrefix(under) }
        }
        set.formUnion(add)
        return set.sorted()
    }
}

// MARK: - Rows

private struct Node: Identifiable {
    let path: String
    let name: String
    let isDir: Bool
    var children: [Node] = []

    var id: String { path }
}

/// One node and, while it is unfolded, its children after it.
private struct TreeRows: View {
    let node: Node
    let depth: Int
    let base: String
    @Binding var expanded: Set<String>
    @Binding var hovered: String?
    let loadingFolders: Set<String>
    let open: (Node) -> Void

    var body: some View {
        let isOpen = expanded.contains(node.path)
        let loading = loadingFolders.contains(node.path)
        FileRow(node: node, depth: depth, showsPath: false, expanded: isOpen,
                base: base, hovered: hovered == node.path, loading: loading,
                onHover: { over in
                    if over { hovered = node.path }
                    else if hovered == node.path { hovered = nil }
                },
                onTap: {
                    if node.isDir {
                        withAnimation(.easeOut(duration: 0.12)) {
                            if isOpen { expanded.remove(node.path) } else { expanded.insert(node.path) }
                        }
                    } else {
                        open(node)
                    }
                })
        if node.isDir, isOpen {
            if loading && node.children.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                .padding(.leading, CGFloat(depth + 1) * 12 + 9)
                .padding(.vertical, 3)
            }
            ForEach(node.children) { child in
                TreeRows(node: child, depth: depth + 1, base: base,
                         expanded: $expanded, hovered: $hovered,
                         loadingFolders: loadingFolders, open: open)
            }
        }
    }
}

private struct FileRow: View {
    let node: Node
    let depth: Int
    let showsPath: Bool
    let expanded: Bool
    let base: String
    let hovered: Bool
    var loading: Bool = false
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if node.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 9)
            } else {
                Color.clear.frame(width: 9)
            }
            Image(systemName: icon)
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(node.isDir ? Palette.muted : Palette.faint)
            Text(showsPath ? node.path : node.name)
                .font(.system(size: 11.5))
                .foregroundStyle(node.isDir ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .truncationMode(showsPath ? .head : .middle)
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
        // Edge to edge inside the panel, a step per level: the rows line up
        // with the search field above them, and the hover pill spans the
        // column rather than floating inside it.
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.trailing, 0)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
        .contextMenu {
            if !node.isDir {
                Button("Open") { onTap() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
                }
                Divider()
            }
            Button("Copy Path") { copy(absolute) }
        }
    }

    private var icon: String {
        if node.isDir { return "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "text.document"
        case "swift": return "swift"
        case "rs": return "gearshape.2"
        case "json", "toml", "yaml", "yml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        default: return "doc.text"
        }
    }

    private var absolute: String {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" + node.path : "/" + trimmed + "/" + node.path
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


/// The explorer's edge in AppKit: the same little capsule the browser's tab
/// column shows when the pointer is on its edge (see EdgeGrip in Design.swift),
/// with a hairline to say where the column ends. It owns the drag itself — a
/// SwiftUI gesture here lost the pointer to the split stage — and works in
/// absolute positions, so dragging right always widens.
private struct ExplorerEdge: NSViewRepresentable {
    @Binding var width: Double

    func makeNSView(context: Context) -> EdgeView {
        let view = EdgeView()
        view.currentWidth = { CGFloat(width) }
        view.onResize = { wanted in
            width = min(480, max(140, Double(wanted)))
        }
        return view
    }

    func updateNSView(_ view: EdgeView, context: Context) {
        view.currentWidth = { CGFloat(width) }
        view.onResize = { wanted in
            width = min(480, max(140, Double(wanted)))
        }
    }

    final class EdgeView: NSView {
        var currentWidth: () -> CGFloat = { 236 }
        var onResize: ((CGFloat) -> Void)?

        private var hovering = false
        private var dragging = false
        private var startWidth: CGFloat = 0
        private var startX: CGFloat = 0
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            dragging = true
            startWidth = currentWidth()
            startX = event.locationInWindow.x
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            onResize?(startWidth - (event.locationInWindow.x - startX))
        }

        override func mouseUp(with event: NSEvent) {
            dragging = false
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            // No line down the edge: the explorer and the terminal are one
            // ground now, and the pill alone says where the edge is.
            //
            // The pill: faint at rest, longer and brighter under the hand,
            // exactly as the tab column's edge behaves.
            let lit = hovering || dragging
            let height: CGFloat = lit ? 40 : 28
            let pill = NSRect(x: bounds.midX - 2, y: bounds.midY - height / 2, width: 4, height: height)
            (lit ? Palette.NS.muted : Palette.NS.faint).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 2, yRadius: 2).fill()
        }
    }
}
