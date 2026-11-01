import AppKit
import SwiftUI

// The page behind New Agent: tabsh's New card, in the browser's own chrome.
// A folder, an agent, a terminal or a chat, a column, and the prompt — the
// same pieces the web app asks for, made here so an agent can be started
// without leaving the browser.
struct AgentComposer: View {
    @ObservedObject var browser: Browser

    @State private var settings: Tabsh.Settings?
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var providerName = ""
    @State private var mode = "tui"
    @State private var status = "in_progress"
    @State private var prompt = ""
    @State private var creating = false
    @State private var failure: String?

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
        provider != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating
    }

    var body: some View {
        ZStack {
            Palette.frame
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    folderChip
                    providerChip
                    modeSwitch
                    Spacer(minLength: 0)
                }

                promptField

                HStack(spacing: 10) {
                    Menu {
                        Button("Backlog") { status = "backlog" }
                        Button("In progress") { status = "in_progress" }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: status == "backlog" ? "tray" : "circle.dotted")
                                .font(.system(size: 10))
                            Text(status == "backlog" ? "Backlog" : "In progress")
                                .font(.system(size: 11.5))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.hover)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Spacer(minLength: 0)

                    if let failure {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.unsafe)
                            .lineLimit(1)
                    }

                    Button(action: create) {
                        Text(creating ? "Starting…" : "Create")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(ready ? Palette.ink : Palette.faint)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                }
            }
            .padding(16)
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.07), radius: 18, y: 4)
            )
            .overlay(
                // The same hairline the new-tab field wears: a light edge
                // that says where the card starts, not a heavy frame.
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .strokeBorder(Palette.muted.opacity(0.30), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private var folderChip: some View {
        Button(action: chooseFolder) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(folder)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.hover)
            )
        }
        .buttonStyle(.plain)
        .help("Choose the folder the agent starts in")
    }

    private var providerChip: some View {
        Menu {
            ForEach(providers) { item in
                Button(item.name) { providerName = item.name }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                Text(provider?.name ?? "Agent")
                    .font(.system(size: 11.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.hover)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton("Terminal", value: "tui")
            modeButton("Chat", value: "ui")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.hover)
        )
        .fixedSize()
    }

    private func modeButton(_ title: String, value: String) -> some View {
        let selected = mode == value
        return Text(title)
            .font(.system(size: 11.5, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Palette.ink : Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Palette.ground : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onTapGesture { mode = value }
    }

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $prompt)
                // The same face and size as the new-tab field, so the
                // placeholder reads at the same weight when it goes.
                .font(.system(size: 15.5))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(height: 120)
            if prompt.isEmpty {
                Text("What should the agent do?")
                    .font(.system(size: 15.5))
                    .foregroundStyle(Palette.ink.opacity(0.3))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }

    private func load() async {
        do {
            let settings = try await Tabsh.settings()
            self.settings = settings
            if providerName.isEmpty {
                let list = settings.providers.isEmpty ? Tabsh.stockProviders : settings.providers
                providerName = settings.agentProvider ?? list.first?.name ?? ""
            }
            if let saved = settings.agentMode, saved == "ui" || saved == "tui" {
                mode = saved
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func create() {
        guard let provider, ready else { return }
        creating = true
        failure = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                let session = try await Tabsh.createAgent(cwd: folder, prompt: text,
                                                          provider: provider, mode: mode, status: status)
                browser.putAway(.agentComposer)
                if mode == "ui" {
                    browser.show(InternalPage(.agent, session.id))
                } else {
                    browser.show(InternalPage(.tabsh, session.id))
                }
            } catch {
                failure = error.localizedDescription
            }
            creating = false
        }
    }
}


