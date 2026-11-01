import AppKit
import WebKit

// The colour a page paints itself with, so the browser's own chrome can sit
// on the same slate instead of on a bar of its own.
//
// Measured, never guessed: the colour the page actually paints itself with —
// its root or body background — so the chrome and the ground around the card
// are that same slate, in hard-edged agreement with the page rather than with
// a brand colour the site may only use for a bar of its own. A page that
// paints nothing (a transparent root and body) falls back to its
// `theme-color`, when it names one.
//
// `dark` is that colour's own lightness, and it decides which palette the
// chrome is drawn in — a dark site gets a dark window, a light one a light
// window — so the title, the tabs and the traffic lights stay readable on
// whatever the page chose.
//
// Only the top document is measured: a frame's ground is not the page's. The
// reading is taken once the document is there, and again when it changes its
// look (a class, a media query, a theme-color swapped in).
struct ChromeTheme: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// True when the colour is dark enough that the chrome has to be dark too.
    var dark: Bool

    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// Only the isolated Search world has this handler, as the others do: a page
/// cannot call it or replace its listener.
final class ChromeThemeRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeChromeTheme"

    /// Called on the main thread with what the page measured.
    var measured: ((ChromeTheme) -> Void)?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let r = body["r"] as? Double,
              let g = body["g"] as? Double,
              let b = body["b"] as? Double,
              let dark = body["dark"] as? Bool
        else { return }
        measured?(ChromeTheme(red: r / 255, green: g / 255, blue: b / 255, dark: dark))
    }

    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
    }

    static let script = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.officeChromeTheme;
      if (!handler) return;

      function parse(value) {
        if (!value) return null;
        const probe = document.createElement('span');
        probe.style.color = value;
        document.documentElement.appendChild(probe);
        const out = getComputedStyle(probe).color;
        probe.remove();
        const m = out.match(/rgba?\\(([^)]+)\\)/);
        if (!m) return null;
        const p = m[1].split(/[\\s,\\/]+/).map(Number);
        if (p.length < 3 || p.some(Number.isNaN)) return null;
        return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
      }

      function themeColour() {
        const metas = Array.from(document.querySelectorAll('meta[name="theme-color"]'));
        for (const meta of metas) {
          const media = meta.getAttribute('media');
          if (media && !matchMedia(media).matches) continue;
          const c = parse(meta.getAttribute('content'));
          if (c && c.a > 0.5) return c;
        }
        return null;
      }

      function painted() {
        const opaque = c => c && c.a > 0.5;
        const root = parse(getComputedStyle(document.documentElement).backgroundColor);
        if (opaque(root)) return root;
        if (document.body) {
          const body = parse(getComputedStyle(document.body).backgroundColor);
          if (opaque(body)) return body;
        }
        return root || null;
      }

      function report() {
        const c = painted() || themeColour();
        if (!c) return;
        const luminance = (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255;
        try {
          handler.postMessage({ r: c.r, g: c.g, b: c.b, alpha: c.a, dark: luminance < 0.5 });
        } catch (e) {}
      }

      const soon = () => setTimeout(report, 0);
      report();
      setTimeout(report, 120);
      addEventListener('load', soon, true);
      addEventListener('pageshow', soon, true);
      try {
        new MutationObserver(soon).observe(document.documentElement,
          { attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode'] });
        if (document.body) {
          new MutationObserver(soon).observe(document.body,
            { attributes: true, attributeFilter: ['class', 'style'] });
        }
        if (document.head) {
          new MutationObserver(soon).observe(document.head, { childList: true, subtree: true });
        }
      } catch (e) {}
      try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', soon); } catch (e) {}
    })();
    """
}
