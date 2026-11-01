import AppKit
import SwiftUI

// The terminal's own settings: type size, typeface, and the colours it wears
// in a light window and in a dark one, chosen separately. Kept in the same
// defaults as the rest of Settings, read by the terminal's views and edited
// by the Terminal page (see Settings.swift).

enum TerminalThemeName: String, CaseIterable, Identifiable {
    case standard, solarized, github, dracula, nord, oneDark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .solarized: return "Solarized"
        case .github: return "GitHub"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .oneDark: return "One Dark"
        }
    }

    /// The colours of one preset in one appearance. `standard` is the window's
    /// own ground and ink, so it keeps following Settings › Appearance.
    func colours(dark: Bool) -> TerminalColours {
        switch self {
        case .standard:
            return TerminalColours(background: Palette.NS.ground,
                                   foreground: Palette.NS.ink,
                                   caret: dark ? NSColor(hex: 0x8CC4F8) : NSColor(hex: 0x1A5CC2))
        case .solarized:
            return dark
                ? TerminalColours(background: NSColor(hex: 0x002B36), foreground: NSColor(hex: 0x839496),
                                  caret: NSColor(hex: 0x93A1A1))
                : TerminalColours(background: NSColor(hex: 0xFDF6E3), foreground: NSColor(hex: 0x657B83),
                                  caret: NSColor(hex: 0x586E75))
        case .github:
            return dark
                ? TerminalColours(background: NSColor(hex: 0x0D1117), foreground: NSColor(hex: 0xC9D1D9),
                                  caret: NSColor(hex: 0x58A6FF))
                : TerminalColours(background: NSColor(hex: 0xFFFFFF), foreground: NSColor(hex: 0x24292F),
                                  caret: NSColor(hex: 0x0969DA))
        case .dracula:
            return TerminalColours(background: NSColor(hex: 0x282A36), foreground: NSColor(hex: 0xF8F8F2),
                                   caret: NSColor(hex: 0xBD93F9))
        case .nord:
            return TerminalColours(background: NSColor(hex: 0x2E3440), foreground: NSColor(hex: 0xD8DEE9),
                                   caret: NSColor(hex: 0x88C0D0))
        case .oneDark:
            return TerminalColours(background: NSColor(hex: 0x282C34), foreground: NSColor(hex: 0xABB2BF),
                                   caret: NSColor(hex: 0x61AFEF))
        }
    }
}

struct TerminalColours {
    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
}

@MainActor
final class TerminalPreferences: ObservableObject {
    static let shared = TerminalPreferences()

    private var store: UserDefaults { Store.settings }

    @Published var fontName: String {
        didSet { store.set(fontName, forKey: "terminal.font") }
    }

    @Published var fontSize: Double {
        didSet {
            let clamped = min(24, max(10, fontSize))
            if clamped != fontSize { fontSize = clamped }
            store.set(fontSize, forKey: "terminal.size")
        }
    }

    @Published var lightTheme: TerminalThemeName {
        didSet { store.set(lightTheme.rawValue, forKey: "terminal.lightTheme") }
    }

    @Published var darkTheme: TerminalThemeName {
        didSet { store.set(darkTheme.rawValue, forKey: "terminal.darkTheme") }
    }

    private init() {
        let defaults = Store.settings
        fontName = defaults.string(forKey: "terminal.font") ?? ""
        let size = defaults.object(forKey: "terminal.size") as? Double ?? 13
        fontSize = min(24, max(10, size))
        lightTheme = TerminalThemeName(rawValue: defaults.string(forKey: "terminal.lightTheme") ?? "") ?? .standard
        darkTheme = TerminalThemeName(rawValue: defaults.string(forKey: "terminal.darkTheme") ?? "") ?? .standard
    }

    /// The typeface the terminal is drawn in, or the system's fixed-width one.
    var font: NSFont {
        if !fontName.isEmpty, let chosen = NSFont(name: fontName, size: fontSize) {
            return chosen
        }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Every installed face that can be a terminal's: fixed-width only.
    var fontChoices: [String] {
        let manager = NSFontManager.shared
        let installed = manager.availableFonts.filter { name in
            guard let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch
        }
        return [""] + installed.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func title(for font: String) -> String {
        font.isEmpty ? "System Monospaced" : font
    }

    /// Where a face came from, as the font picker says on the right of its
    /// row. A known Google face says so; the Mac's own faces stay System,
    /// and anything else installed here is simply Installed.
    func source(for font: String) -> String {
        if font.isEmpty { return "System" }
        let name = font.lowercased().replacingOccurrences(of: " ", with: "")
        let system = ["sfmono", "menlo", "monaco", "courier", "andale", "ptmono",
                      "lucidaconsole", "monospaced"]
        if system.contains(where: { name.contains($0) }) { return "System" }
        let google = ["jetbrainsmono", "firacode", "sourcecodepro", "ibmplexmono",
                      "robotomono", "inconsolata", "spacemono", "ubuntumono",
                      "anonymouspro", "dmmono", "geistmono", "notosansmono",
                      "fragmentmono", "commitmono", "intelonemono", "victormono"]
        if google.contains(where: { name.contains($0) }) { return "Google Fonts" }
        return "Installed"
    }

    func colours(dark: Bool, tint: NSColor? = nil) -> TerminalColours {
        if let tint {
            let light = luminance(tint) > 0.5
            return TerminalColours(background: tint,
                                   foreground: light ? NSColor.black : NSColor.white,
                                   caret: light ? NSColor(hex: 0x1A5CC2) : NSColor(hex: 0x8CC4F8))
        }
        return (dark ? darkTheme : lightTheme).colours(dark: dark)
    }

    private func luminance(_ colour: NSColor) -> Double {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}

/// The Terminal section's small proof: the chosen face, size and theme, with
/// the window's own light or dark side. It follows every change in the rows
/// above and below it as they are made.
struct TerminalPreview: View {
    @ObservedObject private var terminal = TerminalPreferences.shared
    @Environment(\.colorScheme) private var scheme

    private var colours: TerminalColours { terminal.colours(dark: scheme == .dark) }
    private var background: Color { Color(nsColor: colours.background) }
    private var foreground: Color { Color(nsColor: colours.foreground) }
    private var prompt: Color { Color(nsColor: colours.caret) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                dot(Color(red: 1, green: 0.37, blue: 0.33))
                dot(Color(red: 1, green: 0.74, blue: 0.24))
                dot(Color(red: 0.28, green: 0.79, blue: 0.36))
                Spacer(minLength: 8)
                Text(terminal.title(for: terminal.fontName))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background.opacity(0.92))

            Rectangle()
                .fill(foreground.opacity(0.12))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("~ ").foregroundStyle(prompt)
                    Text("git status").foregroundStyle(foreground)
                }
                Text("On branch main")
                    .foregroundStyle(foreground.opacity(0.78))
                Text("nothing to commit, working tree clean")
                    .foregroundStyle(foreground.opacity(0.55))
                HStack(spacing: 0) {
                    Text("~ ").foregroundStyle(prompt)
                    Text("█").foregroundStyle(prompt)
                }
            }
            .font(Font(terminal.font))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private func dot(_ colour: Color) -> some View {
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
    }
}

/// The terminal's face, chosen from a searchable list rather than a menu of
/// every installed monospaced face. The right of each row says where the
/// face came from; the search box keeps its focus while the list narrows.
struct TerminalFontPicker: View {
    @ObservedObject private var terminal = TerminalPreferences.shared
    @State private var open = false
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(terminal.title(for: terminal.fontName))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.hover)
            )
        }
        .buttonStyle(.plain)
        .help("Choose the terminal's font")
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var filtered: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return terminal.fontChoices }
        return terminal.fontChoices.filter {
            terminal.title(for: $0).localizedCaseInsensitiveContains(needle)
                || $0.localizedCaseInsensitiveContains(needle)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("Search fonts… (Esc to go back)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                    .onExitCommand { open = false }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rule()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("FONT")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(filtered, id: \.self) { name in
                        Button {
                            terminal.fontName = name
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(terminal.title(for: name))
                                    .font(font(for: name))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text(terminal.source(for: name))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Palette.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(terminal.fontName == name ? Palette.hover : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text("No fonts match.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 340, height: 380)
        .onAppear {
            DispatchQueue.main.async { searching = true }
        }
    }

    private func font(for name: String) -> Font {
        name.isEmpty
            ? .system(size: 12, design: .monospaced)
            : .custom(name, size: 12)
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
