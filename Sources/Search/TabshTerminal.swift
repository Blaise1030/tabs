import AppKit
import SwiftTerm
import SwiftUI

/// SwiftTerm's terminal, without the system scroller it puts down its edge:
/// the column is one surface, and a permanent thick bar was the loudest thing
/// in it. Scrolling still works; the knob is simply not drawn.
final class ChromeTerminalView: TerminalView {
    override func layout() {
        super.layout()
        for sub in subviews
        where sub is NSScroller || sub.identifier?.rawValue == "SwiftTermOverlayScrollerIndicator" {
            sub.isHidden = true
        }
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

@MainActor
final class TabshTerminal: NSObject, ObservableObject, TerminalViewDelegate {
    let sessionID: String
    let view: TerminalView
    @Published private(set) var exited = false

    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var retries = 0
    private var reconnect: DispatchWorkItem?

    init(sessionID: String) {
        self.sessionID = sessionID
        view = ChromeTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 520),
                                  font: TerminalPreferences.shared.font)
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = NSColor(srgbRed: 0.047, green: 0.047, blue: 0.047, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1)
        view.caretColor = NSColor(srgbRed: 0.55, green: 0.78, blue: 0.98, alpha: 1)
        connect()
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
        guard !stopped, let url = Tabsh.socketURL(for: sessionID) else { return }
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
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
            if !data.isEmpty { view.feed(byteArray: [UInt8](data)[...]) }
            retries = 0
        case let .string(text):
            if text.contains("\"exit\"") {
                exited = true
            } else if text.contains("\"restart\"") {
                // The daemon replaced the shell: attach to the new one.
                retry(now: true)
            }
            // {"stream":…} and {"bell":…} need nothing here.
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
        guard !data.isEmpty, let socket else { return }
        socket.send(.data(Data(data))) { _ in }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // The card's own name is the browser tab's; a shell's OSC title
        // changes too often to steal it.
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
    @ObservedObject private var terminalSettings = TerminalPreferences.shared

    init(sessionID: String, browser: Browser) {
        self.sessionID = sessionID
        _browser = ObservedObject(wrappedValue: browser)
    }

    func makeNSView(context: Context) -> NSView {
        let host = TerminalHost()
        host.wantsLayer = true
        // A native view is not clipped by SwiftUI: without this the shell
        // draws over the resize strip when the pane is made narrower.
        // Square corners: the tab's ground runs out to the edge of the shell,
        // and the padding around it is the only thing between the text and it.
        host.layer?.masksToBounds = true
        let session = TabshTerminals.shared.terminal(for: sessionID)
        let terminal = session.view
        host.terminal = terminal
        session.apply(dark: isDark(context), tint: browser.chromeTheme?.color)
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: host.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let host = view as? TerminalHost else { return }
        // The window can follow the page it is showing (see ChromeTheme): the
        // terminal takes the same ground and contrast.
        TabshTerminals.shared.terminal(for: sessionID)
            .apply(dark: isDark(context), tint: browser.chromeTheme?.color)
        // The stage reuses the host as tabs come and go; the tab that has
        // just come back is the one the keys should reach.
        if let terminal = host.terminal, let window = host.window,
           window.firstResponder !== terminal {
            DispatchQueue.main.async { window.makeFirstResponder(terminal) }
        }
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
/// terminal that looks broken — and again on any click, as a page does.
private final class TerminalHost: NSView {
    weak var terminal: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let terminal, let window else { return }
        DispatchQueue.main.async { [weak window, weak terminal] in
            guard let window, let terminal, terminal.window === window else { return }
            window.makeFirstResponder(terminal)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let terminal, let window { window.makeFirstResponder(terminal) }
        super.mouseDown(with: event)
    }
}
