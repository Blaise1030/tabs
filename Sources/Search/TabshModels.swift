import Foundation

/// The models and modes each agent advertises, for the New Agent card.
///
/// The daemon only knows these while a chat is live — `session/new` is where
/// an ACP agent says what it can run — so this borrows the lists from the UI
/// cards tabsh already has running, and remembers the last answer per
/// provider so the card can offer them before it starts one of its own.
@MainActor
final class TabshModels: ObservableObject {
    static let shared = TabshModels()

    /// Provider name → the models its live chats reported.
    @Published private(set) var models: [String: Tabsh.ChatSelect] = [:]
    /// Provider name → the modes its live chats reported.
    @Published private(set) var modes: [String: Tabsh.ChatSelect] = [:]
    /// A refresh is reading the board's live chats right now.
    @Published private(set) var reading = false
    /// Providers whose agent this is asking for its model list right now.
    @Published private(set) var probing: Set<String> = []

    private var loading = false
    private var asked = Set<String>()
    private let savedKey = "tabsh.agent.selects"

    private struct Saved: Codable {
        var models: [String: Tabsh.ChatSelect]
        var modes: [String: Tabsh.ChatSelect]
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        models = saved.models
        modes = saved.modes
    }

    func models(for provider: String) -> [Tabsh.ChatSelect.Choice] {
        models[provider]?.options ?? []
    }

    func modes(for provider: String) -> [Tabsh.ChatSelect.Choice] {
        modes[provider]?.options ?? []
    }

    /// Look through the board for a live chat of each provider; the agent
    /// with the longest model list wins when several answer. Cards that
    /// aren't live answer with nothing, which just leaves the memory alone.
    func refresh(providers: [Tabsh.Provider]) async {
        guard !loading else { return }
        loading = true
        reading = true
        defer {
            loading = false
            reading = false
        }
        guard let sessions = try? await Tabsh.sessions() else { return }
        for provider in providers {
            let acp = provider.acp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !acp.isEmpty else { continue }
            let rows = sessions.filter {
                ($0.acpCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == acp
            }
            var best: Tabsh.ChatSelect?
            var bestModes: Tabsh.ChatSelect?
            for row in rows {
                guard let select = try? await Tabsh.chatModels(row.id),
                      !select.options.isEmpty else { continue }
                if let held = best, held.options.count >= select.options.count { continue }
                best = select
                bestModes = (try? await Tabsh.chatModes(row.id)) ?? Tabsh.ChatSelect()
            }
            if let best {
                models[provider.name] = best
                if let bestModes { modes[provider.name] = bestModes }
            }
        }
        save()
    }

    /// Ask the agent itself, the first time this provider is opened. The
    /// daemon only reports models for a live chat, and a card is the only
    /// way to have one, so a throwaway card is made, moved to In progress as
    /// a hook would move it (that does not launch it), the chat is brought
    /// up by hand, its answer read, and the card deleted. The answer is kept
    /// on disk, so this happens once per provider, not once per page.
    func load(provider: Tabsh.Provider, cwd: String) async {
        let name = provider.name
        guard models(for: name).isEmpty,
              !probing.contains(name),
              !asked.contains(name),
              let acp = provider.acp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !acp.isEmpty else { return }
        asked.insert(name)
        probing.insert(name)
        defer { probing.remove(name) }

        guard let id = try? await Tabsh.probeSession(cwd: cwd, provider: provider) else { return }
        defer {
            Task<Void, Never> {
                try? await Tabsh.deleteSession(id)
            }
        }
        try? await Tabsh.startChat(id)

        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let select = try? await Tabsh.chatModels(id), !select.options.isEmpty {
                models[name] = select
                if let modes = try? await Tabsh.chatModes(id), !modes.options.isEmpty {
                    self.modes[name] = modes
                }
                save()
                return
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(models: models, modes: modes)) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }
}
