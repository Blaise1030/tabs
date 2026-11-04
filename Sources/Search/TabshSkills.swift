import Foundation
import SwiftUI

// Agent skills as Cursor keeps them: a folder with a `SKILL.md`, under the
// project's `.cursor/skills` or the user's `~/.cursor/skills`. Typing `/` in
// the composer opens a searchable list of them (see TabshComposerSkillPicker).

struct TabshSkill: Identifiable, Equatable, Hashable {
    /// Absolute path to `SKILL.md` — also the stable identity.
    let path: String
    let name: String
    let summary: String
    /// Where it was found, for the quiet label beside the name.
    let source: String

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
}

enum TabshSkills {
    /// Project folders first, then the user's personal skills, then Cursor's
    /// built-in ones. Same name in two places: the earlier source wins.
    static func list(projectPath: String?) -> [TabshSkill] {
        var seen = Set<String>()
        var out: [TabshSkill] = []

        func take(_ skills: [TabshSkill]) {
            for skill in skills {
                let key = skill.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(skill)
            }
        }

        if let projectPath, !projectPath.isEmpty {
            let root = URL(fileURLWithPath: projectPath, isDirectory: true)
            take(scan(root.appendingPathComponent(".cursor/skills", isDirectory: true),
                      source: "Project"))
            take(scan(root.appendingPathComponent(".agents/skills", isDirectory: true),
                      source: "Project"))
            take(scan(root.appendingPathComponent("skill", isDirectory: true),
                      source: "Project"))
            take(scan(root.appendingPathComponent("skills", isDirectory: true),
                      source: "Project"))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        take(scan(home.appendingPathComponent(".cursor/skills", isDirectory: true),
                  source: "Personal"))
        take(scan(home.appendingPathComponent(".agents/skills", isDirectory: true),
                  source: "Personal"))
        take(scan(home.appendingPathComponent(".cursor/skills-cursor", isDirectory: true),
                  source: "Cursor"))

        return out.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// One directory of skill folders (`name/SKILL.md`). Symlinks count —
    /// personal skills often point at another checkout.
    private static func scan(_ directory: URL, source: String) -> [TabshSkill] {
        let files = FileManager.default
        var isDir: ObjCBool = false
        guard files.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue,
              let kids = try? files.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return kids.compactMap { folder -> TabshSkill? in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isFolder = values?.isDirectory == true || values?.isSymbolicLink == true
            guard isFolder else { return nil }
            let skillFile = folder.appendingPathComponent("SKILL.md")
            guard files.fileExists(atPath: skillFile.path) else { return nil }
            return read(skillFile, fallbackName: folder.lastPathComponent, source: source)
        }
    }

    private static func read(_ file: URL, fallbackName: String, source: String) -> TabshSkill {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let meta = frontmatter(text)
        let name = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackName
        let summary = meta.summary?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return TabshSkill(path: file.standardizedFileURL.path,
                          name: name,
                          summary: summary,
                          source: source)
    }

    /// The YAML block Cursor skills open with: `name` and `description` only.
    private static func frontmatter(_ text: String) -> (name: String?, summary: String?) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else { return (nil, nil) }
        let rest = normalized.dropFirst(3).drop(while: { $0 == "\n" })
        guard let end = rest.range(of: "\n---") else { return (nil, nil) }
        let block = String(rest[..<end.lowerBound])

        var name: String?
        var summary: String?
        var collectingSummary = false
        var summaryLines: [String] = []

        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if collectingSummary {
                if raw.hasPrefix(" ") || raw.hasPrefix("\t") || raw.isEmpty {
                    summaryLines.append(raw.trimmingCharacters(in: .whitespaces))
                    continue
                }
                collectingSummary = false
            }
            if raw.hasPrefix("name:") {
                name = String(raw.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if raw.hasPrefix("description:") {
                let value = String(raw.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines)
                if value == ">-" || value == "|" || value == ">" || value.isEmpty {
                    collectingSummary = true
                    summaryLines = []
                } else {
                    summary = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }
        if collectingSummary || summary == nil, !summaryLines.isEmpty {
            summary = summaryLines.filter { !$0.isEmpty }.joined(separator: " ")
        }
        return (name, summary)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// `/` in the composer: skills under the project and the user's Cursor
/// folders, searchable the same way `@` lists project files.
struct TabshComposerSkillPicker: View {
    /// Session / New Agent folder used to find project skills. Nil still
    /// lists personal and Cursor skills.
    var projectPath: String?
    let pick: (TabshSkill) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var skills: [TabshSkill] = []
    @State private var active = 0
    @State private var loading = true
    @FocusState private var focused: Bool

    private var filtered: [TabshSkill] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.summary.localizedCaseInsensitiveContains(needle)
                || $0.source.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading skills…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            } else if filtered.isEmpty {
                Text(skills.isEmpty
                     ? "No skills in this project or ~/.cursor/skills."
                     : "No skills match.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                optionsList
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { load() }
        .onChange(of: query) { _, _ in
            active = filtered.isEmpty ? -1 : 0
        }
        .onKeyPress(.upArrow) {
            active = TabshFolders.moveActive(active, by: -1, count: filtered.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            active = TabshFolders.moveActive(active, by: 1, count: filtered.count)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            TextField("Search skills…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { chooseActive() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.hover)
        )
        .onAppear { focused = true }
    }

    private var optionsList: some View {
        let rows = filtered
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, skill in
                        optionRow(index: index, skill: skill)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.never)
            .frame(height: listHeight(for: rows.count))
            .onChange(of: active) {
                guard active >= 0, active < rows.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(rows[active].id, anchor: .center)
                }
            }
        }
    }

    private static let rowHeight: CGFloat = 44
    private static let listMaxHeight: CGFloat = 280

    private func listHeight(for count: Int) -> CGFloat {
        let rows = CGFloat(count) * Self.rowHeight + CGFloat(max(count - 1, 0)) + 8
        return min(rows, Self.listMaxHeight)
    }

    private func optionRow(index: Int, skill: TabshSkill) -> some View {
        let lit = index == active
        return Button { choose(skill) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("/\(skill.name)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(skill.source)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    if !skill.summary.isEmpty {
                        Text(skill.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lit ? Palette.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Self.rowHeight, alignment: .top)
        .id(skill.id)
        .help(skill.path)
    }

    private func chooseActive() {
        let rows = filtered
        guard active >= 0, active < rows.count else { return }
        choose(rows[active])
    }

    private func choose(_ skill: TabshSkill) {
        pick(skill)
    }

    private func load() {
        loading = true
        let path = projectPath
        // Directory walks stay off the main thread so a large ~/.cursor
        // does not hitch the popover open animation.
        DispatchQueue.global(qos: .userInitiated).async {
            let listed = TabshSkills.list(projectPath: path)
            DispatchQueue.main.async {
                skills = listed
                active = listed.isEmpty ? -1 : 0
                loading = false
            }
        }
    }
}
