import AppKit
import SwiftUI

// Tabs' own pages — Settings, History, Downloads, Bookmarks, Passwords,
// Bring Things Over and the release notes — each in a tab of its own, as
// chrome://settings is in Chrome, rather than a card over the page. A tab
// is something you can leave open beside your work, come back to with ⌃Tab,
// put beside a page in Split View, and close with ⌘W like any other.
//
// One tab of each kind per window: asking again goes to the one already
// open. Each has an address of its own, search://settings/privacy, which
// the field shows, the session keeps, and code can open directly. Nothing
// about them reaches WebKit: the tab holds no web view while it shows one.

/// Which of Tabs' own pages, and where inside it.
struct InternalPage: Equatable {
    enum Kind: String, CaseIterable {
        case settings, history, downloads, bookmarks, passwords
        case importing = "import"
        case notes = "release-notes"
        case editor
        case tabsh
        case preview
        case agent
        // Kebab host so restore (which lowercases the host) still matches —
        // camelCase `agentComposer` used to round-trip as a blank web tab.
        case agentComposer = "agent-composer"

        /// Hosts that open this kind, including legacy spellings sessions
        /// may still carry after a restart.
        static func matching(host: String) -> Kind? {
            if let kind = Kind.allCases.first(where: { $0.rawValue.lowercased() == host }) {
                return kind
            }
            // Pre-fix sessions wrote `search://agentComposer`.
            if host == "agentcomposer" { return .agentComposer }
            return nil
        }
    }

    var kind: Kind
    /// Settings' section, or the browser Bring Things Over starts at.
    var detail: String?

    init(_ kind: Kind, _ detail: String? = nil) {
        self.kind = kind
        self.detail = detail?.isEmpty == true ? nil : detail
    }

    static let scheme = "search"

    /// search://settings, search://settings/privacy, search://import/Arc.
    /// Host matching is case-insensitive, and `agentComposer` (the old
    /// camelCase raw value) still opens New Agent after a restart.
    init?(url: URL) {
        guard url.scheme?.lowercased() == InternalPage.scheme,
              let host = url.host()?.lowercased(),
              let kind = Kind.matching(host: host)
        else { return nil }
        let rest = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(kind, rest)
    }

    var url: URL {
        var text = "\(InternalPage.scheme)://\(kind.rawValue)"
        if let detail, let path = detail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            text += "/" + path
        }
        return URL(string: text) ?? URL(string: "\(InternalPage.scheme)://\(kind.rawValue)")!
    }

    var title: String {
        switch kind {
        case .settings: return "Settings"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .bookmarks: return "Bookmarks"
        case .passwords: return "Passwords"
        case .importing: return "Bring Things Over"
        case .notes: return "What's New"
        case .editor:
            // The file's own name, read off the path the address carries.
            guard let detail, !detail.isEmpty else { return "Editor" }
            return (detail as NSString).lastPathComponent
        case .tabsh:
            return "Terminal"
        case .agent:
            return "Agent"
        case .preview:
            guard let detail, !detail.isEmpty else { return "Preview" }
            return (detail as NSString).lastPathComponent
        case .agentComposer:
            return "New Agent"
        }
    }

    var symbol: String {
        switch kind {
        case .settings: return "gearshape"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .bookmarks: return "book"
        case .passwords: return "key"
        case .importing: return "square.and.arrow.down"
        case .notes: return "sparkles"
        case .editor: return "curlybraces"
        case .tabsh: return "terminal"
        case .agent: return "bubble.left.and.bubble.right"
        case .preview: return "eye"
        case .agentComposer: return "sparkles"
        }
    }

    /// The tab's icon: the symbol, drawn as a template so it takes the
    /// colour of the row it sits in (see Mark).
    var glyph: NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image?.isTemplate = true
        return image
    }
}

private struct AsTabKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when a panel is drawn as a page in a tab of its own rather than
    /// as a card over the page: the plate gives up its card, its shadow and
    /// its cross, and its lists take the height the window gives them.
    var asTab: Bool {
        get { self[AsTabKey.self] }
        set { self[AsTabKey.self] = newValue }
    }
}

/// A list's height: capped on a card, as tall as the window in a tab.
private struct ListHeight: ViewModifier {
    @Environment(\.asTab) private var asTab
    let cap: CGFloat

    func body(content: Content) -> some View {
        if asTab {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(maxHeight: cap)
        }
    }
}

extension View {
    func listHeight(_ cap: CGFloat) -> some View { modifier(ListHeight(cap: cap)) }
}

/// One of Tabs' own pages, where a web page would be: on the stage, on
/// its card when pages are cards, in either pane of a pair.
struct InternalPageView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let page: InternalPage
    var corner: CGFloat = 0

    var body: some View {
        content
            .environment(\.asTab, true)
            // Its own state for each kind: History's search box doesn't
            // follow you into Downloads.
            .id(page.kind)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // In a pair, a click on this page makes it the one with the keys,
            // as a click on a web page does (see PageView.onKeys).
            .simultaneousGesture(TapGesture().onEnded {
                if browser.activeID != tab.id, browser.split(for: tab) != nil { browser.focusPane(tab) }
            })
            .transition(.opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch page.kind {
        case .settings:
            SettingsPanel(browser: browser, prefs: browser.prefs, asked: page.detail)
        case .history:
            HistoryPanel(browser: browser)
        case .downloads:
            DownloadsPanel(browser: browser, loot: browser.loot)
        case .bookmarks:
            BookmarksPanel(browser: browser, bookmarks: browser.bookmarks)
        case .passwords:
            // The list is read each time the page is drawn, whichever way it
            // came: brought back from the last session, Settings › Passwords ›
            // Open… turning the Settings tab into it, Back or Forward. Here,
            // under `.id(page.kind)`, and not on the view around it, which a
            // tab going from one of these pages to another keeps: there it
            // ran once, and the page reached from Settings said "Nothing kept
            // yet" while the sign-in box offered the accounts.
            PasswordsPanel(browser: browser)
                .onAppear { browser.relist() }
        case .importing:
            ImportPanel(browser: browser)
        case .notes:
            ReleaseNotesPanel { browser.putAway(.notes) }
        case .editor:
            EditorPanel(path: page.detail ?? "")
        case .tabsh:
            TabshTerminalPane(sessionID: page.detail ?? "", tab: tab, browser: browser)
        case .agent:
            TabshAgentPane(sessionID: page.detail ?? "", browser: browser)
                .id(page.detail)
        case .preview:
            PreviewPanel(path: page.detail ?? "", browser: browser)
        case .agentComposer:
            AgentComposer(browser: browser)
        }
    }
}
