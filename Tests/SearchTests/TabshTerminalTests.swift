import AppKit
import XCTest
@testable import Search

/// The terminal's socket says where it left off, so a reattach can be sent
/// only the bytes it missed rather than the whole scrollback again.
final class TabshTerminalTests: XCTestCase {
    func testASocketNamesTheEpochAndOffsetItHasSeen() throws {
        let url = try XCTUnwrap(Tabsh.socketURL(session: "abc-1", token: "t",
                                                resume: ("e-1", 42)))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(parts.path, "/ws")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "id" }?.value, "abc-1")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "token" }?.value, "t")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "resume" }?.value, "e-1:42")
    }

    /// An agent at work animates its title with a braille spinner (Claude
    /// Code and friends); that spin, not the words after it, is the signal.
    func testASpinnerTitleIsWorking() {
        XCTAssertEqual(TabshAgentActivity(title: "⠂ Fix the login crash"), .working)
        XCTAssertEqual(TabshAgentActivity(title: "⠋ Working…"), .working)
    }

    /// The still mark an agent leaves in its title at rest is Ready, even
    /// though no turn has finished — it must not read as Completed.
    func testAStillTitleIsReady() {
        XCTAssertEqual(TabshAgentActivity(title: "✳ Claude Code"), .ready)
        XCTAssertEqual(TabshAgentActivity(title: "✳ Fix the login crash"), .ready)
    }

    func testAWaitingTitleNeedsInput() {
        XCTAssertEqual(TabshAgentActivity(title: "Claude Code — waiting for input"), .needsInput)
        XCTAssertEqual(TabshAgentActivity(title: "Allow this command? (y/n)"), .needsInput)
    }

    /// A task summary that merely mentions permission is not a request for
    /// it: the still title stays Ready.
    func testATaskAboutPermissionIsNotARequest() {
        XCTAssertEqual(TabshAgentActivity(title: "✳ Fix the permission bug"), .ready)
    }

    /// A plain shell's title (user, host, folder) says nothing about an
    /// agent, so the header stays bare.
    func testAPlainShellTitleSaysNothing() {
        XCTAssertNil(TabshAgentActivity(title: "blaise@mac: ~/Developer/tabs-browser"))
        XCTAssertNil(TabshAgentActivity(title: "zsh"))
        XCTAssertNil(TabshAgentActivity(title: "  "))
    }

    func testAFreshSocketAsksForTheWholeScrollback() throws {
        let url = try XCTUnwrap(Tabsh.socketURL(session: "abc-1", token: "t"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(parts.queryItems?.first { $0.name == "resume" })
    }

    /// The standard theme is the window's own ground and ink. The palette's
    /// greys are dynamic and SwiftTerm resolves them as it is handed the
    /// colour, so they must be resolved for the pane's appearance first —
    /// otherwise a dark browser's terminal was drawn on the light ground.
    func testTheStandardTerminalFollowsTheWindowsAppearance() {
        let dark = TerminalThemeName.standard.colours(dark: true)
        // Read as the light appearance would: a resolved dark colour stays
        // dark, while the raw palette colour would turn white.
        XCTAssertLessThan(luminance(dark.background, as: .aqua), 0.5, "a dark window's terminal is dark")
        XCTAssertGreaterThan(luminance(dark.foreground, as: .aqua), 0.5, "and its ink is light")

        let light = TerminalThemeName.standard.colours(dark: false)
        XCTAssertGreaterThan(luminance(light.background, as: .darkAqua), 0.5, "a light window's terminal is light")
        XCTAssertLessThan(luminance(light.foreground, as: .darkAqua), 0.5, "and its ink is dark")
    }

    private func luminance(_ colour: NSColor, as appearance: NSAppearance.Name) -> CGFloat {
        var resolved = colour
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = colour.usingColorSpace(.sRGB) ?? colour
        }
        guard let rgb = resolved.usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
