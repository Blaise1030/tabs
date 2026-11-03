import AppKit
import SwiftTerm
import SwiftUI

/// SwiftTerm's terminal, without the system scroller it puts down its edge:
/// the column is one surface, and a permanent thick bar was the loudest thing
/// in it. Scrolling still works; the knob is simply not drawn. Files dropped
/// on it are pasted as shell-quoted paths (see TabshDrop), the same shape
/// the web app's drop.ts feeds a TUI.
final class ChromeTerminalView: TerminalView {
    var onDropFiles: (([URL]) -> Void)?

    override func layout() {
        super.layout()
        for sub in subviews
        where sub is NSScroller || sub.identifier?.rawValue == "SwiftTermOverlayScrollerIndicator" {
            sub.isHidden = true
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TabshDrop.urls(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        TabshDrop.urls(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !TabshDrop.urls(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = TabshDrop.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

/// The terminal's colours, in one place: the explorer beside it paints the
/// same ground (see TabshTerminalPane), so the two read as one column.
@MainActor
enum TabshTerminalTheme {
    static func colours(dark: Bool, tint: NSColor? = nil) -> TerminalColours {
        TerminalPreferences.shared.colours(dark: dark, tint: tint)
    }

    static func background(dark: Bool, tint: NSColor? = nil) -> NSColor {
        colours(dark: dark, tint: tint).background
    }
}

// A tabsh shell in a tab of the browser, drawn by SwiftTerm and carried over
// the daemon's socket (see Tabsh.swift). One per session, kept alive while
// the browser runs so switching tabs neither drops the socket nor replays
// the screen: the tab comes back to the terminal it left.
@MainActor
final class TabshTerminals {
    static let shared = TabshTerminals()

    private var live: [String: TabshTerminal] = [:]

    func terminal(for session: String) -> TabshTerminal {
        if let open = live[session] { return open }
        let made = TabshTerminal(sessionID: session)
        live[session] = made
        return made
    }

    /// The tab was closed. The shell stays up on the daemon — that is tabsh's
    /// promise — and the socket is let go with the view.
    func close(_ session: String) {
        live.removeValue(forKey: session)?.stop()
    }
}

/// What an agent in a terminal is doing, read from the title it sets for
/// itself (OSC 0/2, SwiftTerm's `setTerminalTitle`). This is the agent's
/// own word, not the card's: it needs no tabsh hooks, and it never moves
/// the card — the header wears it as a live indicator beside the card's
/// hook-driven state on the tab badge.
///
/// Agents title the same few ways: a braille (or rotating-circle) spinner
/// while a turn runs, a still mark (`✳`, a tick) at rest, and plain words
/// when they are blocked on the person. Anything else — a plain shell's
/// `user@host: ~/folder` — says nothing and leaves the header bare.
/// The spinner is checked before the words: a working agent's title is a
/// summary of its task, so "Fix the permission bug" under a spinner is
/// work, not a request, and the still `✳` is checked before the working
/// words for the same reason.
enum TabshAgentActivity: Equatable {
    case working
    case needsInput
    case ready

    init?(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        if first.unicodeScalars.first.map({ (0x2800...0x28FF).contains($0.value) }) == true
            || "◐◓◑◒◍◌⟳↻".contains(first) {
            self = .working
            return
        }
        let words = trimmed.lowercased()
        let waiting = [
            "waiting for input", "waiting for your input", "needs input",
            "needs your input", "awaiting input", "awaiting your",
            "permission requested", "requesting permission",
            "waiting for permission", "waiting for approval",
            "approval requested", "(y/n)", "[y/n]", "press enter",
            "do you want to proceed", "would you like to proceed",
        ]
        if waiting.contains(where: words.contains) {
            self = .needsInput
            return
        }
        if "✳✓✔".contains(first) {
            self = .ready
            return
        }
        let working = ["working", "thinking", "processing", "generating",
                       "running…", "running..."]
        if working.contains(where: words.contains) {
            self = .working
            return
        }
        let atRest = ["done", "finished", "completed", "ready", "idle"]
        if atRest.contains(where: words.contains) {
            self = .ready
            return
        }
        return nil
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .ready: return "Ready"
        }
    }
}

/// The header's live read of the agent's own title: a spinner while it
/// works, the asking mark when it is blocked, a tick at rest. Read-only —
/// moving the card stays with the header's menu and the chat's select.
struct TabshAgentActivityPill: View {
    let activity: TabshAgentActivity
    /// The full title the state was read from, for the help text.
    var title: String?

    var body: some View {
        HStack(spacing: 5) {
            switch activity {
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 11, height: 11)
            case .needsInput:
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.unsafe)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.safe)
            }
            Text(activity.label)
                .foregroundStyle(Palette.ink)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.hover))
        .fixedSize()
        .help(title ?? activity.label)
        .accessibilityLabel("Agent")
        .accessibilityValue(activity.label)
    }
}

@MainActor
final class TabshTerminal: NSObject, ObservableObject, TerminalViewDelegate {
    let sessionID: String
    let view: TerminalView
    @Published private(set) var exited = false
    /// The agent's state as its own terminal title reports it, and that
    /// title. Updated only when the state changes: a spinner retitles the
    /// terminal every frame, and the header must not rebuild with it.
    @Published private(set) var activity: TabshAgentActivity?
    @Published private(set) var agentTitle: String?

    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var retries = 0
    private var reconnect: DispatchWorkItem?
    /// The shell output this screen holds: the daemon's epoch for the shell,
    /// and how many bytes of it have been fed. A reconnect asks for only what
    /// came after, as the web app's terminal does, so a screen that is
    /// already full is not filled with the same scrollback twice.
    private var epoch: String?
    private var at = 0
    /// The next binary frame is the replay that follows the daemon's stream
    /// frame, and whether it holds only what this screen missed (`resumed`)
    /// rather than the whole scrollback, which replaces what is on screen.
    private var replaying = false
    private var resumed = false
    /// SwiftTerm is still parsing the replay. Answers to OSC colour queries
    /// in that history must not reach the live PTY — they would land on the
    /// shell prompt as typed garbage (and race the daemon's resume line).
    /// Same idea as the web app's `parsingReplay`.
    private var parsingReplay = false

    init(sessionID: String) {
        self.sessionID = sessionID
        view = ChromeTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 520),
                                  font: TerminalPreferences.shared.font)
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = NSColor(srgbRed: 0.047, green: 0.047, blue: 0.047, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1)
        view.caretColor = NSColor(srgbRed: 0.55, green: 0.78, blue: 0.98, alpha: 1)
        if let chrome = view as? ChromeTerminalView {
            chrome.registerForDraggedTypes([
                .fileURL, .png, .tiff,
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.png"),
                NSPasteboard.PasteboardType("public.tiff"),
            ])
            chrome.onDropFiles = { [weak self] urls in
                self?.pasteDropped(urls)
            }
        }
        connect()
    }

    /// A drop on the terminal: local paths, shell-quoted, as a paste so a
    /// TUI like Claude Code picks them up the way the web app's drop does.
    private func pasteDropped(_ urls: [URL]) {
        let text = TabshDrop.pastePaths(urls)
        guard !text.isEmpty else { return }
        view.pasteText(text)
    }

    /// The chrome's colours, so the terminal is part of the same window
    /// rather than a black rectangle inside a light one: the page's own tint
    /// when the browser is following a page, else the light or dark the
    /// window is drawn in. The explorer beside it paints the same ground.
    func apply(dark: Bool, tint: NSColor? = nil) {
        let colours = TabshTerminalTheme.colours(dark: dark, tint: tint)
        view.nativeBackgroundColor = colours.background
        view.nativeForegroundColor = colours.foreground
        view.caretColor = colours.caret
        view.selectedTextBackgroundColor = colours.foreground.withAlphaComponent(0.18)
        let font = TerminalPreferences.shared.font
        if view.font.fontName != font.fontName || view.font.pointSize != font.pointSize {
            view.font = font
        }
        view.needsDisplay = true
    }

    func stop() {
        stopped = true
        reconnect?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func connect() {
        // A shell the daemon replaced (or a daemon that restarted) has a new
        // epoch: the daemon can't honour the old resume and sends the whole
        // scrollback, which the first binary frame tells us to replace.
        let seen = epoch.map { (epoch: $0, at: at) }
        guard !stopped,
              let url = Tabsh.socketURL(for: sessionID, resume: seen)
        else { return }
        var request = URLRequest(url: url)
        // The daemon takes a WebSocket only when it can see where it came
        // from; this is the browser's own copy of its page.
        request.setValue(Tabsh.origin, forHTTPHeaderField: "Origin")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receive()
        // A shell that has never been sized asks for a sensible default until
        // the view's first layout says otherwise.
        sendResize(cols: 80, rows: 24)
    }

    private func receive() {
        guard let socket else { return }
        socket.receive { [weak self, weak socket] result in
            Task { @MainActor [weak self] in
                // A late message from a socket that has already been
                // replaced must not feed the new screen or open another
                // reconnect.
                guard let self, let socket, self.socket === socket else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    self.receive()
                case .failure:
                    self.retry()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .data(data):
            // The first frame after the stream frame is the replay: its bytes
            // are already counted by `at`. Live output came after it.
            let replay = replaying
            replaying = false
            if replay {
                // Hold `send` closed across the feed and one turn after: the
                // terminal answers colour queries while parsing, and may
                // finish those replies on the next run-loop pass.
                parsingReplay = true
                if !resumed { view.resetToInitialState() }
                if !data.isEmpty { view.feed(byteArray: [UInt8](data)[...]) }
                DispatchQueue.main.async { [weak self] in
                    self?.parsingReplay = false
                }
            } else {
                if !data.isEmpty { view.feed(byteArray: [UInt8](data)[...]) }
                at += data.count
            }
            retries = 0
        case let .string(text):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let stream = object["stream"] as? [String: Any],
               let epoch = stream["epoch"] as? String,
               let at = stream["at"] as? Int {
                // Says whether the replay that follows is the whole scrollback
                // (a fresh shell, or a resume the daemon couldn't honour) or
                // only the bytes this screen missed.
                self.epoch = epoch
                self.at = at
                replaying = true
                resumed = stream["resumed"] as? Bool == true
            } else if object["exit"] as? Bool == true {
                exited = true
            } else if object["restart"] as? Bool == true {
                // The daemon replaced the shell: attach to the new one.
                retry(now: true)
            }
            // {"bell":…} needs nothing here.
        @unknown default:
            break
        }
    }

    private func retry(now: Bool = false) {
        guard !stopped, !exited else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        reconnect?.cancel()
        let delay = now ? 0 : min(8, pow(2, Double(retries)))
        retries += 1
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sendResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let socket else { return }
        socket.send(.string("{\"cols\":\(cols),\"rows\":\(rows)}")) { _ in }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // While the stream header is open or the replay is being parsed,
        // drop emulator replies — they are not keystrokes.
        guard !replaying, !parsingReplay else { return }
        guard !data.isEmpty, let socket else { return }
        socket.send(.data(Data(data))) { _ in }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // The card's own name is the browser tab's; a shell's OSC title
        // changes too often to steal it. What it does say is what the
        // agent is doing right now, and the pane's header wears that (see
        // TabshAgentActivity) — for an agent's session, not a plain shell,
        // whose titles the classifier leaves alone either way.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if agentTitle != trimmed { agentTitle = trimmed }
        let next = TabshAgentActivity(title: title)
        if activity != next { activity = next }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }

    func kittyClipboardAvailableMimeTypes(source: TerminalView,
                                          location: KittyClipboardLocation) -> [String]? { nil }

    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation,
                            mimeType: String) -> KittyClipboardReadResult? { nil }

    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation,
                             content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }

    func kittyClipboardRequestPermission(source: TerminalView,
                                         request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The terminal in a tab: SwiftTerm's view, reparented into whatever the
/// stage is drawing now, and the message a dead shell leaves behind.
struct TabshTerminalView: NSViewRepresentable {
    let sessionID: String
    @ObservedObject var browser: Browser
    /// Whether the keys belong to this pane: its tab is the page on show, and
    /// nothing the person is typing into is over it (see TabshTerminalPane).
    /// Asked each time a claim is about to be made, not read once — a pane on
    /// its way out is given no last update to say so in.
    var claimsKeys: () -> Bool
    @ObservedObject private var terminalSettings = TerminalPreferences.shared

    init(sessionID: String, browser: Browser, claimsKeys: @escaping () -> Bool = { true }) {
        self.sessionID = sessionID
        _browser = ObservedObject(wrappedValue: browser)
        self.claimsKeys = claimsKeys
    }

    func makeNSView(context: Context) -> NSView {
        let host = TerminalHost()
        host.wantsLayer = true
        // A native view is not clipped by SwiftUI: without this the shell
        // draws over the resize strip when the pane is made narrower.
        // Square corners: the tab's ground runs out to the edge of the shell,
        // and the padding around it is the only thing between the text and it.
        host.layer?.masksToBounds = true
        host.claimsKeys = claimsKeys
        let session = TabshTerminals.shared.terminal(for: sessionID)
        session.apply(dark: isDark(context), tint: browser.chromeTheme?.color)
        host.adopt(session.view)
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let host = view as? TerminalHost else { return }
        // The window can follow the page it is showing (see ChromeTheme): the
        // terminal takes the same ground and contrast.
        let terminal = TabshTerminals.shared.terminal(for: sessionID)
        terminal.apply(dark: isDark(context), tint: browser.chromeTheme?.color)
        // Back from a window it was taken out of (see TerminalHost.viewWillMove).
        host.adopt(terminal.view)
        host.claimsKeys = claimsKeys
        // The stage reuses the host as tabs come and go; the tab that has
        // just come back is the one the keys should reach. Only while this
        // pane is the page on show: the claim is made a turn of the run loop
        // later, and one made as a tab was being left reached the window
        // after the new tab's field had asked for the keys, and took them —
        // ⌘T left the caret in no field, with what was typed going to the
        // shell behind. Asked again when the claim lands, so a pane that has
        // gone in the meantime keeps its hands off.
        if claimsKeys(), let window = host.window, window.firstResponder !== terminal.view {
            DispatchQueue.main.async {
                guard host.claimsKeys(), terminal.view.window === window else { return }
                window.makeFirstResponder(terminal.view)
            }
        }
    }

    /// The pane is gone for good: the shell leaves the window with it, and
    /// TabshTerminals keeps the session itself for the tab's return.
    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        (host as? TerminalHost)?.terminal?.removeFromSuperview()
    }

    /// Dark when the page the window follows is dark, else the window's own
    /// appearance.
    private func isDark(_ context: Context) -> Bool {
        if let theme = browser.chromeTheme { return theme.dark }
        return context.environment.colorScheme == .dark
    }
}

/// The terminal's place in the stage. It takes the keys as soon as it is in a
/// window — a terminal you have to click into before it hears you is a
/// terminal that looks broken — and again on any click, as a page does. Drops
/// that land on the host (the padding around the shell) go to the same
/// handler the terminal view uses.
private final class TerminalHost: NSView {
    weak var terminal: NSView?
    /// Whether the keys belong here — asked afresh at each claim, see
    /// TabshTerminalView.claimsKeys.
    var claimsKeys: () -> Bool = { true }

    /// The shell in this pane: reparented here, or taken back if the pane was
    /// away from the window in between (see viewWillMove).
    func adopt(_ terminal: NSView) {
        self.terminal = terminal
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([
            .fileURL, .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.png"),
        ])
        guard claimsKeys(), let terminal, let window else { return }
        DispatchQueue.main.async { [weak self, weak window, weak terminal] in
            guard let self, self.claimsKeys(), let window, let terminal,
                  terminal.window === window else { return }
            window.makeFirstResponder(terminal)
        }
    }

    /// The pane has left the window, and the shell goes with it. The session
    /// is kept by TabshTerminals, so the tab comes back to the terminal it
    /// left — but a view kept in a window it is no longer part of would draw
    /// under whatever the stage shows next, and take what is typed there.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { terminal?.removeFromSuperview() }
    }

    override func mouseDown(with event: NSEvent) {
        if let terminal, let window { window.makeFirstResponder(terminal) }
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (terminal as? ChromeTerminalView)?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (terminal as? ChromeTerminalView)?.draggingUpdated(sender) ?? []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (terminal as? ChromeTerminalView)?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (terminal as? ChromeTerminalView)?.performDragOperation(sender) ?? false
    }
}
