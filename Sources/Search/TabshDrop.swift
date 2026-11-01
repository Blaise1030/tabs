import AppKit
import UniformTypeIdentifiers

// Dropping or pasting files into a terminal, the agent chat, or New Agent.
// Finder gives real paths; some apps only put image bytes on the pasteboard.
// Paths are shell-quoted for the terminal (as the web's drop.ts does); chat
// and New Agent keep them as attachments until send/create uploads them.

enum TabshDrop {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp",
        "tif", "tiff", "heic",
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Quote a path the way a shell expects it, so spaces and quotes survive
    /// a paste into Claude Code or another TUI.
    static func shellQuote(_ path: String) -> String {
        if path.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func pastePaths(_ urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return urls.map { shellQuote($0.path) }.joined(separator: " ") + " "
    }

    /// File URLs on a dragging pasteboard, plus any image that only arrived
    /// as bytes (written to a temp file so the rest of the pipeline is paths).
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls where url.isFileURL {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                found.append(url.standardizedFileURL)
            }
        }

        // Some apps put a file:// line without registering NSURL.
        if found.isEmpty, let list = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) {
            for line in list.split(whereSeparator: \.isNewline) {
                let raw = String(line).trimmingCharacters(in: .whitespaces)
                guard raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                found.append(url.standardizedFileURL)
            }
        }

        if found.isEmpty, let image = writePasteboardImage(pasteboard) {
            found.append(image)
        }
        return found
    }

    /// Same extraction for SwiftUI's item providers. Prefers the synchronous
    /// file-URL item load — `loadObject(ofClass: URL.self)` is what made
    /// drops look intermittent.
    static func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [URL] = []
        var seen = Set<String>()

        for provider in providers {
            group.enter()
            loadURL(from: provider) { url in
                defer { group.leave() }
                guard let url else { return }
                let path = url.standardizedFileURL.path
                lock.lock()
                if seen.insert(path).inserted {
                    found.append(url.standardizedFileURL)
                }
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(found)
        }
    }

    /// Image bytes on the general pasteboard (⌘V of a screenshot), written
    /// beside the rest of the temp files so the composer can attach them.
    static func pastedImageURLs() -> [URL] {
        writePasteboardImage(NSPasteboard.general).map { [$0] } ?? []
    }

    // MARK: - Loading

    private static func loadURL(from provider: NSItemProvider, done: @escaping (URL?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                DispatchQueue.main.async {
                    done(fileURL(from: item))
                }
            }
            return
        }

        for type in [UTType.png, .jpeg, .gif, .webP, .tiff, .bmp, .heic] {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                DispatchQueue.main.async {
                    guard let data, let url = writeImageData(data, type: type) else {
                        done(nil)
                        return
                    }
                    done(url)
                }
            }
            return
        }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                DispatchQueue.main.async {
                    done(object?.standardizedFileURL)
                }
            }
            return
        }

        done(nil)
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL {
            return url.standardizedFileURL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)?.standardizedFileURL
        }
        if let raw = item as? String, let url = URL(string: raw), url.isFileURL {
            return url.standardizedFileURL
        }
        return nil
    }

    private static func writePasteboardImage(_ pasteboard: NSPasteboard) -> URL? {
        let types: [(NSPasteboard.PasteboardType, UTType)] = [
            (.png, .png),
            (.tiff, .tiff),
        ]
        for (pasteType, ut) in types {
            if let data = pasteboard.data(forType: pasteType) {
                return writeImageData(data, type: ut)
            }
        }
        return nil
    }

    private static func writeImageData(_ data: Data, type: UTType) -> URL? {
        let ext = type.preferredFilenameExtension ?? "png"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabsh-drop-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// A file waiting in a composer. It stays local until send/create, when it
/// is uploaded and its path travels after the message as tabsh does.
struct TabshPendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }
    var isImage: Bool { TabshDrop.isImage(url) }
}

/// An NSTextView that turns file drops and image pastes into attachments
/// instead of inserting raw paths (AppKit's default — and the reason drops
/// looked intermittent when the pointer only sometimes hit the field).
final class TabshAttachTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?

    /// ⌘Return, read here rather than in the delegate's doCommandBy: AppKit
    /// has no key binding for it (StandardKeyBinding.dict maps Return, ⌃Return
    /// and ⌥Return, never ⌘Return), so the command never arrives and the press
    /// would be swallowed. Read by key code, so the keypad's Enter counts too.
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           !hasMarkedText(), let onCommandReturn {
            onCommandReturn()
            return
        }
        super.keyDown(with: event)
    }

    /// The grey line an empty field shows, drawn here rather than laid over
    /// the field: the caret starts at the text container's own origin, so a
    /// label padded by eye sat a few points beside it.
    var placeholder: String? {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    var placeholderColor: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let placeholder, !placeholder.isEmpty else {
            return
        }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(
            at: NSPoint(x: origin.x + padding, y: origin.y),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: placeholderColor,
            ]
        )
    }

    override func didChangeText() {
        super.didChangeText()
        // Typing the last character out brings the placeholder back.
        needsDisplay = true
    }

    func registerFileDrops() {
        registerForDraggedTypes([
            .fileURL, .png, .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
            NSPasteboard.PasteboardType(UTType.png.identifier),
        ])
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = TabshDrop.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles?(urls)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TabshDrop.urls(from: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        TabshDrop.urls(from: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func paste(_ sender: Any?) {
        let images = TabshDrop.pastedImageURLs()
        if !images.isEmpty, let onFiles {
            onFiles(images)
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }
}
