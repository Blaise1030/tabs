import AppKit
import SwiftUI

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

// MARK: - The agents' marks

/// The programs whose marks tabsh knows. The browser draws the same paths
/// the web app uses, so a tab wears Cursor's mark, Claude's or OpenAI's, not
/// a generic prompt.
enum TabshAgentBrand: String {
    case claude, openai, gemini, cursor, agent

    var template: Bool {
        self == .openai || self == .cursor
    }

    var fill: String {
        switch self {
        case .claude: return "#D97757"
        case .gemini: return "#4796E3"
        case .openai, .cursor, .agent: return "#000000"
        }
    }

    var path: String? {
        switch self {
        case .claude:
            return #"m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"#
        case .openai:
            return #"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"#
        case .gemini:
            return #"M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"#
        case .cursor:
            return #"M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"#
        case .agent:
            return nil
        }
    }
}

extension TabshAgentBrand {
    /// The brand's vector mark, for the tab and for a quick check that a
    /// path still loads.
    var image: NSImage? { TabshAgentMarks.image(for: self) }
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
        guard let path = brand.path else { return nil }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 24 24">
        <path d="\(path)" fill="\(brand.fill)"/>
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

    /// The mark to put on the tab. The browser draws the real brand paths,
    /// not a generic prompt, for the agents whose marks tabsh knows.
    var brand: TabshAgentBrand {
        let source = [agent, acp, name]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if source.contains("claude") { return .claude }
        if source.contains("codex") || source.contains("openai") || source.contains("gpt") {
            return .openai
        }
        if source.contains("gemini") { return .gemini }
        if source.contains("cursor") || source.contains("agent") { return .cursor }
        return .agent
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
}

// MARK: - The panel

/// The cards as the board groups them: a column at the foot of the sidebar,
/// resizable from its top edge and foldable to its heading. Each row is the
/// card's status, name, hook note, folder, agent and time; a click goes to
/// the session's tab, opening it if it isn't there.
struct TabshStatusPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sessions = TabshSessions.shared

    @AppStorage("tabsh.status.height") private var storedHeight: Double = 220
    @AppStorage("tabsh.status.collapsed") private var collapsed = false
    /// The folded statuses, as raw values. Kept in defaults so the next
    /// launch opens on the same groups the last one closed.
    @AppStorage("tabsh.status.folded") private var foldedStorage = "completed,archived"
    @State private var resizing: CGFloat?
    @State private var onHandle = false
    @State private var hoveredGroup: TabshStatus?
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.greys) private var greys
    @State private var hovered: String?
    /// The measured height of the groups and rows, so a short list does not
    /// leave the panel taller than its content.
    @State private var contentHeight: CGFloat = 0

    private static let headerHeight: CGFloat = 36
    private static let handleHeight: CGFloat = 7
    private static let minimum: CGFloat = 120
    private static let maximum: CGFloat = 520

    private var folded: Set<TabshStatus> {
        Set(foldedStorage
            .split(separator: ",")
            .compactMap { TabshStatus(rawValue: String($0)) })
    }

    private var cards: [Tabsh.SessionInfo] {
        sessions.sessions.values.filter { $0.parent == nil }
    }

    private var ground: Color {
        browser.asCards ? Palette.frame : Palette.ground
    }

    /// As tall as the cards need, up to the height the handle was left at.
    private var expandedHeight: CGFloat {
        let settled = Self.handleHeight + Self.headerHeight + contentHeight
        return min(storedHeight, max(Self.handleHeight + Self.headerHeight, settled))
    }

    private var scrollable: Bool {
        contentHeight + Self.handleHeight + Self.headerHeight > storedHeight + 0.5
    }

    private var grouped: [TabshStatus: [Tabsh.SessionInfo]] {
        Dictionary(grouping: cards, by: \.state)
            .mapValues { $0.sorted { $0.statusAt > $1.statusAt } }
    }

    var body: some View {
        if cards.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                handle
                heading
                if !collapsed { content }
            }
            .frame(height: collapsed ? Self.headerHeight + Self.handleHeight : expandedHeight,
                   alignment: .top)
            .frame(maxWidth: .infinity)
            // The column's own ground, not a white card on it: the sessions
            // panel is part of the sidebar, so it takes the same colour as
            // everything around it.
            .background(ground)
            .clipped()
            .animation(Motion.quick, value: collapsed)
        }
    }

    /// The handle under the hand: the same little pill the column and the
    /// explorer use, laid on its side — longer and brighter while it is
    /// hovered or pulled.
    private var litHandle: Bool { onHandle || resizing != nil }

    /// The top edge: seven points to take hold of, with only the handle
    /// drawn — no hairline across the column.
    private var handle: some View {
        ZStack {
            Capsule()
                .fill(litHandle ? Palette.muted : Palette.faint)
                .frame(width: litHandle ? 36 : 24, height: litHandle ? 3 : 2)
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
                    if resizing == nil { resizing = storedHeight }
                    if collapsed { collapsed = false }
                    let base = resizing ?? storedHeight
                    storedHeight = min(Self.maximum, max(Self.minimum,
                                                      base - value.translation.height))
                }
                .onEnded { _ in resizing = nil }
        )
        .animation(Motion.quick, value: onHandle)
        .animation(Motion.quick, value: litHandle)
    }

    private var heading: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text("Sessions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("\(cards.count)")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 6)
            Button {
                withAnimation(Motion.quick) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show sessions" : "Hide sessions")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
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
                    groupHeading(status, count: list.count)
                    if !folded.contains(status) {
                        ForEach(list) { session in
                            row(session)
                        }
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

    /// A status heading, drawn like the browser's own tab group headings:
    /// the name in the column's grey at 12.5, a fold chevron at the trailing
    /// edge, and the fill only under the pointer.
    private func groupHeading(_ status: TabshStatus, count: Int) -> some View {
        Button {
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
                    .opacity(hoveredGroup == status || folded.contains(status) ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hoveredGroup == status ? greys.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over { hoveredGroup = status }
            else if hoveredGroup == status { hoveredGroup = nil }
        }
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
        return Button {
            if let open {
                browser.select(open)
            } else {
                let kind: InternalPage.Kind = session.mode == "ui" ? .agent : .tabsh
                browser.show(InternalPage(kind, session.id))
            }
        } label: {
            HStack(spacing: 8) {
                TabshSessionMark(session: session,
                                 size: 15,
                                 tint: hovering ? Palette.ink : Palette.ink.opacity(0.9))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(session.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if !hovering {
                            Text(session.elapsed)
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.faint)
                                .fixedSize()
                        }
                    }

                    if let note = session.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 14)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? greys.hover : selected ? greys.wash : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        // Under a status heading, a session sits in as a browser group's
        // tabs do, rather than starting at the heading's edge.
        .padding(.leading, 16)
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
                ForEach(TabshStatus.allCases, id: \.self) { status in
                    Button(status == session.state ? "\(status.title) ✓" : status.title) {
                        sessions.move(session.id, to: status)
                    }
                }
            }
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

    /// At launch: read the cards already on the daemon, then follow the
    /// board's socket so a hook's move reaches the tabs without a reload.
    func start() {
        guard !started else { return }
        started = true
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
        // is the shell's or agent's own, so the tab follows it as the web
        // app does.
        if let session = object["session"] as? String,
           let title = object["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           var info = sessions[session] {
            info.name = title
            sessions[session] = info
            updateTabs()
        }

        // Card changes have `id` and `status`; activity events have neither.
        guard let id = object["id"] as? String,
              let status = object["status"] as? String else { return }

        let statusAt = object["status_at"] as? Int ?? 0
        let note = object["note"] as? String
        if var info = sessions[id] {
            info.status = status
            info.statusAt = statusAt
            info.note = note
            sessions[id] = info
            updateTabs()
        } else {
            // A card this window hasn't seen yet: read the list once.
            refresh()
        }
    }
}
