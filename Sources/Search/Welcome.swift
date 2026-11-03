import AppKit
import SwiftUI

/// The first time. Four short pages over the window, in the app's own
/// language: what this is, what to bring over, how to hold it, and whether
/// links from other apps should come here. Nothing is asked twice, and every
/// page can be skipped.
struct WelcomePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var page = 0
    @State private var forward = true

    // Bringing things over. Nil until one is picked, which means the first:
    // finding them looks through each browser's folders, and as an initial
    // value that ran every time the panel was made, the first window's
    // included, for a page that isn't showing yet.
    @State private var source: ImportSource?
    @State private var wantsPasswords = true
    @State private var wantsHistory = true
    @State private var wantsBookmarks = true
    @State private var bringing = false
    @State private var brought: String?

    // The default browser.
    @State private var isDefault = Links.isDefault
    @State private var asked = false

    // Connect your agents: pick a provider, copy the setup prompt, or open
    // a card that runs it.
    @State private var editingAgents = false
    @State private var settingUp = false
    @State private var setupFailure: String?
    @State private var copiedPrompt = false

    private var importsPasswords: Bool { (source ?? ImportSource.installed().first)?.importsPasswords ?? false }

    private let pages = 5

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    switch page {
                    case 0: welcome
                    case 1: bring
                    case 2: hold
                    case 3: links
                    default: agents
                    }
                }
                .frame(maxWidth: 520)
                .id(page)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                    removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                ))
                Spacer(minLength: 0)
                foot
            }
            .padding(40)
        }
        .animation(Motion.glide, value: page)
        .transition(.opacity)
    }

    // MARK: - the pages

    private var welcome: some View {
        VStack(spacing: 22) {
            Plate(size: 72)
            VStack(spacing: 10) {
                Text("Tabs")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("A browser with nothing in the way. Four megabytes, the engine already in your Mac, and as little around the page as we could manage.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }
        }
    }

    private var bring: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Bring things over.", "Passwords go into your keychain, bookmarks into the menu, and history means the address field already knows where you go. Nothing in the other browser changes.")

            let sources = ImportSource.installed()
            let unreadable = Chromium.unreadable()
            if sources.isEmpty {
                if unreadable.isEmpty {
                    Text("No other browser found on this Mac — nothing to bring.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if sources.count > 1 {
                        Segmented(
                            options: sources.map { ($0, $0.name) },
                            selection: Binding(get: { source ?? sources[0] }, set: { source = $0 })
                        )
                    } else {
                        Text("From \(sources[0].name)")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    if importsPasswords {
                        Choice("Passwords", "macOS will ask once for that browser's keychain key", on: $wantsPasswords)
                    } else {
                        Text("Passwords from \((source ?? sources[0]).name) aren't supported yet.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    Choice("Bookmarks", "Folders and all, behind the bookmark button", on: $wantsBookmarks)
                    Choice("History", "The last few thousand places, for finishing addresses", on: $wantsHistory)
                }

                HStack(spacing: 12) {
                    Big(bringing ? "Bringing…" : "Bring them in", filled: true) { bringAll() }
                        .disabled(bringing || brought != nil || !((importsPasswords && wantsPasswords) || wantsHistory || wantsBookmarks))
                    if bringing { Ring(size: 10) }
                    if let brought {
                        Text(brought)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.settle, value: brought)
            }

            if !unreadable.isEmpty {
                Text(unreadable.map(\.message).joined(separator: "\n"))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Safari, a browser on another Mac, one Tabs can't read: what
            // it exported, bookmarks, passwords or Safari's own ZIP.
            Pill("From a file another browser exported…") { browser.importFile() }
        }
    }

    private var hold: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Two ways to hold it.", "Titles across the top, or down the side. The grey slides to the tab you pick either way, and you can change your mind with ⇧⌘S.")
            HStack(spacing: 12) {
                Way(title: "Tab strip", sidebar: false, chosen: !prefs.sidebar) {
                    withAnimation(Motion.glide) { prefs.sidebar = false }
                }
                Way(title: "Sidebar", sidebar: true, chosen: prefs.sidebar) {
                    withAnimation(Motion.glide) { prefs.sidebar = true }
                }
            }
            HStack(spacing: 12) {
                Text("Tabs wear")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Connect your agents.",
                    "Cards move on their own when your coding agent reports what it is doing. Pick one and let it wire its hooks, or copy the prompt into a session you already have.")
            if editingAgents {
                AgentProvidersSettings()
                Button {
                    withAnimation(Motion.settle) { editingAgents = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Back to setup")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
            } else {
                WelcomeAgentSetup(
                    settingUp: $settingUp,
                    failure: $setupFailure,
                    copied: $copiedPrompt,
                    onEditProviders: {
                        withAnimation(Motion.settle) { editingAgents = true }
                    },
                    onSetUp: setUpAgent
                )
            }
        }
        .onAppear { AgentProviderStore.shared.refresh() }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Links from other apps.", "A click in Mail, in Slack, in a PDF — macOS sends it to whichever browser is the default. It can be this one.")
            HStack(spacing: 12) {
                if isDefault {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                        Text("Tabs is the default browser")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                } else {
                    Big("Make Tabs the default", filled: true) {
                        asked = true
                        Links.becomeDefault { _ in isDefault = Links.isDefault }
                    }
                    if asked, !isDefault {
                        Text("macOS asks in its own dialog")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.faint)
                    }
                }
            }
            .animation(Motion.settle, value: isDefault)

            VStack(alignment: .leading, spacing: 8) {
                Text("A few things worth knowing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.top, 6)
                Key("⌘T", "A new tab. Type a place, or words to search.")
                Key("⌘K", "Every open tab, by name.")
                Key("⌘,", "Settings, including passwords and updates. ⌘F there finds any setting.")
                Key("⌃1", "Spaces: separate tabs and sign-ins. Turn them on in Settings › Spaces & Pins, or Set Up Like Arc there.")
                Key("⌥⌘N", "Split a page in two, or drag a tab onto a page; ⌃⌘← and ⌃⌘→ go from one page to the other.")
                Key("⌘O", "Links from other apps can open in a small window. Settings › Browsing.")
                Key("⌘L", "Suggestions from your search engine as you type — off until you turn them on in Settings › Browsing.")
                Key("⌘", "Held, it can show each tab's number for ⌘1–9. Settings › Tabs.")
                Key("⌘1", "Pressed again on its pin, back to where you were.")
                Key("⇧⌘P", "Float a video in Tabs' window, or in macOS's picture in picture. Settings › Browsing.")
                Key("⌃-click", "Claude or ChatGPT in a side panel beside the page: right-click a tab › Open in Side Panel, or View › Side Panel.")
                Key("⌘Q", "Tabs can ask before it quits. Settings › General.")
                Key("⌘,", "Your Apple passwords, under the sign-in field — Settings › Passwords.")
                if PageTranslator.available {
                    Key("⌃-click", "Translate a page into your language, on this Mac — nothing is sent anywhere. Right-click the page › Translate Page.")
                }
                if AI.shipped {
                    Key("⌘,", "AI summaries and questions about a page — off until you turn it on in Settings › AI.")
                }
            }
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Palette.ink : Palette.faint.opacity(0.6))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            if page < pages - 1 {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Big(page < pages - 1 ? "Continue" : "Start browsing", filled: true) {
                if page < pages - 1 { forward = true; page += 1 } else { finish() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520)
    }

    // MARK: - doing

    private func bringAll() {
        guard let source = source ?? ImportSource.installed().first else { return }
        // The profile used most recently, without asking: the sheet in
        // Settings › Passwords is where another is chosen.
        let profile = source.usual
        bringing = true
        var lines: [String] = []
        let group = DispatchGroup()
        if wantsPasswords && source.importsPasswords {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try source.read(profile: profile) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let found):
                        let kept = browser.keep(found)
                        ImportRecords.note(source.name, passwords: kept)
                        lines.append("\(kept) passwords" + (found.undecrypted > 0 ? " (\(found.undecrypted) couldn't be decrypted)" : ""))
                    case .failure(Chromium.Trouble.noPassphrase):
                        lines.append("passwords: macOS didn't hand over the key — allow it and try again")
                    case .failure(Mozilla.Trouble.primaryPassword):
                        lines.append("passwords: \(source.name) has a primary password — export them from it and bring in the CSV")
                    case .failure:
                        lines.append("passwords: nothing readable")
                    }
                    group.leave()
                }
            }
        }
        if wantsBookmarks {
            lines.append("\(browser.takeBookmarks(from: source, profile: profile).added) bookmarks")
        }
        if wantsHistory {
            group.enter()
            browser.takePlaces(from: source, profile: profile) { count in
                lines.append("\(count) places")
                group.leave()
            }
        }
        group.notify(queue: .main) {
            bringing = false
            brought = lines.joined(separator: " · ")
            browser.relist()
        }
    }

    private func finish() {
        prefs.welcomed = true
        withAnimation(Motion.settle) { browser.welcoming = false }
    }

    /// Opens a TUI card whose first prompt is the Tabs setup guide, for the
    /// provider the user picked — same idea as tabsh web's welcome Set up.
    private func setUpAgent() {
        let store = AgentProviderStore.shared
        guard let provider = store.providers.first(where: { $0.name == store.preferred })
                ?? store.providers.first
        else { return }
        settingUp = true
        setupFailure = nil
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task { @MainActor in
            do {
                let session = try await Tabsh.createAgent(
                    cwd: home,
                    prompt: TabshDaemon.setupPrompt,
                    provider: provider.tabsh,
                    mode: "tui",
                    status: "in_progress")
                finish()
                _ = browser.show(InternalPage(.tabsh, session.id))
            } catch {
                setupFailure = error.localizedDescription
            }
            settingUp = false
        }
    }

    private func heading(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - pieces

    /// The mark alone, at whatever height the page wants — no plate behind
    /// it, the same as everywhere else it's drawn.
    private struct Plate: View {
        let size: CGFloat
        var body: some View {
            Logomark()
                .fill(Palette.ink, style: FillStyle(eoFill: true))
                .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                .frame(width: size, height: size)
        }
    }

    private struct Big: View {
        let title: String
        var filled = false
        let act: () -> Void
        @State private var hovering = false

        init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.filled = filled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(filled ? Palette.ground : Palette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.wash), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private struct Choice: View {
        let title: String
        let detail: String
        @Binding var on: Bool

        init(_ title: String, _ detail: String, on: Binding<Bool>) {
            self.title = title
            self.detail = detail
            _on = on
        }

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                }
                Spacer()
                Switch(on: $on)
            }
        }
    }

    /// One of the two ways, as a small drawing of the window.
    private struct Way: View {
        let title: String
        let sidebar: Bool
        let chosen: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground)
                        if sidebar {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                        .padding(.bottom, 4)
                                    ForEach(0..<4, id: \.self) { i in
                                        RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Palette.wash : Palette.hover).frame(height: 8)
                                    }
                                }
                                .padding(8)
                                .frame(width: 62)
                                Rectangle().fill(Palette.hairline).frame(width: 1)
                                Spacer()
                            }
                        } else {
                            HStack(spacing: 3) {
                                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                    .padding(.trailing, 6)
                                ForEach(0..<4, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Palette.wash : Palette.hover).frame(width: 30, height: 8)
                                }
                            }
                            .padding(8)
                        }
                    }
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    Text(title)
                        .font(.system(size: 13, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chosen ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chosen ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.settle, value: chosen)
        }
    }

    private struct Key: View {
        let keys: String
        let what: String
        init(_ keys: String, _ what: String) { self.keys = keys; self.what = what }
        var body: some View {
            HStack(spacing: 10) {
                Text(keys)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(minWidth: 44)
                Text(what).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// Welcome's agents step: pick a provider, copy the Tabs setup prompt, or
/// open a card that runs it — the editor stays one tap away.
private struct WelcomeAgentSetup: View {
    @ObservedObject private var store = AgentProviderStore.shared
    @Binding var settingUp: Bool
    @Binding var failure: String?
    @Binding var copied: Bool
    let onEditProviders: () -> Void
    let onSetUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Rule() }
                    providerRow(provider)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Or paste into a session you already have")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                HStack(alignment: .top, spacing: 10) {
                    Text(TabshDaemon.setupPrompt)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Pill(copied ? "Copied" : "Copy") { copyPrompt() }
                }
                .padding(12)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                Big("Set up with \(chosenName)", filled: true, act: onSetUp)
                    .disabled(settingUp || store.providers.isEmpty)
                if settingUp { Ring(size: 10) }
                Button("Edit providers…") { onEditProviders() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.unsafe)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.reading {
                HStack(spacing: 8) {
                    Ring(size: 10)
                    Text("Reading agents…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var chosenName: String {
        store.preferred
            ?? store.providers.first?.name
            ?? "an agent"
    }

    private func providerRow(_ provider: AgentProvider) -> some View {
        Button {
            store.choose(provider)
        } label: {
            HStack(spacing: 12) {
                TabshAgentMark(brand: provider.brand, size: 14, tint: Palette.ink)
                    .frame(width: 26, height: 26)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                    Text(provider.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if store.preferred == provider.name {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TabshDaemon.setupPrompt, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    /// Same capsule as Welcome's Continue, kept local so this screen does
    /// not reach into WelcomePanel's private pieces.
    private struct Big: View {
        let title: String
        var filled = false
        let act: () -> Void
        @State private var hovering = false

        init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.filled = filled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(filled ? Palette.ground : Palette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.wash),
                                in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}
