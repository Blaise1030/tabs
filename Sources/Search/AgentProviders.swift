import SwiftUI

/// One agent the New Agent page offers: the command that starts it in a
/// terminal, the one that resumes a conversation, and the ACP command a chat
/// card speaks to. The daemon stores them with the rest of its settings; the
/// browser only reads and writes its part (`providers`, `agentProvider`).
struct AgentProvider: Identifiable, Equatable {
    let id: UUID
    var name: String
    var command: String
    var resume: String
    var acp: String

    init(id: UUID = UUID(), name: String, command: String,
         resume: String = "", acp: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.resume = resume
        self.acp = acp
    }
}

/// Which part of a provider a row edits.
enum AgentProviderField: String {
    case name, command, resume, acp
}

/// The daemon's provider list, held while a window is open so Settings and
/// the Welcome see the same edits. Changes go back to the daemon as a whole
/// settings object: a PUT replaces it, so the keys this screen doesn't touch
/// (theme, keybindings, sounds) must travel back unchanged.
final class AgentProviderStore: ObservableObject {
    static let shared = AgentProviderStore()

    /// The web app's cap (`MAX_PROVIDERS`), so both screens agree.
    static let most = 12

    @Published private(set) var providers: [AgentProvider]
    @Published private(set) var preferred: String?
    @Published private(set) var reading = false
    @Published private(set) var failure: String?
    /// Why the row being edited can't be saved yet.
    @Published private(set) var problem: String?

    /// Saves are chained: two edits in a row reach the daemon in the order
    /// they were made, and the last one carries both.
    private var lastSave: Task<Void, Never>?
    /// A read that started before an edit must not put the old list back.
    private var revision = 0

    static func stock() -> AgentProvider {
        AgentProvider(name: "Claude Code",
                      command: "claude {prompt}",
                      resume: "claude --resume {session}",
                      acp: "npx --yes @agentclientprotocol/claude-agent-acp")
    }

    private init() {
        providers = [Self.stock()]
        preferred = providers.first?.name
    }

    // MARK: - reading

    /// Read them again, for the screens that open onto this list: providers
    /// can also be changed in tabsh's web page while the browser is open.
    func refresh() {
        guard !reading else { return }
        Task { @MainActor in await load() }
    }

    @MainActor
    func load() async {
        guard !reading else { return }
        let started = revision
        reading = true
        defer { reading = false }
        do {
            let object = try await Tabsh.settingsObject()
            // An edit made while the list was coming back is newer than it.
            guard revision == started else { return }
            var list: [AgentProvider] = []
            for entry in object["providers"] as? [[String: Any]] ?? [] {
                let name = (entry["name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let command = (entry["command"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !command.isEmpty,
                      !list.contains(where: { $0.name == name })
                else { continue }
                list.append(AgentProvider(
                    name: name,
                    command: command,
                    resume: entry["resume"] as? String ?? "",
                    acp: entry["acp"] as? String ?? ""
                ))
            }
            // A daemon with nothing saved gets the same stock agent the web
            // app would have offered, ready to edit rather than an empty page.
            if list.isEmpty { list = [Self.stock()] }
            providers = Array(list.prefix(Self.most))
            let wanted = object["agentProvider"] as? String
            preferred = providers.first { $0.name == wanted }?.name ?? providers.first?.name
            failure = nil
            problem = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - changing

    @MainActor
    func choose(_ provider: AgentProvider) {
        guard preferred != provider.name else { return }
        preferred = provider.name
        problem = nil
        revision += 1
        save()
    }

    /// Add a provider and return it, so the screen can open its commands.
    /// A name another provider already has is refused with `problem` set.
    @MainActor
    func add(named raw: String) -> AgentProvider? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trouble = Self.nameTrouble(name, in: providers, except: nil) {
            problem = trouble
            return nil
        }
        guard providers.count < Self.most else {
            problem = "A dozen agents is as many as tabsh keeps"
            return nil
        }
        let provider = AgentProvider(name: name,
                                     command: "\(name.lowercased()) {prompt}")
        providers.append(provider)
        problem = nil
        revision += 1
        save()
        return provider
    }

    /// Change one command or the name. Returns the reason it couldn't be
    /// saved, or nil once it is in the list (the daemon write follows).
    @MainActor
    @discardableResult
    func update(_ id: UUID, _ field: AgentProviderField, to raw: String) -> String? {
        guard let index = providers.firstIndex(where: { $0.id == id }) else {
            problem = "That provider isn't there any more"
            return problem
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = providers[index]
        switch field {
        case .name:
            if let trouble = Self.nameTrouble(value, in: providers, except: id) {
                problem = trouble
                return trouble
            }
            let wasPreferred = preferred == provider.name
            providers[index].name = value
            if wasPreferred { preferred = value }
        case .command:
            if value.isEmpty {
                problem = "The startup command can't be empty"
                return problem
            }
            providers[index].command = value
        case .resume:
            providers[index].resume = value
        case .acp:
            providers[index].acp = value
        }
        problem = nil
        revision += 1
        save()
        return nil
    }

    @MainActor
    func remove(_ id: UUID) {
        // The web app keeps the last one: a tabsh with no agent would have
        // nothing for New Agent to start.
        guard providers.count > 1,
              let index = providers.firstIndex(where: { $0.id == id })
        else { return }
        let removed = providers.remove(at: index)
        if preferred == removed.name { preferred = providers.first?.name }
        problem = nil
        revision += 1
        save()
    }

    static func nameTrouble(_ name: String, in list: [AgentProvider],
                            except id: UUID?) -> String? {
        if name.isEmpty { return "A provider needs a name" }
        if list.contains(where: { $0.id != id && $0.name == name }) {
            return "Another provider has that name"
        }
        return nil
    }

    // MARK: - writing

    @MainActor
    private func save() {
        let snapshot = providers
        let wanted = preferred
        let previous = lastSave
        lastSave = Task { @MainActor in
            _ = await previous?.result
            do {
                var object = try await Tabsh.settingsObject()
                object["providers"] = snapshot.map { provider -> [String: String] in
                    var entry = ["name": provider.name, "command": provider.command]
                    if !provider.resume.isEmpty { entry["resume"] = provider.resume }
                    // An empty ACP command keeps UI mode off, and the web
                    // app stores no key at all in that case.
                    if !provider.acp.isEmpty { entry["acp"] = provider.acp }
                    return entry
                }
                if let wanted {
                    object["agentProvider"] = wanted
                } else {
                    object.removeValue(forKey: "agentProvider")
                }
                try await Tabsh.saveSettingsObject(object)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Settings › Agents and the Welcome

/// The provider list, and one provider's commands when it is opened. The
/// same view is drawn in Settings › Agents and in the Welcome, so the two
/// can't disagree about what a provider is or how it is changed.
struct AgentProvidersSettings: View {
    @ObservedObject private var store = AgentProviderStore.shared

    /// Nil shows the list; a provider's id shows its commands.
    @State private var editing: UUID?
    @State private var adding = false
    @State private var newName = ""
    @FocusState private var naming: Bool

    var body: some View {
        Group {
            if let editing, let provider = store.providers.first(where: { $0.id == editing }) {
                AgentProviderEditor(store: store, provider: provider) {
                    self.editing = nil
                }
                .id(provider.id)
            } else {
                list
            }
        }
        .onAppear { store.refresh() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Rule() }
                    providerRow(provider)
                }
                if store.providers.count < AgentProviderStore.most {
                    Rule()
                    addRow
                }
            }
            Text("Click an agent to make it the one New Agent starts. The pencil edits the commands it runs.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = store.problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.unsafe)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = store.failure {
                HStack(spacing: 8) {
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.unsafe)
                        .fixedSize(horizontal: false, vertical: true)
                    Pill("Try Again") { Task { @MainActor in await store.load() } }
                }
            } else if store.reading {
                HStack(spacing: 8) {
                    Ring(size: 10)
                    Text("Reading the agents tabsh already has")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func providerRow(_ provider: AgentProvider) -> some View {
        HStack(spacing: 8) {
            Button {
                store.choose(provider)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink.opacity(0.78))
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
                            .help("New Agent starts this one")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Start \(provider.name) with New Agent")
            Pill("Edit") { editing = provider.id }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var addRow: some View {
        HStack(spacing: 12) {
            Image(systemName: adding ? "pencil" : "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            if adding {
                TextField("Name the provider, then Return",
                          text: $newName,
                          prompt: Text("Name the provider, then Return")
                            .foregroundStyle(Palette.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($naming)
                    .onSubmit(add)
                    .onExitCommand { stopAdding() }
                Pill("Add") { add() }
                Pill("Cancel") { stopAdding() }
            } else {
                Text("Add provider")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !adding else { return }
            adding = true
            newName = ""
            DispatchQueue.main.async { naming = true }
        }
    }

    private func add() {
        guard let provider = store.add(named: newName) else { return }
        stopAdding()
        editing = provider.id
    }

    private func stopAdding() {
        adding = false
        newName = ""
        naming = false
    }
}

/// One provider's four commands, each a row that turns into a field as the
/// row is clicked. Return saves, Escape leaves it as it was.
private struct AgentProviderEditor: View {
    @ObservedObject var store: AgentProviderStore
    let provider: AgentProvider
    let back: () -> Void

    @State private var editing: AgentProviderField?
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: back) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Agent providers")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(provider.name.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                    Spacer(minLength: 8)
                    if store.providers.count > 1 {
                        Button {
                            store.remove(provider.id)
                            back()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                                .padding(3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete \(provider.name)")
                    }
                }
                .foregroundStyle(Palette.ink.opacity(0.62))
                .padding(.leading, 2)
                Card {
                    fieldRow(.name, "Name…", provider.name, hint: "", monospaced: false)
                    Rule()
                    fieldRow(.command, "Startup command…", provider.command,
                             hint: "The command that starts it; {prompt} is the card's first prompt",
                             monospaced: true)
                    Rule()
                    fieldRow(.resume, "Resume command…", provider.resume,
                             hint: "None", monospaced: true)
                    Rule()
                    fieldRow(.acp, "ACP command…", provider.acp,
                             hint: "None — UI mode stays off", monospaced: true)
                }
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.unsafe)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = store.failure {
                HStack(spacing: 8) {
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.unsafe)
                        .fixedSize(horizontal: false, vertical: true)
                    Pill("Try Again") { Task { @MainActor in await store.load() } }
                }
            }
        }
    }

    private func fieldRow(_ field: AgentProviderField, _ title: String,
                          _ value: String, hint: String, monospaced: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .fixedSize()
            Spacer(minLength: 14)
            if editing == field {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: monospaced ? 11.5 : 12.5,
                                  design: monospaced ? .monospaced : .default))
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit { commit(field) }
                    .onExitCommand { cancel() }
            } else {
                Text(value.isEmpty ? hint : value)
                    .font(.system(size: monospaced ? 11.5 : 12.5,
                                  design: monospaced ? .monospaced : .default))
                    .foregroundStyle(value.isEmpty ? Palette.faint : (monospaced ? Palette.muted : Palette.ink))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(value.isEmpty ? hint : value)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editing == nil else { return }
            begin(field, value)
        }
    }

    private func begin(_ field: AgentProviderField, _ value: String) {
        problem = nil
        editing = field
        draft = value
        // The field isn't in the hierarchy until this change is drawn, so
        // focus waits one turn instead of asking a TextField that isn't there.
        DispatchQueue.main.async { focused = true }
    }

    private func commit(_ field: AgentProviderField) {
        if let trouble = store.update(provider.id, field, to: draft) {
            problem = trouble
            return
        }
        problem = nil
        editing = nil
        focused = false
    }

    private func cancel() {
        problem = nil
        editing = nil
        focused = false
    }
}
