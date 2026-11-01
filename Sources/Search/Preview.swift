import AppKit
import SwiftUI
import WebKit

// A file looked at rather than edited: pictures drawn at their own size, and
// Markdown set as the document it is, both in a tab of their own. The editor
// is one button away for anything you then want to change.
//
// Addressed like the editor — search://preview/<path> — so the session keeps
// it, Back and Forward walk it, and Split View can put it beside the page it
// belongs to.
struct PreviewPanel: View {
    let path: String
    @ObservedObject var browser: Browser

    @State private var failure: String?

    private var name: String { (path as NSString).lastPathComponent }
    private var extensionName: String { (path as NSString).pathExtension.lowercased() }
    private var isMarkdown: Bool { ["md", "markdown", "mdown", "mkd"].contains(extensionName) }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Palette.ground)
        .task(id: path) { load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isMarkdown ? "text.document" : "photo")
                .font(.system(size: 10))
                .foregroundStyle(Palette.faint)
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
            Button("Edit") {
                browser.show(InternalPage(.editor, path), inheritingGroup: true)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .help("Open in the editor")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Palette.ground, location: 0),
                    .init(color: Palette.ground.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            VStack(spacing: 6) {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isMarkdown {
            MarkdownWebView(path: path)
        } else {
            imageView
        }
    }

    private var imageView: some View {
        Group {
            if let image = NSImage(contentsOfFile: path) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .scrollIndicators(.never)
            } else {
                Text("This picture can't be read.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load() {
        failure = nil
        guard isMarkdown else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              String(data: data, encoding: .utf8) != nil
                || String(data: data, encoding: .macOSRoman) != nil
        else {
            failure = "This document can't be read."
            return
        }
    }
}

/// Markdown drawn by the browser's own renderer (Markdown.page, the one
/// Reader uses), in a web view that is part of the tab and follows the app's
/// light or dark look. It cannot navigate: a link opens in a tab of its own.
struct MarkdownWebView: NSViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.wantsLayer = true
        web.layer?.masksToBounds = true
        web.layer?.cornerRadius = Metrics.cardRadius
        web.layer?.cornerCurve = .continuous
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = false
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != path else { return }
        context.coordinator.loaded = path
        load(web)
    }

    private func load(_ web: WKWebView) {
        let file = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman)
        else {
            web.loadHTMLString(Self.shell("<p>This document can't be read.</p>"), baseURL: nil)
            return
        }
        let page = Markdown.page(text, base: file.deletingLastPathComponent())
        web.loadHTMLString(Self.shell(page.html), baseURL: file.deletingLastPathComponent())
    }

    private static func shell(_ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 22px 30px 40px; background: transparent;
               font: 13px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
               color: #1b1b1c; max-width: 760px; }
        @media (prefers-color-scheme: dark) { body { color: #e9e9ea; } }
        h1, h2, h3, h4 { font-weight: 600; line-height: 1.25; margin: 1.2em 0 .45em; }
        h1 { font-size: 24px; } h2 { font-size: 19px; } h3 { font-size: 16px; } h4 { font-size: 14px; }
        p, ul, ol, blockquote, table, pre { margin: .55em 0 .9em; }
        ul, ol { padding-left: 1.4em; }
        a { color: #0b63ce; text-decoration: none; }
        @media (prefers-color-scheme: dark) { a { color: #6cb6ff; } }
        code { font: 12px/1.45 "SF Mono", Menlo, monospace; padding: 1px 4px;
               border-radius: 4px; background: rgba(127,127,127,.18); }
        pre { padding: 10px 12px; border-radius: 8px; overflow-x: auto;
              background: rgba(127,127,127,.12); }
        pre code { padding: 0; background: none; }
        blockquote { margin-left: 0; padding-left: 12px; color: #6f7278;
                     border-left: 3px solid rgba(127,127,127,.4); }
        hr { border: 0; border-top: 1px solid rgba(127,127,127,.3); margin: 1.4em 0; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; text-align: left; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        </style></head><body>\(body)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The first load is this document; a link is somewhere else, and
            // opens where a link belongs — another tab.
            if navigationAction.navigationType == .other || navigationAction.request.url == nil {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, url.scheme != "about" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

/// Markdown set with the system's own parser: headings and code blocks get
/// the sizes and weights a reader expects, links keep their colour, and the
/// rest is left as the text says.
enum PreviewMarkdown {
    static func attributed(_ text: String) -> AttributedString? {
        var attributed: AttributedString
        do {
            attributed = try AttributedString(markdown: text)
        } catch {
            return nil
        }
        for run in attributed.runs {
            var size: CGFloat = 13
            var weight: Font.Weight = .regular
            var design: Font.Design = .default

            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        size = [24, 20, 17, 15, 14, 13][min(max(level, 1), 6) - 1]
                        weight = .semibold
                    case .codeBlock:
                        design = .monospaced
                        size = 12
                    default:
                        break
                    }
                }
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                design = .monospaced
            }
            attributed[run.range].font = .system(size: size, weight: weight, design: design)
        }
        return attributed
    }
}
