import AVFoundation
import AppKit
import Combine

// The keyboard packs tabsh uses, played for typing in the editor, a terminal
// and the agent composer. It follows the first responder, so typing in a web
// page, a menu or a dialog stays quiet; a shortcut or a lone modifier does
// too. The samples are the same MIT-licensed kbsim and Mechvibes sets, kept
// beside the app (Sounds/*/LICENSE).

enum TypingSoundPack: String, CaseIterable, Identifiable {
    case off
    case mxBlackPBT = "mx-black-pbt"
    case mxBlue = "mx-blue"
    case holyPanda = "holy-panda"
    case gateronBlackInk = "gateron-black-ink"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .mxBlackPBT: return "Cherry MX Black (PBT)"
        case .mxBlue: return "Cherry MX Blue"
        case .holyPanda: return "Holy Panda"
        case .gateronBlackInk: return "Gateron Black Ink"
        }
    }

    /// The release sample's base name, for packs that have one. `nil` means
    /// the pack is press-only.
    var release: String? {
        switch self {
        case .off, .mxBlackPBT: return nil
        case .mxBlue: return "release"
        case .holyPanda, .gateronBlackInk: return "release_key"
        }
    }

    /// The big keys that have samples of their own rather than one of the
    /// five ordinary key presses.
    var specials: Set<String> {
        switch self {
        case .off, .mxBlue: return []
        case .mxBlackPBT, .holyPanda, .gateronBlackInk: return ["space", "enter", "back"]
        }
    }
}

@MainActor
final class TypingSounds: ObservableObject {
    static let shared = TypingSounds()

    @Published var pack: TypingSoundPack {
        didSet {
            Store.settings.set(pack.rawValue, forKey: "typingSound")
            // Warm the new pack off the caller's stack. Settings' picker used
            // to set `pack` on the main thread and then stall on preload —
            // every sample builds four AVAudioPlayers — so the menu looked
            // stuck and the choice never seemed to take.
            let chosen = pack
            DispatchQueue.main.async { [weak self] in
                self?.preload(chosen)
            }
        }
    }

    private var down: Any?
    private var up: Any?
    private var held: [UInt16: String] = [:]
    private var pools: [String: [AVAudioPlayer]] = [:]
    private var next: [String: Int] = [:]
    private var started = false

    private init() {
        let saved = Store.settings.string(forKey: "typingSound") ?? ""
        pack = TypingSoundPack(rawValue: saved) ?? .mxBlackPBT
    }

    /// Once at launch: keep the chosen pack warm and listen for the keys.
    func start() {
        guard !started else { return }
        started = true
        preload(pack)
        // Play after the key is delivered. The monitor runs on the main
        // thread *before* the field sees the event: doing AVAudioPlayer work
        // here made every character wait on audio, and the app beachballed
        // as soon as someone typed in a terminal or the agent composer.
        down = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let caught = event
            DispatchQueue.main.async { self?.pressed(caught) }
            return event
        }
        up = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            let caught = event
            DispatchQueue.main.async { self?.released(caught) }
            return event
        }
    }

    /// A single click, for the settings row when a pack is picked.
    func preview(_ pack: TypingSoundPack) {
        guard pack != .off else { return }
        let chosen = pack
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preload(chosen)
            self.play("press_key3", pack: chosen)
        }
    }

    // MARK: - keys

    private func pressed(_ event: NSEvent) {
        guard pack != .off, !event.isARepeat,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              isTypingSurface(event.window)
        else { return }

        let special = specialName(event.keyCode)
        let hasCharacter = !(event.charactersIgnoringModifiers ?? "").isEmpty
        guard hasCharacter || special != nil else { return }

        play(pressName(special, pack: pack), pack: pack)
        if let release = releaseName(special, pack: pack) {
            held[event.keyCode] = release
        }
    }

    private func released(_ event: NSEvent) {
        guard pack != .off, let name = held.removeValue(forKey: event.keyCode) else { return }
        play(name, pack: pack)
    }

    private func isTypingSurface(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView { return true }
        // SwiftTerm's view is its own first responder.
        return String(describing: type(of: responder)).contains("TerminalView")
    }

    private func specialName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 49: return "space"
        case 36, 76: return "enter"
        case 51, 117: return "back"
        default: return nil
        }
    }

    private func pressName(_ special: String?, pack: TypingSoundPack) -> String {
        if let special, pack.specials.contains(special) {
            return "press_\(special)"
        }
        return "press_key\(Int.random(in: 1...5))"
    }

    private func releaseName(_ special: String?, pack: TypingSoundPack) -> String? {
        guard let release = pack.release else { return nil }
        if let special, pack.specials.contains(special) {
            return "release_\(special)"
        }
        return release
    }

    // MARK: - samples

    private func samples(of pack: TypingSoundPack) -> [String] {
        var names = (1...5).map { "press_key\($0)" }
        for special in pack.specials {
            names.append("press_\(special)")
        }
        if let release = pack.release {
            names.append(release)
            for special in pack.specials {
                names.append("release_\(special)")
            }
        }
        return names
    }

    private func preload(_ pack: TypingSoundPack) {
        guard pack != .off else { return }
        for name in samples(of: pack) {
            _ = players(name, pack: pack)
        }
    }

    private func play(_ name: String, pack: TypingSoundPack) {
        let pool = players(name, pack: pack)
        guard !pool.isEmpty else { return }
        let key = "\(pack.rawValue)/\(name)"
        let at = (next[key] ?? 0) % pool.count
        next[key] = (next[key] ?? 0) + 1
        let player = pool[at]
        player.currentTime = 0
        player.play()
    }

    /// Four players a sample, so fast typing overlaps rather than cutting
    /// the last click short.
    nonisolated static func sampleURL(_ name: String, pack: TypingSoundPack) -> URL? {
        resources.url(
            forResource: name,
            withExtension: "mp3",
            subdirectory: "Sounds/\(pack.rawValue)"
        )
    }

    /// The typing-sound pack bundle `build.sh` puts in `Contents/Resources`.
    ///
    /// Do not use `Bundle.module` here. SwiftPM's generated accessor for an
    /// executable still looks beside the `.app` (and at a hardcoded CI
    /// `.build` path) — never in `Contents/Resources` — and `fatalError`s
    /// when both miss. That is why the v1.0.8 DMG died on every launch
    /// (`could not load resource bundle: from …/Tabs.app/Search_Search.bundle
    /// or /Users/runner/work/…`). Resolve the packaged location ourselves;
    /// if it is missing, typing is simply quiet.
    nonisolated private static let resources: Bundle = {
        let name = "Search_Search.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
        }
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(name)"))
        // `swift run` / a bare `.build` binary: the bundle sits next to the
        // executable, which is also `Bundle.main.bundleURL` for a tool.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let folder = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(folder.appendingPathComponent(name))
        }
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.main
    }()

    private func players(_ name: String, pack: TypingSoundPack) -> [AVAudioPlayer] {
        let key = "\(pack.rawValue)/\(name)"
        if let pool = pools[key] { return pool }
        guard let url = Self.sampleURL(name, pack: pack) else {
            pools[key] = []
            return []
        }

        var pool: [AVAudioPlayer] = []
        for _ in 0..<4 {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = 0.6
            player.prepareToPlay()
            pool.append(player)
        }
        pools[key] = pool
        return pool
    }
}
