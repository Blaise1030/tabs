import AppKit
import SwiftUI

/// Opens the sessions panel search from a menu or key — same idea as
/// `TabshExplorerActions.searchFiles` for the project column.
enum TabshSessionSearchActions {
    static let openName = Notification.Name("tabsh.sessions.search")

    static func open() {
        NotificationCenter.default.post(name: openName, object: nil)
    }
}

// The daemon's cards, kept in step with the browser's tabs. A card carries
// the title, status, note, folder and agent the board shows; its hooks move
// the status through `/api/board/events`, and the tab wears the same glyph.
// The agent's hooks move a card most of the time; the browser may move one
// too, from the session's menu, which writes the same user-sourced status
// change the board does.

enum TabshStatus: String, CaseIterable, Hashable {
    case backlog
    case inProgress = "in_progress"
    case needsInput = "needs_input"
    case completed
    case archived

    var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "In progress"
        case .needsInput: return "Needs input"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }

    var symbol: String {
        switch self {
        case .backlog: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .needsInput: return "questionmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox"
        }
    }

    var tint: Color {
        switch self {
        case .backlog, .archived: return Palette.faint
        case .inProgress: return Color(nsColor: .controlAccentColor)
        case .needsInput: return Palette.unsafe
        case .completed: return Palette.safe
        }
    }

    /// The mark inside the little badge on a tab's own icon. A card that is
    /// simply waiting there needs none, and one at work is a dot; only the
    /// states that want something from you carry a glyph.
    var badgeSymbol: String? {
        switch self {
        case .needsInput: return "questionmark"
        case .completed: return "checkmark"
        case .backlog, .inProgress, .archived: return nil
        }
    }
}

/// The session's state as a corner badge, so the tab keeps its real
/// terminal/agent icon rather than turning the whole mark into a status.
struct TabshStatusBadge: View {
    let status: TabshStatus
    var size: CGFloat = 9

    var body: some View {
        if status != .backlog, status != .archived {
            ZStack {
                Circle().fill(status.tint)
                if let symbol = status.badgeSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.58, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(Palette.ground, lineWidth: 1.5)
            )
            .help(status.title)
        }
    }
}

struct TabshStatusMark: View {
    let status: TabshStatus
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(status.tint)
            .frame(width: size + 2, height: size + 2)
            .help(status.title)
    }
}

/// The board's states as menu items, the one the card is in ticked. One list
/// for everywhere a status is changed by menu: the Sessions panel's row menu,
/// the terminal header's menu, and the floating button a terminal has instead
/// of one. (The chat header wears the select instead, see
/// `TabshHeaderStatusSelect`.)
struct TabshStatusMenuItems: View {
    let current: TabshStatus?
    let move: (TabshStatus) -> Void

    var body: some View {
        ForEach(TabshStatus.allCases, id: \.self) { status in
            Button(status == current ? "\(status.title) ✓" : status.title) {
                move(status)
            }
        }
    }
}

/// The card's state as a select, worn by the chat header: the state's mark
/// and name are the value, and the list under it names every state the board
/// knows, the current one ticked. A terminal header leaves it off — one card
/// should not say its state twice across the two panes, and the tab's badge
/// carries it either way.
struct TabshHeaderStatusSelect: View {
    let sessionID: String
    @ObservedObject private var sessions = TabshSessions.shared
    @State private var open = false

    var body: some View {
        if let info = sessions.info(for: sessionID) {
            let current = info.state
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: current.symbol)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(current.tint)
                    Text(current.title)
                        .foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.hover))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Change this card's status")
            .accessibilityLabel("Status")
            .accessibilityValue(current.title)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                TabshHeaderStatusList(current: current) { status in
                    sessions.move(sessionID, to: status)
                    open = false
                }
            }
        }
    }
}

/// The states the header's select offers, each with its own mark and name.
private struct TabshHeaderStatusList: View {
    let current: TabshStatus
    let choose: (TabshStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STATUS")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(TabshStatus.allCases, id: \.self) { status in
                Button { choose(status) } label: {
                    HStack(spacing: 8) {
                        TabshStatusMark(status: status, size: 10)
                        Text(status.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if status == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(status == current ? Palette.hover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 220)
    }
}

/// The bar above an agent session — chat or terminal — naming the card, with
/// the same move/delete menu on both. `title` is the card's own name (see
/// `Tabsh.SessionInfo.label`), so both surfaces say which card they are, not
/// just which agent runs it. `accessory` is for a header-only control: the
/// chat puts its status select there, and the terminal leaves it empty.
struct TabshSessionHeader<Accessory: View>: View {
    let sessionID: String
    let title: String
    @Binding var showingExplorer: Bool
    /// The status list in the trailing `…` menu. False where the header
    /// already wears the status select, so the same states aren't offered
    /// twice; a terminal header keeps them, having no select of its own.
    var statusInMenu = true
    @ViewBuilder var accessory: () -> Accessory

    @ObservedObject private var sessions = TabshSessions.shared

    private var info: Tabsh.SessionInfo? { sessions.info(for: sessionID) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let info, !info.meta.isEmpty {
                    Text(info.meta)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Shrink first so a long title never shoves the trailing
            // controls off the right edge (or leaves a gap past them).
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
            .help(info?.tooltip ?? title)

            // Explorer, status select and `…` — one trailing group, always
            // flush to the right of the bar.
            HStack(spacing: 8) {
                if !showingExplorer {
                    ExplorerShowButton { showingExplorer = true }
                }

                accessory()

                Menu {
                    // The status is changed here, with the same list as the
                    // board's row menu; the tab's own badge shows where it is.
                    if let info, statusInMenu {
                        TabshStatusMenuItems(current: info.state) {
                            sessions.move(sessionID, to: $0)
                        }
                        Divider()
                    }
                    Button("Delete Session", role: .destructive) {
                        sessions.delete(sessionID)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Session actions")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The agents' marks

/// The programs whose marks tabsh knows. The browser draws the same paths
/// the web app uses, so a tab wears Cursor's mark, Claude's, OpenAI's or
/// OpenCode's, not a generic prompt.
enum TabshAgentBrand: String {
    case claude, openai, gemini, cursor, opencode, agent

    var template: Bool {
        self == .openai || self == .cursor
    }

    /// The coordinate space `body` is drawn in. The marks taken from the web
    /// app are 24 points square; OpenCode's own is a 512-point glyph.
    var viewBox: String {
        self == .opencode ? "0 0 512 512" : "0 0 24 24"
    }

    /// The mark's SVG, as tabsh's web app draws it (and, for OpenCode, as
    /// opencode.ai draws its own).
    var body: String? {
        switch self {
        case .claude:
            return ##"<path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z" fill="#D97757"/>"##
        case .openai:
            return ##"<path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z" fill="#000000"/>"##
        case .gemini:
            return ##"<path d="M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81" fill="#4796E3"/>"##
        case .cursor:
            return ##"<path d="M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23" fill="#000000"/>"##
        case .opencode:
            // opencode.ai's mark: the black field, the white square, and the
            // conversation block below its title bar.
            return ##"<rect width="512" height="512" fill="#131010"/><path d="M320 224V352H192V224H320Z" fill="#5A5858"/><path fill-rule="evenodd" clip-rule="evenodd" d="M384 416H128V96H384V416ZM320 160H192V352H320V160Z" fill="#FFFFFF"/>"##
        case .agent:
            return nil
        }
    }
}

extension TabshAgentBrand {
    /// The brand's vector mark, for the tab and for a quick check that a
    /// path still loads.
    var image: NSImage? { TabshAgentMarks.image(for: self) }

    /// Which mark a provider or launch command wears. Name and command are
    /// both checked so "Cursor CLI" / `cursor-agent` and "OpenCode" /
    /// `opencode …` land on the same glyphs as session tabs.
    static func infer(name: String = "", command: String = "",
                      acp: String = "") -> TabshAgentBrand {
        let blob = [name, command, acp]
            .map { $0.lowercased() }
            .joined(separator: " ")
        if blob.contains("claude") { return .claude }
        if blob.contains("codex") || blob.contains("openai") || blob.contains("gpt") {
            return .openai
        }
        if blob.contains("gemini") { return .gemini }
        if blob.contains("opencode") { return .opencode }
        if blob.contains("cursor")
            || command.split(separator: " ").first.map(String.init)?.lowercased() == "agent"
            || command.split(separator: " ").first.map(String.init)?.lowercased() == "cursor-agent" {
            return .cursor
        }
        return .agent
    }
}

struct TabshAgentMark: View {
    let brand: TabshAgentBrand
    var size: CGFloat = 15
    var tint: Color = Palette.ink

    var body: some View {
        if let image = brand.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .renderingMode(brand.template ? .template : .original)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size - 3, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}

private enum TabshAgentMarks {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for brand: TabshAgentBrand) -> NSImage? {
        let key = brand.rawValue as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let body = brand.body else { return nil }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="\(brand.viewBox)">
        \(body)
        </svg>
        """
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        image.isTemplate = brand.template
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A card's mark without needing a tab: the agent's brand, or a terminal's
/// glyph, with the hook-driven state as its corner badge.
struct TabshSessionMark: View {
    let session: Tabsh.SessionInfo
    var size: CGFloat = 15
    var tint: Color = Palette.ink

    var body: some View {
        Group {
            if session.mode == "ui" {
                TabshAgentMark(brand: session.brand, size: size, tint: tint)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size - 4, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            TabshStatusBadge(status: session.state, size: max(7, size * 0.62))
                .offset(x: 3, y: 3)
        }
    }
}

/// A session tab's real mark: the terminal's own glyph, or the AI agent's
/// brand, with the hook-driven state as a small corner badge.
struct TabshTabMark: View {
    let tab: Tab
    let session: Tabsh.SessionInfo
    var size: CGFloat = 15
    var tint: Color = Palette.ink

    var body: some View {
        Group {
            if tab.page?.kind == .agent {
                TabshAgentMark(brand: session.brand, size: size, tint: tint)
            } else {
                Mark(icon: tab.icon, letter: tab.monogram, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            TabshStatusBadge(status: session.state, size: max(7, size * 0.62))
                .offset(x: 3, y: 3)
        }
    }
}

/// The words in a session's row: the card's title, the second line under it,
/// and the time since the hook moved it. The column's tab rows and the
/// Sessions panel both draw these, so a card reads the same in either list.
///
/// The title is passed in rather than taken here because a tab's row has
/// more to say than a card on its own: it can swap the title for the page's
/// address at rest (see TitleAtRest), which a card has no page for.
struct TabshRowTitle<Title: View>: View {
    let session: Tabsh.SessionInfo
    /// The row's title size: the column's own, `prefs.sideTitle`.
    let size: CGFloat
    let colour: Color
    @ViewBuilder var title: () -> Title

    var body: some View {
        if session.subtitle.isEmpty {
            title()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                title()
                // The card's own second line: the hook's note, or the
                // folder and agent that explain it.
                Text(session.subtitle)
                    .font(.system(size: max(8.5, size - 3)))
                    .foregroundStyle(colour.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// A card's time at the end of its row, as the board's list shows it.
struct TabshRowElapsed: View {
    let session: Tabsh.SessionInfo

    var body: some View {
        Text(session.elapsed)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Palette.faint)
    }
}

extension Tabsh.SessionInfo {
    var state: TabshStatus {
        TabshStatus(rawValue: status) ?? .backlog
    }

    /// How long the card has held this status: now, 5m, 3h, 2d.
    var elapsed: String {
        guard statusAt > 0 else { return "now" }
        let seconds = max(0, Int(Date().timeIntervalSince1970) - statusAt)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    var folder: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = cwd == home
            ? "~"
            : cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
        if short == "~" { return "~" }
        return (short as NSString).lastPathComponent
    }

    private var agentSource: String? {
        [agent, acp]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Whether an agent stands behind the card. The daemon makes a card for
    /// every shell, a plain terminal's included, but only an agent's card has
    /// a state to report: a terminal belongs in the tab list, not the
    /// Sessions panel.
    var hasAgent: Bool { agentSource != nil }

    var agentName: String? {
        guard let source = agentSource else { return nil }
        let lower = source.lowercased()
        if lower.contains("claude") { return "Claude Code" }
        if lower.contains("codex") { return "Codex" }
        if lower.contains("cursor") || lower.contains("agent") { return "Cursor CLI" }
        if lower.contains("opencode") { return "OpenCode" }
        if lower.contains("muse") { return "Muse" }
        return source.split(separator: " ").first.map(String.init)
    }

    /// The card's own name — the prompt's first line — as a tab and a panel
    /// header show it. A card the daemon has not named yet falls back to its
    /// agent, so the header is never blank.
    var label: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (agentName ?? "Agent") : name
    }

    /// The mark to put on the tab. The browser draws the real brand paths,
    /// not a generic prompt, for the agents whose marks tabsh knows.
    ///
    /// Only the commands say which agent runs the card. Its name is the
    /// prompt's first line, so a card called "Fix the agent panel" would
    /// otherwise read as Cursor's `agent` CLI.
    var brand: TabshAgentBrand {
        TabshAgentBrand.infer(command: agent ?? "", acp: acp ?? "")
    }

    /// The board row's second line: the hook's note when it left one, and
    /// otherwise the folder and agent that explain the card.
    var subtitle: String {
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return note
        }
        return [folder, agentName, elapsed]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The card without its status word: note, folder, agent, and the time
    /// since the hook moved it.
    var meta: String {
        [note, folder, agentName, elapsed]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Everything the row has room for, in one line: status, note, folder,
    /// agent and the time since the move.
    var detail: String {
        [state.title, note, folder, agentName, elapsed]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var tooltip: String {
        var lines = [state.title]
        if let note, !note.isEmpty { lines.append(note) }
        if !folder.isEmpty { lines.append("Folder: \(folder)") }
        if let agentName { lines.append("Agent: \(agentName)") }
        lines.append(elapsed == "now" ? "Updated now" : "Updated \(elapsed) ago")
        lines.append("Session: \(id)")
        return lines.joined(separator: "\n")
    }

    /// Whether the sessions panel's search keeps this card: the needle
    /// against its name, note, folder, agent and status.
    func matches(_ needle: String) -> Bool {
        let q = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let hay = [name, note, folder, agentName, state.title, cwd]
            .compactMap { $0 }
            .joined(separator: "\n")
        return hay.localizedCaseInsensitiveContains(q)
    }
}

// MARK: - The panel

/// The cards as the board groups them: a column at the foot of the sidebar,
/// resizable from its top edge and folded from the column's foot (see
/// SideFoot). Each row is the card's status, name, hook note, folder, agent
/// and time; a click goes to the session's tab, opening it if it isn't there.
struct TabshStatusPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sessions = TabshSessions.shared
    /// The same row sizes the column's tabs use, so a card is the same height
    /// and its title the same size in both lists.
    @ObservedObject private var prefs = Shared.prefs

    @AppStorage("tabsh.status.height") private var storedHeight: Double = 220
    /// Whether the handle has ever been pulled. Until it has, the panel is
    /// only as tall as its cards; after, its height is exactly what was left
    /// at the handle, even with room to spare under the last card.
    @AppStorage("tabsh.status.byhand") private var byHand = false
    @AppStorage("tabsh.status.collapsed") private var collapsed = false
    /// The folded statuses, as raw values. Kept in defaults so the next
    /// launch opens on the same groups the last one closed.
    @AppStorage("tabsh.status.folded") private var foldedStorage = "completed,archived"
    @State private var resizing: CGFloat?
    @State private var onHandle = false
    @State private var hoveredGroup: TabshStatus?
    /// The status a dragged session is hovering over, so its heading lights
    /// up the way a browser tab group does while a drop is aimed at it.
    @State private var dropTarget: TabshStatus?
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.greys) private var greys
    @State private var hovered: String?
    /// The measured height of the groups and rows, so a short list does not
    /// leave the panel taller than its content.
    @State private var contentHeight: CGFloat = 0
    /// The panel's own search: the magnifying glass under the handle opens it.
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let handleHeight: CGFloat = 7
    private static let minimum: CGFloat = 120
    private static let maximum: CGFloat = 520
    /// Height the open field takes in the stack, so the list is pushed down.
    private static let searchBarHeight: CGFloat = 36
    /// Drag payload for a session row: `tabsh-session:<id>`, so a drop on a
    /// status heading (or another row under it) can move the card.
    private static let dragPrefix = "tabsh-session:"

    private var folded: Set<TabshStatus> {
        Set(foldedStorage
            .split(separator: ",")
            .compactMap { TabshStatus(rawValue: String($0)) })
    }

    private var cards: [Tabsh.SessionInfo] {
        let all = Self.listed(Array(sessions.sessions.values))
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.matches(needle) }
    }

    /// The cards the panel lists: agent sessions only. A plain terminal is a
    /// card on the daemon too (every shell is one), but it has no agent to
    /// report a status, so it is just a tab — not a session row here. Side
    /// terminals are left out as well: they belong to their card's row.
    static func listed(_ all: [Tabsh.SessionInfo]) -> [Tabsh.SessionInfo] {
        all.filter { $0.parent == nil && $0.hasAgent }
    }

    private var ground: Color {
        browser.asCards ? Palette.frame : Palette.ground
    }

    /// How tall the panel is, given what it holds. Before the handle has
    /// been pulled, the panel fits its cards (as tall as they need, up to
    /// the height last left). Once it has been pulled, the height is the
    /// handle's own, even when the cards are shorter: the edge between the
    /// tab list and the sessions is the person's to place, and a short list
    /// must not nail it shut. See `panelHeight`.
    private var expandedHeight: CGFloat {
        // The closed icon is absolute and takes no height; the open field
        // sits in the stack and pushes the list down.
        let search = searching ? Self.searchBarHeight : 0
        return Self.panelHeight(stored: storedHeight, byHand: byHand,
                                content: contentHeight + search)
    }

    /// The panel's height. `byHand` is the one thing the numbers can't say:
    /// a fit to content and a pulled height can be equal, and the next pull
    /// must move either way from the same place.
    static func panelHeight(stored: Double, byHand: Bool, content: CGFloat) -> CGFloat {
        guard byHand else {
            let needed = handleHeight + content
            return min(CGFloat(stored), max(handleHeight, needed))
        }
        return min(maximum, max(minimum, CGFloat(stored)))
    }

    private var scrollable: Bool {
        contentHeight + Self.handleHeight > storedHeight + 0.5
    }

    private var grouped: [TabshStatus: [Tabsh.SessionInfo]] {
        Dictionary(grouping: cards, by: \.state)
            .mapValues { $0.sorted { $0.statusAt > $1.statusAt } }
    }

    var body: some View {
        // No heading of its own: the cards start at the handle, and the
        // column's foot carries the one chevron that folds them away (see
        // SideFoot), so the list has the whole panel to itself.
        // Keep the panel while a search is open even if every card is
        // filtered out, so the field can be cleared without the panel
        // vanishing under the pointer.
        // Group + onReceive stay mounted even while collapsed / empty, so a
        // key can open search without the magnifying glass being on screen.
        let all = Self.listed(Array(sessions.sessions.values))
        Group {
            if (all.isEmpty && !searching) || collapsed {
                EmptyView()
            } else {
                VStack(spacing: 0) {
                    handle
                    // Open field in the stack (slides in, pushes the list);
                    // closed icon stays absolute over the list's top trailing.
                    if searching {
                        searchBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    content
                        .overlay(alignment: .topTrailing) {
                            if !searching {
                                searchToggle
                                    .transition(.opacity)
                            }
                        }
                }
                .animation(Motion.settle, value: searching)
                .frame(height: expandedHeight, alignment: .top)
                .frame(maxWidth: .infinity)
                // The column's own ground, not a white card on it: the sessions
                // panel is part of the sidebar, so it takes the same colour as
                // everything around it.
                .background(ground)
                .clipped()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TabshSessionSearchActions.openName)) { _ in
            withAnimation(Motion.settle) {
                collapsed = false
                searching = true
            }
            // After the field is in the tree — same timing as the glass button.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    /// The handle under the hand: the same little pill the column and the
    /// explorer use, laid on its side — as thick as that handle's edge, and
    /// longer and brighter while it is hovered or pulled.
    private var litHandle: Bool { onHandle || resizing != nil }

    /// The top edge: seven points to take hold of, with only the handle
    /// drawn — no hairline across the column.
    private var handle: some View {
        ZStack {
            Capsule()
                .fill(litHandle ? Palette.muted : Palette.faint)
                .frame(width: litHandle ? 36 : 24, height: Grip.width)
                .animation(Motion.quick, value: litHandle)
        }
        .frame(height: Self.handleHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { over in
            onHandle = over
            if over { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    // The first pull starts from what is on screen, then the
                    // height is the handle's own from here on.
                    if resizing == nil {
                        resizing = expandedHeight
                        byHand = true
                    }
                    if collapsed { collapsed = false }
                    let base = resizing ?? CGFloat(storedHeight)
                    storedHeight = Double(min(Self.maximum, max(Self.minimum,
                                                             base - value.translation.height)))
                }
                .onEnded { _ in resizing = nil }
        )
        // A double-click puts the panel back to fitting its cards, as the
        // tab column's edge does with the column's width.
        .modifier(OneClick(double: true) {
            withAnimation(Motion.quick) { byHand = false }
        })
        .animation(Motion.quick, value: onHandle)
        .animation(Motion.quick, value: litHandle)
    }

    /// The magnifying glass overlaid on the list (top trailing), so a
    /// closed search takes no row under the grip.
    private var searchToggle: some View {
        Button {
            withAnimation(Motion.settle) { searching = true }
            // After the field is in the tree — setting focus in the
            // same turn as `searching = true` misses it.
            DispatchQueue.main.async { searchFocused = true }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(!query.isEmpty ? Palette.ink : Palette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search sessions")
        .accessibilityLabel("Search sessions")
        .padding(.top, 4)
        .padding(.trailing, 4)
    }

    /// The field the magnifying glass opens: slides in under the grip and
    /// takes a row, pushing the groups down. Same muted capsule as the
    /// explorer's search.
    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.muted)
            TextField("Search sessions…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            Button {
                withAnimation(Motion.settle) {
                    query = ""
                    searching = false
                    searchFocused = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
            .buttonStyle(.plain)
            .help("Close session search")
            .accessibilityLabel("Close session search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.hover)
        )
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var content: some View {
        GeometryReader { outer in
            ScrollView(.vertical) {
            // Not lazy: the panel measures this stack to stop at its last
            // group, and a lazily-built stack reports a height that grows
            // with the scroll rather than the list.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(TabshStatus.allCases, id: \.self) { status in
                    let list = grouped[status] ?? []
                    // A search that found nothing in this column skips it;
                    // otherwise every status stays, empty counts included.
                    if list.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        EmptyView()
                    } else {
                        statusGroup(status, list: list)
                    }
                }
            }
            .padding(.horizontal, 4)
            // A little air under the last group; the panel itself stops
            // there when the list is shorter than its chosen height.
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                contentHeight = $0
            }
            .background {
                GeometryReader { inner in
                    Color.clear.preference(key: SessionsScrollKey.self,
                                           value: inner.frame(in: .named("sessionsScroll")).minY)
                }
            }
            }
            .coordinateSpace(name: "sessionsScroll")
            .onPreferenceChange(SessionsScrollKey.self) { scrollOffset = $0 }
            .scrollIndicators(.never)
            .overlay {
                if scrollable {
                    ScrollFade(background: ground, height: 16,
                               showTop: scrollOffset < -0.5,
                               showBottom: scrollOffset + contentHeight > outer.size.height + 0.5)
                }
            }
        }
    }

    /// One status column: its heading and the rows under it. The whole
    /// block takes a dragged session so a drop on the heading or on a peer
    /// row moves the card here — the same change the row's Move to menu
    /// writes.
    @ViewBuilder
    private func statusGroup(_ status: TabshStatus, list: [Tabsh.SessionInfo]) -> some View {
        let open = !folded.contains(status)
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 2) {
            groupHeading(status, count: list.count)
            if open {
                ForEach(list) { session in
                    row(session)
                }
            }
        }
        .padding(.bottom, dropTarget == status ? 2 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dropTarget == status ? greys.hover.opacity(0.85) : .clear)
        )
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTarget == status },
            set: { dropTarget = $0 ? status : (dropTarget == status ? nil : dropTarget) }
        )) { providers in
            acceptSessionDrop(providers, onto: status)
        }
    }

    /// A status heading, drawn like the browser's own tab group headings:
    /// the name in the column's grey at 12.5, a fold chevron at the trailing
    /// edge, and the fill only under the pointer.
    private func groupHeading(_ status: TabshStatus, count: Int) -> some View {
        let lit = hoveredGroup == status || dropTarget == status
        return Button {
            withAnimation(Motion.quick) {
                var next = folded
                if next.contains(status) { next.remove(status) }
                else { next.insert(status) }
                foldedStorage = next.map(\.rawValue).sorted().joined(separator: ",")
            }
        } label: {
            HStack(spacing: 8) {
                TabshStatusMark(status: status, size: 9)
                Text(status.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(folded.contains(status) ? -90 : 0))
                    .opacity(lit || folded.contains(status) ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(lit ? greys.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over { hoveredGroup = status }
            else if hoveredGroup == status { hoveredGroup = nil }
        }
    }

    /// A session drag onto a status group: move the card, and open a folded
    /// group so the row is visible where it landed.
    private func acceptSessionDrop(_ providers: [NSItemProvider], onto status: TabshStatus) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) })
        else { return false }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value, value.hasPrefix(Self.dragPrefix) else { return }
            let id = String(value.dropFirst(Self.dragPrefix.count))
            guard !id.isEmpty else { return }
            DispatchQueue.main.async {
                sessions.move(id, to: status)
                if folded.contains(status) {
                    withAnimation(Motion.quick) {
                        var next = folded
                        next.remove(status)
                        foldedStorage = next.map(\.rawValue).sorted().joined(separator: ",")
                    }
                }
                dropTarget = nil
            }
        }
        return true
    }

    /// The browser tab a session already stands for, when one is open: a
    /// session is a tab of this window, not a second thing beside it.
    private func openTab(_ session: Tabsh.SessionInfo) -> Tab? {
        let kind: InternalPage.Kind = session.mode == "ui" ? .agent : .tabsh
        return (browser.tabs + browser.parkedTabs).first {
            $0.page?.kind == kind && $0.page?.detail == session.id
        }
    }

    private func row(_ session: Tabsh.SessionInfo) -> some View {
        let open = openTab(session)
        let selected = open.map { $0.id == browser.activeID } ?? false
        let hovering = hovered == session.id
        // The same words, in the same size and colour, as the tab's row in
        // the column above (see SideRow): a card is the same thing in both
        // lists, not a second rendering of it. The title is the tab's when
        // one is open, so the two never disagree about what a session is
        // called; an unopened card has only its name.
        let colour: Color = selected ? Palette.ink
            : hovering ? Palette.ink.opacity(0.7) : Palette.muted
        let size = prefs.sideTitle
        return Button {
            if let open {
                browser.select(open)
            } else {
                let kind: InternalPage.Kind = session.mode == "ui" ? .agent : .tabsh
                browser.show(InternalPage(kind, session.id))
            }
        } label: {
            HStack(spacing: 8) {
                if let open {
                    TabshTabMark(tab: open, session: session,
                                 size: prefs.roomyTabs ? 17 : 15, tint: colour)
                } else {
                    TabshSessionMark(session: session,
                                     size: prefs.roomyTabs ? 17 : 15, tint: colour)
                }

                TabshRowTitle(session: session, size: size, colour: colour) {
                    Text(open?.label ?? session.name)
                        .font(.system(size: size))
                        .foregroundStyle(colour)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                TabshRowElapsed(session: session)
                    .opacity(hovering ? 0 : 1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .frame(height: prefs.sessionRow)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? greys.hover : selected ? greys.wash : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        // Under a status heading, a session sits in by as much as a browser
        // group's tabs do in the column, rather than starting at the
        // heading's edge.
        .padding(.leading, 14)
        .overlay(alignment: .trailing) {
            if hovering, let open {
                Button { browser.close(open) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 15, height: 15)
                        .background(Palette.ink.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help("Close \(session.name)")
            }
        }
        .contextMenu {
            if let open {
                Button("Show Tab") { browser.select(open) }
                Button("Close Tab") { browser.close(open) }
            } else {
                Button("Open in a Tab") {
                    let kind: InternalPage.Kind = session.mode == "ui" ? .agent : .tabsh
                    browser.show(InternalPage(kind, session.id))
                }
            }
            Divider()
            Menu("Move to") {
                TabshStatusMenuItems(current: session.state) {
                    sessions.move(session.id, to: $0)
                }
            }
            Divider()
            // Closes the shell or agent on the daemon — not only the tab.
            Button("Delete Session", role: .destructive) {
                sessions.delete(session.id)
            }
        }
        .onDrag {
            NSItemProvider(object: "\(Self.dragPrefix)\(session.id)" as NSString)
        }
        .onHover { over in
            if over { hovered = session.id }
            else if hovered == session.id { hovered = nil }
        }
        .help(session.tooltip)
    }
}

private struct SessionsScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
final class TabshSessions: ObservableObject {
    static let shared = TabshSessions()

    @Published private(set) var sessions: [String: Tabsh.SessionInfo] = [:]

    private var socket: URLSessionWebSocketTask?
    private var reloadTask: Task<Void, Never>?
    private var retry: DispatchWorkItem?
    private var started = false
    private var stopped = false

    /// Move a card, as the board's menu does. The daemon is told with the same
    /// user-sourced change; the panel and the tab update at once, the socket
    /// confirms.
    func move(_ id: String, to status: TabshStatus) {
        guard var session = sessions[id], session.status != status.rawValue else { return }
        session.status = status.rawValue
        session.statusAt = Int(Date().timeIntervalSince1970)
        sessions[id] = session
        Task { try? await Tabsh.setStatus(id, status.rawValue) }
    }

    /// Delete a card for good: the shell or agent is killed on the daemon,
    /// any open tab for it closes, and the Sessions list drops it. Closing
    /// a tab alone leaves the card running — this is the other way.
    func delete(_ id: String) {
        guard sessions[id] != nil else { return }
        sessions.removeValue(forKey: id)
        forgetLocal(id)
        for browser in Browsers.all {
            for tab in browser.tabs + browser.parkedTabs {
                guard tab.tabshSessionID == id else { continue }
                browser.close(tab)
            }
        }
        Task {
            do {
                try await Tabsh.deleteSession(id)
            } catch {
                // The daemon kept it: put the list back so the panel and any
                // restored tab match what is still there.
                refresh()
            }
        }
    }

    /// Local pieces that outlive a closed tab — sockets, drafts — so a
    /// deleted card does not leave them hanging for a session that is gone.
    private func forgetLocal(_ id: String) {
        TabshTerminals.shared.close(id)
        TabshChats.shared.close(id)
        TabshDrafts.shared.set("", for: id)
    }

    /// At launch: read the cards already on the daemon, then follow the
    /// board's socket so a hook's move reaches the tabs without a reload.
    func start() {
        guard !started else { return }
        started = true
        // Ask while the app is coming up, not mid-turn: the first Needs
        // input banner used to race the permission prompt and vanish.
        if Shared.prefs.agentNotifyNeeds || Shared.prefs.agentNotifyDone {
            AgentNotify.ask()
        }
        refresh()
        connect()
    }

    func stop() {
        stopped = true
        reloadTask?.cancel()
        retry?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func refresh() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let list = try? await Tabsh.boardSessions() else { return }
            self.sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            self.updateTabs()
            self.closeOrphans()
        }
    }

    /// A session tab whose card is not on this browser's daemon can never
    /// attach: its terminal would sit empty with nothing to say why. That is
    /// a tab restored from another tabsh's board (the browser's state is its
    /// own now; see TabshDaemon) or one whose card was deleted while the tab
    /// was closed. Only a list that actually came back is trusted — a daemon
    /// still starting must not take every session tab with it.
    private func closeOrphans() {
        for browser in Browsers.all {
            // A copy: closing mutates the arrays this walks.
            for tab in browser.tabs + browser.parkedTabs {
                guard let id = tab.tabshSessionID, sessions[id] == nil else { continue }
                browser.close(tab)
            }
        }
    }

    func info(for session: String) -> Tabsh.SessionInfo? {
        sessions[session]
    }

    /// A tab just became a session tab, or was restored as one. It wears
    /// what is already known; an unknown session asks for the list again.
    func attach(_ tab: Tab) {
        guard let id = tab.tabshSessionID else { return }
        if let info = sessions[id] {
            tab.adopt(tabsh: info)
        } else {
            refresh()
        }
    }

    private func updateTabs() {
        for browser in Browsers.all {
            for tab in browser.tabs + browser.parkedTabs {
                guard let id = tab.tabshSessionID else { continue }
                tab.adopt(tabsh: sessions[id])
            }
        }
    }

    private func connect() {
        guard !stopped, let request = Tabsh.boardEventsRequest() else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        // The daemon may have come up after the launch read: a connection
        // is a good moment to ask for the list again.
        refresh()
        receive()
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
                    self.socket = nil
                    self.retry?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.started, !self.stopped else { return }
                        self.connect()
                    }
                    self.retry = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .data(bytes):
            data = bytes
        case let .string(text):
            data = Data(text.utf8)
        @unknown default:
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // The socket was behind: ask for the whole list, as the web app does.
        if object["resync"] as? Bool == true {
            refresh()
            return
        }

        // Activity events name a terminal under `session`; a title it reports
        // is the shell's or ACP agent's own, so the tab and chat header follow
        // it as the web app does — but only when the card is unpinned, so a
        // name the user chose stays put.
        if let session = object["session"] as? String,
           let title = object["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           var info = sessions[session],
           !info.pinned {
            info.name = title
            sessions[session] = info
            updateTabs()
        }

        // Card changes have `id` and `status`; activity events have neither.
        guard let id = object["id"] as? String,
              let status = object["status"] as? String else { return }

        let statusAt = object["status_at"] as? Int ?? 0
        let note = object["note"] as? String
        let source = object["source"] as? String
        if var info = sessions[id] {
            let was = info.status
            info.status = status
            info.statusAt = statusAt
            info.note = note
            sessions[id] = info
            updateTabs()
            // A hook's or the agent's own move is news; a move made here, or
            // on the board, is not (see AgentNotify).
            if source == "hook", was != status {
                AgentNotify.moved(info, to: info.state)
            }
        } else {
            // A card this window hasn't seen yet: read the list once.
            refresh()
        }
    }
}
