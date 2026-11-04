import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The page behind New Agent: tabsh's New card, in the browser's own chrome.
// Uses the same composer card as agent chat (TabshComposerField, discs,
// Superellipse) with New Agent chips under the field. Files dropped or
// pasted attach as chips and are uploaded with the prompt (see TabshDrop).
struct AgentComposer: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var directory = TabshModels.shared

    @State private var settings: Tabsh.Settings?
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var providerName = ""
    @State private var mode = "tui"
    @State private var status = "in_progress"
    @State private var prompt = ""
    @State private var modelID: String?
    @State private var modelName: String?
    @State private var agentModeID: String?
    @State private var modelsOpen = false
    @State private var foldersOpen = false
    @State private var modeOpen = false
    @State private var creating = false
    @State private var failure: String?
    @State private var attachments: [TabshPendingAttachment] = []
    @State private var droppingFiles = false
    @State private var composerHeight: CGFloat = 32
    @State private var focusToken = 0
    /// `@` lists files under the chosen folder; + still opens the system panel.
    @State private var filesOpen = false
    /// `/` lists project and personal Cursor skills.
    @State private var skillsOpen = false
    @ObservedObject private var dictation = Dictation.shared

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var recentFolders: [String] {
        TabshFolders.recent(from: Array(TabshSessions.shared.sessions.values))
    }

    private var providers: [Tabsh.Provider] {
        let saved = settings?.providers ?? []
        // A daemon that has never saved settings has no providers: the
        // composer still offers the stock list rather than an empty menu.
        return saved.isEmpty ? Tabsh.stockProviders : saved
    }
    private var provider: Tabsh.Provider? {
        providers.first { $0.name == providerName } ?? providers.first
    }

    private var ready: Bool {
        provider != nil
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
            && !creating
    }

    var body: some View {
        ZStack {
            // The page's own white, as the new-tab page has it, not the
            // window's frame grey: the card is one page among the others,
            // and the frame already sits around it as a card (see CardEdge).
            Palette.ground
            VStack(spacing: 7) {
                if let failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.unsafe)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Same composer card as the agent chat. `@` / `/` float above
                // the card so opening them does not shift the layout.
                VStack(alignment: .leading, spacing: 6) {
                    if !attachments.isEmpty { attachmentBar }

                    HStack(alignment: .bottom, spacing: 4) {
                        Button(action: chooseFiles) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .composerDisc()
                        }
                        .buttonStyle(.plain)
                        .disabled(creating)
                        .help("Attach images or files")
                        .accessibilityLabel("Attach images or files")

                        Button(action: dictate) {
                            Image(systemName: dictation.busy ? "mic.fill" : "mic")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(dictation.busy ? Color(nsColor: .systemRed) : Palette.muted)
                                .composerDisc()
                        }
                        .buttonStyle(.plain)
                        .disabled(creating)
                        .help(dictation.busy ? "Stop dictating" : "Dictate the prompt")
                        .accessibilityLabel(dictation.busy ? "Stop dictating" : "Dictate the prompt")

                        TabshComposerField(text: $prompt,
                                           height: $composerHeight,
                                           focus: focusToken,
                                           placeholder: "What should the agent do?",
                                           onSubmit: create,
                                           onFiles: attach,
                                           onPickFiles: {
                                               foldersOpen = false
                                               modelsOpen = false
                                               modeOpen = false
                                               skillsOpen = false
                                               filesOpen = true
                                           },
                                           onPickSkills: {
                                               foldersOpen = false
                                               modelsOpen = false
                                               modeOpen = false
                                               filesOpen = false
                                               skillsOpen = true
                                           })
                            .frame(height: composerHeight)

                        if creating {
                            ProgressView()
                                .controlSize(.small)
                                .composerDisc()
                        } else {
                            Button(action: create) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(ready ? .white : Palette.faint)
                                    .composerDisc(
                                        fill: ready ? Color(nsColor: .controlAccentColor) : Palette.ground,
                                        ring: !ready
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(!ready)
                            .help("Create (⌘↩)")
                            .accessibilityLabel("Create")
                        }
                    }

                    HStack(spacing: 6) {
                        folderChip
                        modelChip
                        modeSwitch
                        if hasAgentModes { agentModeChip }
                        statusChip
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 1)
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .frame(width: 620)
                .background(
                    Superellipse()
                        .fill(droppingFiles ? Palette.wash : Palette.ground)
                        .shadow(color: .black.opacity(CardEdge.shadow), radius: 2, y: 1)
                )
                .overlay(Superellipse().stroke(
                    droppingFiles ? Color(nsColor: .controlAccentColor).opacity(0.55) : Palette.hairline,
                    lineWidth: 1
                ))
                .onDrop(of: [.fileURL, .image, .png, .jpeg, .gif, .webP, .tiff],
                        isTargeted: $droppingFiles) { providers in
                    TabshDrop.urls(from: providers) { attach($0) }
                    return true
                }
                .overlay(alignment: .top) {
                    Group {
                        if skillsOpen {
                            TabshComposerSkillPicker(projectPath: folder) { skill in
                                applySkill(skill)
                                skillsOpen = false
                            } dismiss: {
                                skillsOpen = false
                            }
                            .frame(maxWidth: .infinity)
                            .composerMenuChrome()
                        } else if filesOpen {
                            TabshComposerFilePicker(rootPath: folder) { url in
                                attach([url])
                                filesOpen = false
                            } dismiss: {
                                filesOpen = false
                            }
                            .frame(maxWidth: .infinity)
                            .composerMenuChrome()
                        }
                    }
                    .floatAboveComposer()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .zIndex((skillsOpen || filesOpen) ? 2 : 0)
                .animation(Motion.settle, value: skillsOpen || filesOpen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
        .onAppear { focusToken += 1 }
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    TabshAttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
        .frame(height: 58)
    }

    private var statusChip: some View {
        Menu {
            Button("Backlog") { status = "backlog" }
            Button("In progress") { status = "in_progress" }
        } label: {
            chipLabel(icon: status == "backlog" ? "tray" : "circle.dotted",
                      title: status == "backlog" ? "Backlog" : "In progress")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var folderChip: some View {
        Button {
            foldersOpen.toggle()
            modelsOpen = false
            modeOpen = false
            filesOpen = false
            skillsOpen = false
        } label: {
            chipLabel(icon: "folder",
                      title: TabshFolders.tildify(folder, home: home),
                      truncate: .head,
                      maxWidth: 96)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $foldersOpen, arrowEdge: .bottom) {
            FolderMenu(folder: $folder, recent: recentFolders, home: home) {
                foldersOpen = false
            }
        }
        .help("Choose the folder the agent starts in")
    }

    /// The agent and its model: the card's model selector. Every provider is
    /// a column of the menu and every model it has told tabsh about is a row
    /// beside it, so Cursor CLI opens onto Cursor's models and opencode onto
    /// opencode's.
    private var modelChip: some View {
        Button {
            modelsOpen.toggle()
            foldersOpen = false
            modeOpen = false
            filesOpen = false
            skillsOpen = false
            if modelsOpen {
                let list = providers
                Task { await directory.refresh(providers: list) }
            }
        } label: {
            let brand = TabshAgentBrand.infer(
                name: provider?.name ?? providerName,
                command: provider?.command ?? "",
                acp: provider?.acp ?? ""
            )
            HStack(spacing: 4) {
                TabshAgentMark(brand: brand, size: 11, tint: Palette.muted)
                Text(modelName ?? provider?.name ?? "Agent")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 96, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.hover))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $modelsOpen, arrowEdge: .bottom) {
            ModelMenu(providers: providers,
                      selectedProvider: providerName,
                      selectedModel: modelID,
                      cwd: folder,
                      directory: directory) { item, model in
                choose(item, model)
            }
        }
        .help(modelName.map { "\(provider?.name ?? "") · \($0)" } ?? "Choose the agent and model")
    }

    private var hasAgentModes: Bool {
        !directory.modes(for: providerName).isEmpty && modelID != nil
    }

    private var agentModeChip: some View {
        let options = directory.modes(for: providerName)
        let current = agentModeID
            ?? options.first { $0.id == directory.modes[providerName]?.current }?.id
            ?? options.first?.id
        let name = options.first { $0.id == current }?.name
            ?? directory.modes[providerName]?.current
            ?? "Mode"
        return Button {
            modeOpen.toggle()
            modelsOpen = false
            foldersOpen = false
            filesOpen = false
            skillsOpen = false
        } label: {
            chipLabel(icon: "shield.lefthalf.filled", title: name)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $modeOpen, arrowEdge: .bottom) {
            TabshModeList(options: options, current: current) { id in
                agentModeID = id
                modeOpen = false
            }
        }
        .fixedSize()
        .help("The agent's mode")
    }

    private var modeSwitch: some View {
        HStack(spacing: 1) {
            modeButton("Terminal", value: "tui")
            modeButton("Chat", value: "ui")
        }
        .padding(1.5)
        .background(Capsule().fill(Palette.hover))
        .fixedSize()
    }

    private func modeButton(_ title: String, value: String) -> some View {
        let selected = mode == value
        return Text(title)
            .font(.system(size: 10.5, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Palette.ink : Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(selected ? Palette.ground : .clear)
            )
            .contentShape(Capsule())
            .onTapGesture { mode = value }
    }

    /// Same short capsule the chat composer's Auto / Agent pickers use.
    private func chipLabel(icon: String,
                           title: String,
                           truncate: Text.TruncationMode = .tail,
                           maxWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(title)
                .lineLimit(1)
                .truncationMode(truncate)
                .frame(maxWidth: maxWidth, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.hover))
    }

    /// Speaks the prompt, on device (see Dictation.swift). Each settled
    /// piece is appended to what is already written, with a space between;
    /// the field keeps the keyboard throughout.
    private func dictate() {
        if dictation.busy {
            dictation.stop()
            return
        }
        dictation.begin { words in
            guard !words.isEmpty else { return }
            let gap = prompt.isEmpty || prompt.hasSuffix(" ") || prompt.hasSuffix("\n") ? "" : " "
            prompt += gap + words
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Attach images or files to the new agent"
        let add: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            attach(panel.urls)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }

    private func applySkill(_ skill: TabshSkill) {
        let mention = "/\(skill.name)"
        let gap = prompt.isEmpty || prompt.hasSuffix(" ") || prompt.hasSuffix("\n") ? "" : " "
        prompt += gap + mention + " "
        attach([skill.url])
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls where !attachments.contains(where: { $0.url == url }) {
            attachments.append(TabshPendingAttachment(url: url))
        }
        focusToken += 1
    }

    private func choose(_ item: Tabsh.Provider, _ model: Tabsh.ChatSelect.Choice?) {
        providerName = item.name
        modelID = model?.id
        modelName = model?.name
        let modes = directory.modes(for: item.name)
        agentModeID = modes.first { $0.id == directory.modes[item.name]?.current }?.id
            ?? modes.first?.id
        modelsOpen = false
    }

    private func load() async {
        do {
            let settings = try await Tabsh.settings()
            self.settings = settings
            let list = settings.providers.isEmpty ? Tabsh.stockProviders : settings.providers
            if providerName.isEmpty {
                providerName = settings.agentProvider ?? list.first?.name ?? ""
            }
            if let saved = settings.agentMode, saved == "ui" || saved == "tui" {
                mode = saved
            }
            // Prefer a folder a card already used, as the web New card does,
            // rather than always starting from home.
            if folder == home, let recent = recentFolders.first {
                folder = recent
            }
            await directory.refresh(providers: list)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func create() {
        guard let provider, ready else { return }
        creating = true
        failure = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let picking = attachments
        Task { @MainActor in
            do {
                var paths: [String] = []
                for attachment in picking {
                    paths.append(try await Tabsh.upload(file: attachment.url))
                }
                let combined = withImages(text, paths)
                let session: Tabsh.Session
                // UI cards always go through createChat — even with no model
                // picked yet (the agent keeps its default). The old gate on
                // `modelID != nil` fell through to createAgent, which only
                // stores the prompt on the session and never posts it as a
                // chat message, so the new pane opened empty.
                if mode == "ui", status != "backlog" {
                    // The chosen model only means something if it is set on
                    // the agent before the prompt goes in; otherwise the
                    // agent answers its first turn as its default.
                    session = try await Tabsh.createChat(
                        cwd: folder, name: title(for: text),
                        provider: provider, model: modelID,
                        mode: hasAgentModes ? agentModeID : nil)
                } else {
                    session = try await Tabsh.createAgent(cwd: folder, prompt: combined,
                                                          provider: provider, mode: mode,
                                                          status: status)
                }
                attachments.removeAll()
                // A card made from a composer opened in a group joins that
                // group, as a file opened from the terminal's explorer does.
                // Read from the composer's own tab: it may not be the one in
                // front when it sits in a split.
                let group = browser.pageTab(.agentComposer).flatMap { browser.group(of: $0) }
                let page = mode == "ui"
                    ? InternalPage(.agent, session.id)
                    : InternalPage(.tabsh, session.id)
                let tab = browser.show(page)
                if let group { browser.move(tab, toGroup: group) }
                // Hand the New Agent words to the live chat after the pane
                // exists, so they show up as the first bubble (and so a
                // prompt written with no model still arrives).
                if mode == "ui", status != "backlog", !combined.isEmpty {
                    TabshChats.shared.chat(for: session.id).send(combined)
                }
                browser.putAway(.agentComposer)
            } catch {
                failure = error.localizedDescription
            }
            creating = false
        }
    }

    /// The web's shape: the prompt, a blank line, then one path a line.
    private func withImages(_ text: String, _ paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let files = paths.joined(separator: "\n")
        return text.isEmpty ? files : text + "\n\n" + files
    }

    /// The name a card is born with: the prompt's first line, as the web
    /// card's `prompt_title` takes it.
    private func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "New agent" }
        return String(trimmed.prefix(100))
    }
}

/// The New Agent folder field as a search: typing lists the folders that
/// complete it (the daemon's /api/files/folders), and until the field is
/// edited the list offers recent folders. ↑↓ move, Enter picks, Tab picks
/// and lists the picked folder's subfolders — the same shape as the web card.
private struct FolderMenu: View {
    @Binding var folder: String
    let recent: [String]
    let home: String
    let dismiss: () -> Void

    @State private var query = ""
    @State private var edited = false
    @State private var options: [String] = []
    @State private var active = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var latest = 0
    /// Ignores the query write that seeds the field when the popover opens,
    /// so the first paint still shows recent folders instead of searching.
    @State private var seeding = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if !options.isEmpty { optionsList }
        }
        .padding(8)
        .frame(width: 340)
        .background(Palette.ground)
        .onAppear(perform: seed)
        .onChange(of: query, perform: queryChanged)
        .onKeyPress(.upArrow) {
            active = TabshFolders.moveActive(active, by: -1, count: options.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            if options.isEmpty { scheduleSearch() }
            else { active = TabshFolders.moveActive(active, by: 1, count: options.count) }
            return .handled
        }
        .onKeyPress(.tab) {
            pick(descend: true)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            TextField("Search folders or type a path…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { pick(descend: false) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.hover)
        )
    }

    private var optionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, path in
                        optionRow(index: index, path: path)
                    }
                }
                .padding(4)
            }
            // A ScrollView has no height of its own, and in a popover it
            // collapsed to a sliver: the folders were listed but cut off
            // below the search field. It gets the room its rows take, and
            // scrolls once that passes the cap. No scroller: the legacy bar
            // in a popover is a thick strip beside the names.
            .scrollIndicators(.never)
            .frame(height: listHeight)
            .onChange(of: active) {
                guard active >= 0, active < options.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
    }

    /// One row's height: a 12pt line with 5pt above and below it.
    private static let rowHeight: CGFloat = 25
    private static let listMaxHeight: CGFloat = 240

    private var listHeight: CGFloat {
        // The rows, the gap between them, and the 4pt the stack is inset by.
        let rows = CGFloat(options.count) * Self.rowHeight + CGFloat(options.count - 1) + 8
        return min(rows, Self.listMaxHeight)
    }

    private func optionRow(index: Int, path: String) -> some View {
        let label = TabshFolders.tildify(path, home: home)
        let lit = index == active
        return Button { choose(path, descend: false) } label: {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(lit ? Palette.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: Self.rowHeight)
        .id(index)
        .help(path)
    }

    private func seed() {
        seeding = true
        query = TabshFolders.tildify(folder, home: home)
        edited = false
        options = recent
        active = options.isEmpty ? -1 : 0
        focused = true
        DispatchQueue.main.async { seeding = false }
    }

    private func queryChanged(_: String) {
        guard !seeding else { return }
        edited = true
        scheduleSearch()
    }

    private func pick(descend: Bool) {
        if active >= 0, active < options.count {
            choose(options[active], descend: descend)
            return
        }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        choose(TabshFolders.expandHome(typed, home: home), descend: descend)
    }

    private func choose(_ path: String, descend: Bool) {
        let absolute = TabshFolders.expandHome(path, home: home)
        if descend {
            query = TabshFolders.tildify(absolute, home: home) + "/"
            edited = true
            scheduleSearch()
            return
        }
        folder = absolute
        dismiss()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func search() async {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edited || typed.isEmpty {
            options = recent
            active = options.isEmpty ? -1 : 0
            return
        }
        let mine = latest + 1
        latest = mine
        do {
            let result = try await Tabsh.folders(path: typed)
            guard mine == latest else { return }
            options = result.folders
            active = options.isEmpty ? -1 : 0
        } catch {
            // The daemon is unreachable: the field still takes a typed path.
            guard mine == latest else { return }
        }
    }
}

/// The model wheel: the agents in the left column, each agent's models in
/// the right one, switched by hovering the agent. A search bar runs across
/// the top of both columns, so a long list is narrowed before it is read.
private struct ModelMenu: View {
    let providers: [Tabsh.Provider]
    let selectedProvider: String
    let selectedModel: String?
    let cwd: String
    @ObservedObject var directory: TabshModels
    let pick: (Tabsh.Provider, Tabsh.ChatSelect.Choice?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hovering: String?
    @State private var query = ""
    @FocusState private var searching: Bool

    private var shown: Tabsh.Provider? {
        providers.first { $0.name == (hovering ?? selectedProvider) } ?? providers.first
    }

    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            Rule()

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(providers) { provider in
                            Button { pick(provider, nil) } label: {
                                providerRow(provider)
                            }
                            .buttonStyle(.plain)
                            .onHover { inside in
                                guard inside else { return }
                                hovering = provider.name
                                directory.offer(provider: provider, cwd: cwd)
                            }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(width: 190)

                Rectangle()
                    .fill(Palette.hairline)
                    .frame(width: 1)

                modelColumn
            }
            .frame(height: 320)
        }
        .background(Palette.ground)
        .onAppear {
            hovering = selectedProvider
            if let provider = shown {
                directory.offer(provider: provider, cwd: cwd)
            }
            DispatchQueue.main.async { searching = true }
        }
        .onDisappear { directory.cancelOffer() }
    }

    /// The bar the popover opens with: a magnifying glass, a plain field, and
    /// Escape — which empties the field first, then closes the wheel, so a
    /// typed search is never lost to a stray press.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
            TextField("Search models…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searching)
                .onExitCommand {
                    if needle.isEmpty {
                        dismiss()
                    } else {
                        query = ""
                    }
                }
            if !needle.isEmpty {
                Button {
                    query = ""
                    searching = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.faint)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func providerRow(_ provider: Tabsh.Provider) -> some View {
        let active = shown?.name == provider.name
        let brand = TabshAgentBrand.infer(name: provider.name,
                                          command: provider.command,
                                          acp: provider.acp ?? "")
        return HStack(spacing: 7) {
            TabshAgentMark(brand: brand, size: 12, tint: Palette.ink)
                .frame(width: 14)
            Text(provider.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if directory.probing.contains(provider.name) {
                ProgressView()
                    .controlSize(.mini)
            } else if provider.name == selectedProvider {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
    }

    private var modelColumn: some View {
        let all = directory.models(for: shown?.name ?? "")
        let options = all.filter { matches($0) }
        let defaultRow = shown.map { matches("Default", $0.name) } ?? false
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let provider = shown {
                    if all.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(directory.probing.contains(provider.name)
                                 ? "Reading the agent's models…"
                                 : "No models reported yet")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                            Text("A chat of this agent has to be live once for tabsh to learn its list.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }

                    if defaultRow {
                        modelRow("Default", detail: provider.name,
                                 chosen: selectedProvider == provider.name && selectedModel == nil) {
                            pick(provider, nil)
                        }
                    }
                    ForEach(options) { choice in
                        modelRow(choice.name, detail: choice.description,
                                 chosen: selectedProvider == provider.name && selectedModel == choice.id) {
                            pick(provider, choice)
                        }
                    }

                    // A search that found nothing in this agent's list is
                    // told so, unless there was never a list to search.
                    if !all.isEmpty, !defaultRow, options.isEmpty {
                        Text("No models match.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(6)
        }
        // Matches the chat model picker: no legacy thick scroller in the card.
        .scrollIndicators(.never)
        .frame(width: 320)
    }

    /// Whether a row survives the search: the needle against its headline and
    /// whatever else it says, case- and diacritic-insensitively. An empty
    /// field keeps everything.
    private func matches(_ text: String, _ other: String? = nil) -> Bool {
        guard !needle.isEmpty else { return true }
        if text.localizedStandardContains(needle) { return true }
        guard let other, !other.isEmpty else { return false }
        return other.localizedStandardContains(needle)
    }

    private func matches(_ choice: Tabsh.ChatSelect.Choice) -> Bool {
        matches(choice.name, choice.description) || matches(choice.id)
    }

    private func modelRow(_ title: String, detail: String?, chosen: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


