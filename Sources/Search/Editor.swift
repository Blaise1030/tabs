import AppKit
import SwiftUI

// A file on this Mac, edited in a tab of the browser: one of Tabs' own
// pages (see InternalPages.swift), with the address search://editor/<path>,
// so the session keeps it, Back and Forward walk it, and Split View can put
// it beside the page it belongs to.
//
// TextKit does the editing, not a web view: a real NSTextView, with the
// substitutions a code editor must not have, hard tabs of four, and a small
// highlighter for the languages people keep in a folder like this one. The
// editor never parses the language; it colours what looks like a comment, a
// string, a number or a keyword, and leaves the rest alone.

/// The editor's view for one file: header, text, save.
struct EditorPanel: View {
    /// The file's path as the tab carries it (search://editor/<path>).
    let path: String
    @State private var text = ""
    @State private var saved = ""
    @State private var failure: String?
    @State private var exists = true

    private var name: String { (path as NSString).lastPathComponent }
    private var language: Syntax.Language { Syntax.Language(path: path) }
    private var dirty: Bool { exists && text != saved }

    /// How far the code fades before it meets the chrome: solid at the edge
    /// the header sits against, gone by the first line that shows — same
    /// treatment as the agent chat transcript (`TabshAgent` edgeFade).
    private static let fade: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            // A hard cut under the bar clipped mid-line; fade to the pane's
            // ground instead, as the chat list does above the composer.
            CodeEditor(text: $text, language: language, onSave: save)
                .overlay(alignment: .top) { edgeFade(top: true) }
                .overlay(alignment: .bottom) { edgeFade(top: false) }
        }
        .background(Palette.ground)
        .onAppear(perform: load)
    }

    /// One end of the editor, faded to the ground the pane is drawn on.
    private func edgeFade(top: Bool) -> some View {
        LinearGradient(
            colors: top
                ? [Palette.ground, Palette.ground.opacity(0)]
                : [Palette.ground.opacity(0), Palette.ground],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.fade)
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: dirty ? "circle.fill" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(dirty ? Palette.muted : Palette.faint)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(path)
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
                    .lineLimit(1)
            } else if !exists {
                Text("File not found")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            } else if dirty {
                Text("Edited")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Button("Save") { save() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(!dirty)
                .help("Save ⌘S")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Palette.ground)
    }

    private func load() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            // UTF-8 first; a file that isn't is read as MacRoman rather than
            // refused, which is how TextEdit reads what it does not know.
            guard let read = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .macOSRoman)
            else {
                failure = "Can't read this file"
                return
            }
            text = read
            saved = read
            failure = nil
            exists = true
        } catch {
            exists = false
            failure = nil
        }
    }

    private func save() {
        guard exists else { return }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            saved = text
            failure = nil
        } catch {
            failure = "Save failed"
        }
    }
}

// MARK: - TextKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: Syntax.Language
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        scroll.layer?.cornerRadius = Metrics.cardRadius
        scroll.layer?.cornerCurve = .continuous
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        // The same ground the header fades into (see EditorPanel).
        scroll.backgroundColor = Palette.NS.ground
        scroll.borderType = .noBorder

        let view = CodeTextView()
        view.delegate = context.coordinator
        view.onSave = onSave
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.usesFindBar = true
        view.font = Syntax.font
        view.textColor = .textColor
        view.drawsBackground = true
        view.backgroundColor = Palette.NS.ground
        view.string = text
        // Four spaces, and a tab types four spaces.
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = Syntax.space * 4
        paragraph.tabStops = []
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: Syntax.font, .foregroundColor: NSColor.textColor,
                                 .paragraphStyle: paragraph]
        context.coordinator.attach(view)
        Syntax.highlight(view, as: language)
        scroll.documentView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        view.onSave = onSave
        if view.string != text {
            view.string = text
            Syntax.highlight(view, as: language)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        private weak var view: NSTextView?
        private var pending: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        func attach(_ view: NSTextView) { self.view = view }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            // Colours just after the hand stops rather than on every key:
            // highlighting re-attributes the whole document, which is not
            // what should happen between two keystrokes of a word.
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                Syntax.highlight(view, as: self.parent.language)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

/// An NSTextView that saves its file on ⌘S before the menu system can look
/// at the key: the editor is the only thing in the window that has anything
/// to save, and it is the first responder when you press it.
final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // A tab types four spaces, as the file it is in would.
    override func insertTab(_ sender: Any?) {
        insertText(String(repeating: " ", count: 4), replacementRange: selectedRange())
    }
}

// MARK: - Highlighter

enum Syntax {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let space: CGFloat = (" " as NSString).size(withAttributes: [.font: font]).width

    enum Language {
        case swift, javascript, rust, python, go, json, markdown, other

        init(path: String) {
            switch (path as NSString).pathExtension.lowercased() {
            case "swift": self = .swift
            case "js", "jsx", "mjs", "cjs", "ts", "tsx", "astro": self = .javascript
            case "rs": self = .rust
            case "py": self = .python
            case "go": self = .go
            case "json", "jsonc": self = .json
            case "md", "markdown", "mdx": self = .markdown
            default: self = .other
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift:
                return ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
                        "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
                        "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
                        "if", "import", "in", "init", "inout", "internal", "is", "let", "nil",
                        "nonisolated", "open", "operator", "private", "protocol", "public", "repeat",
                        "rethrows", "return", "self", "Self", "static", "struct", "subscript",
                        "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
                        "where", "while", "some", "any", "macro", "package"]
            case .javascript:
                return ["async", "await", "break", "case", "catch", "class", "const", "continue",
                        "default", "delete", "do", "else", "export", "extends", "false", "finally",
                        "for", "from", "function", "if", "import", "in", "instanceof", "let", "new",
                        "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
                        "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
                        "interface", "type", "enum", "implements", "readonly", "as", "satisfies"]
            case .rust:
                return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                        "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
                        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                        "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
            case .python:
                return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                        "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                        "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                        "raise", "return", "True", "try", "while", "with", "yield"]
            case .go:
                return ["break", "case", "chan", "const", "continue", "default", "defer", "else",
                        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                        "package", "range", "return", "select", "struct", "switch", "type", "var"]
            case .json, .markdown, .other:
                return []
            }
        }
    }

    /// One pass over the text, four kinds of span. Cheap enough to run on
    /// every pause in typing, and wrong only in what it colours.
    static func highlight(_ view: NSTextView, as language: Language) {
        guard let storage = view.textStorage, storage.length > 0, storage.length < 400_000 else { return }
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = space * 4
        paragraph.tabStops = []
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor,
                               .paragraphStyle: paragraph], range: whole)
        let ns = text as NSString
        let keywords = language.keywords

        func paint(_ pattern: String, _ colour: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: colour, range: range)
            }
        }

        // Comments first, so a keyword inside one stays a comment.
        switch language {
        case .python:
            paint("(?m)#.*$", .secondaryLabelColor)
        case .markdown:
            paint("(?m)^#{1,6} .*$", .systemBlue)
        default:
            paint("(?s)/\\*.*?\\*/", .secondaryLabelColor)
            paint("(?m)//.*$", .secondaryLabelColor)
        }
        // Strings, then numbers, then the words that are clearly keywords.
        paint("\"(?:\\\\.|[^\"\\\\])*\"", .systemRed)
        paint("'(?:\\\\.|[^'\\\\])*'", .systemRed)
        paint("(?<![\\w.])-?\\d+(?:\\.\\d+)?(?![\\w])", .systemPurple)
        if !keywords.isEmpty, let regex = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*") {
            regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound,
                      keywords.contains(ns.substring(with: range)) else { return }
                storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: range)
            }
        }
        storage.endEditing()
        // The caret and the selection survive the repaint.
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor,
                                 .paragraphStyle: paragraph]
    }
}
