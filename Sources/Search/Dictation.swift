import AVFoundation
import AppKit
import Speech
import SwiftUI

// Dictation: the Mac's own speech recognition, on this machine and nowhere
// else, for the two places here a prompt is written by voice — the New Agent
// card's prompt and a tabsh session's terminal. It is not a browser feature
// for pages: a page's own dictation is macOS's, and arrives as typing.
//
// Two engines behind one small protocol, because the good one is newer than
// the browser's floor: macOS 26's DictationTranscriber (no time limit, no
// network, no speech-recognition permission), and SFSpeechRecognizer with
// on-device recognition everywhere before it. Both are told to stay on this
// Mac; a Mac that cannot recognise offline says so rather than sending a
// voice to a server, which is the one promise this app makes everywhere.
//
// The words arrive twice — once still being revised, once settled — as
// Apple's recognisers work. Only the settled ones are typed into the field;
// the pill shows both, so what you said is readable while you say it.

/// What has been heard: the settled words, and the tail still being revised.
/// A recogniser rewrites the tail — "to" becomes "too", then "to the" — so
/// it is kept apart until the recogniser stops revising it.
struct HeardText: Equatable {
    private(set) var settled = ""
    private(set) var pending = ""
    /// The last segment kept, so a finalization that arrives twice (or a
    /// repeated one-word reply) does not say it twice.
    private var lastKept = ""

    init() {}

    /// The tail as it stands now, not yet typed anywhere.
    mutating func revise(_ segment: String) {
        pending = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The run ended without settling the tail: it is not typed.
    mutating func dropTail() { pending = "" }

    /// The recogniser has finished with a segment: keep it, once, and say
    /// what to type. Empty when there is nothing new.
    mutating func settle(_ segment: String) -> String? {
        let clean = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        guard !clean.isEmpty, clean != lastKept else { return nil }
        lastKept = clean
        settled = settled.isEmpty ? clean : settled + " " + clean
        return clean
    }

    /// Everything, settled and still being revised, for the pill.
    var shown: String {
        if pending.isEmpty { return settled }
        return settled.isEmpty ? pending : settled + " " + pending
    }

    var isEmpty: Bool { settled.isEmpty && pending.isEmpty }
}

/// Why dictation could not start, in words a person reads rather than a
/// code.
enum DictationTrouble: LocalizedError {
    case noMicrophone
    case microphoneNotAllowed
    case speechNotAllowed
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone is available."
        case .microphoneNotAllowed:
            return "Tabs may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .speechNotAllowed:
            return "Tabs may not use speech recognition. Allow it in System Settings › Privacy & Security › Speech Recognition."
        case .unsupported(let language):
            return "Offline dictation is not available for \(language) on this Mac."
        }
    }
}

/// One recogniser, whichever the Mac can run. `hear` is told each settled
/// segment and each revised tail; `end` once, when the recogniser is done,
/// with what went wrong if anything did.
@MainActor
protocol DictationEngine: AnyObject {
    func start(hear: @escaping @MainActor (_ segment: String, _ settled: Bool) -> Void,
               end: @escaping @MainActor (_ trouble: String?) -> Void) async throws
    /// No more audio: finish what was heard and give the last words.
    func stop()
    /// Throw away what was heard and let the microphone go now.
    func cancel()
}

@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
    }

    @Published private(set) var phase: Phase = .idle
    /// What the pill shows: settled words and the tail being revised.
    @Published private(set) var shown = ""
    /// A refusal or a failure, said in the pill for a few seconds.
    @Published private(set) var trouble: String?

    private var engine: (any DictationEngine)?
    private var heard = HeardText()
    /// Where settled words go, as they settle. One run at a time; a second
    /// start while listening stops the first.
    private var into: ((String) -> Void)?
    private var keys: Any?
    private var panel: DictationPanel?
    private var watchdog: DispatchWorkItem?
    /// Which run the callbacks belong to: a cancelled run's late result must
    /// not type into the next one's field.
    private var run: UUID?

    var busy: Bool { phase != .idle }

    // MARK: - starting and stopping

    /// Starts listening, and calls `words` with each piece as it settles.
    /// Nothing is typed for a word still being revised.
    func begin(into words: @escaping (String) -> Void) {
        if busy { stop(); return }
        let run = UUID()
        self.run = run
        heard = HeardText()
        shown = ""
        trouble = nil
        into = words
        phase = .preparing
        refresh()
        Task { [weak self] in await self?.start(run) }
    }

    /// The user is done: stop the microphone, keep the last words, and close.
    func stop() {
        guard busy else { return }
        engine?.stop()
        // The final result comes a moment after the microphone goes quiet.
        // If it never comes (no speech, a wedged recogniser), the run closes
        // anyway rather than leaving a pill up for ever.
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// The user changed their mind: nothing said is typed.
    func cancel() {
        guard busy else { return }
        engine?.cancel()
        finish(nil)
    }

    /// The menu's one command: start dictating into the session tab in
    /// front, or stop if it is already listening. The words are typed into
    /// the shell, not run — what you said is on the prompt to fix or send.
    func toggle(intoSession session: String) {
        if busy {
            stop()
            return
        }
        begin { words in
            TabshTerminals.shared.terminal(for: session).view.send(txt: words + " ")
        }
    }

    private func start(_ run: UUID) async {
        do {
            guard await Dictation.microphoneAllowed() else { throw DictationTrouble.microphoneNotAllowed }
            let engine: any DictationEngine
            if #available(macOS 26, *) {
                engine = AnalyzerDictation()
            } else {
                engine = RecognizerDictation()
            }
            self.engine = engine
            try await engine.start(
                hear: { [weak self] segment, settled in
                    guard let self, self.run == run else { return }
                    if settled {
                        if let words = self.heard.settle(segment) { self.into?(words) }
                    } else {
                        self.heard.revise(segment)
                    }
                    self.shown = self.heard.shown
                    self.refresh()
                },
                end: { [weak self] trouble in
                    guard let self, self.run == run else { return }
                    self.finish(trouble)
                }
            )
            // Cancelled while the model was still being made ready.
            guard self.run == run, (self.engine as AnyObject?) === (engine as AnyObject) else { return }
            phase = .listening
            watchKeys()
            refresh()
        } catch {
            guard self.run == run else { return }
            finish(error.localizedDescription)
        }
    }

    /// The run is over, however it ended. `trouble` is said in the pill.
    private func finish(_ trouble: String?) {
        guard run != nil else { return }
        // The run's own callbacks stop counting from here: a result that
        // lands while the engine is being torn down is not typed.
        run = nil
        watchdog?.cancel()
        watchdog = nil
        unwatchKeys()
        // A run may be closed while its engine is still making itself ready
        // (the model downloading) or has already ended; either way the
        // microphone is let go here, before the engine is dropped.
        engine?.cancel()
        engine = nil
        into = nil
        phase = .idle
        heard.dropTail()
        shown = trouble ?? ""
        self.trouble = trouble
        guard let panel else { return }
        if trouble == nil {
            panel.orderOut(nil)
        } else {
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.phase == .idle, self.trouble == trouble else { return }
                self.trouble = nil
                self.shown = ""
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: - the keys, while listening

    /// Return keeps what was said and stops; Escape throws it away. Read
    /// here, ahead of whatever has focus, so the pill works without being
    /// clicked — it never takes the keyboard.
    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.phase == .listening else { return event }
            switch event.keyCode {
            case 53: // escape
                self.cancel()
                return nil
            case 36, 76: // return, keypad enter
                self.stop()
                return nil
            default:
                return event
            }
        }
    }

    private func unwatchKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    // MARK: - the pill

    private func refresh() {
        guard phase != .idle || trouble != nil else {
            panel?.orderOut(nil)
            return
        }
        let panel: DictationPanel
        if let made = self.panel {
            panel = made
        } else {
            panel = DictationPanel(dictation: self)
            self.panel = panel
        }
        panel.fit()
        // A test run keeps the pill off every screen, as the recording pill
        // does: the model is what is tested there (see Bench).
        guard !Store.testing else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - permission

    /// The microphone belongs to the app, not to a site: one prompt, once,
    /// with the sentence `build.sh` puts in Info.plist.
    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

// MARK: - macOS 26 and later: DictationTranscriber

@available(macOS 26, *)
@MainActor
private final class AnalyzerDictation: DictationEngine {
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var audio: AVAudioEngine?
    private var starting: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var ended: ((String?) -> Void)?
    private var done = false

    func start(hear: @escaping @MainActor (String, Bool) -> Void,
               end: @escaping @MainActor (String?) -> Void) async throws {
        ended = end
        let wanted = Locale.current
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) ?? wanted
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)

        // The words this Mac knows. A language never used with dictation
        // before needs its model once; it is downloaded here, on device,
        // and never sent anywhere.
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .unsupported:
            throw DictationTrouble.unsupported(locale.identifier)
        default:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationTrouble.unsupported(locale.identifier)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        // `start` runs with the stream, to its end; it is started here and
        // left to the end of dictation rather than held open before the
        // microphone begins.
        starting = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                // Cancelling ends the analysis this way; the run is already
                // over by then.
                await MainActor.run { self?.close(error.localizedDescription) }
            }
        }
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let words = String(result.text.characters)
                    await MainActor.run {
                        hear(words, result.isFinal)
                    }
                }
            } catch {
                // A cancelled analysis throws on the way out; the run is
                // already over by then.
            }
            await MainActor.run { self?.close(nil) }
        }

        try listen(into: feed, format: format)
    }

    private func listen(into feed: AsyncStream<AnalyzerInput>.Continuation,
                        format: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let natural = input.inputFormat(forBus: 0)
        guard natural.sampleRate > 0 else { throw DictationTrouble.noMicrophone }
        let pipe = try AudioPipe(from: natural, to: format)
        input.installTap(onBus: 0, bufferSize: 2048, format: natural) { buffer, _ in
            guard let converted = pipe.take(buffer) else { return }
            feed.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationTrouble.noMicrophone
        }
        audio = engine
    }

    func stop() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        // The end of the audio tells the analyzer to settle what it has and
        // hand over the last words.
        feed?.finish()
        feed = nil
    }

    func cancel() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        feed?.finish()
        feed = nil
        results?.cancel()
        results = nil
        starting?.cancel()
        starting = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
        close(nil)
    }

    /// `end` exactly once, whichever of the results and the user got here
    /// first.
    private func close(_ trouble: String?) {
        guard !done else { return }
        done = true
        ended?(trouble)
    }
}

// MARK: - macOS 14–25: SFSpeechRecognizer, on device

@MainActor
private final class RecognizerDictation: DictationEngine {
    private var audio: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var ended: ((String?) -> Void)?
    private var done = false

    func start(hear: @escaping @MainActor (String, Bool) -> Void,
               end: @escaping @MainActor (String?) -> Void) async throws {
        ended = end

        let granted = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { resume.resume(returning: $0 == .authorized) }
        }
        guard granted else { throw DictationTrouble.speechNotAllowed }

        let locale = Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DictationTrouble.unsupported(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw DictationTrouble.unsupported(locale.identifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // The one setting that keeps this app's promise: no server.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    hear(result.bestTranscription.formattedString, result.isFinal)
                }
                if result?.isFinal == true {
                    self.close(nil)
                } else if let error {
                    self.close(error.localizedDescription)
                }
            }
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let natural = input.inputFormat(forBus: 0)
        guard natural.sampleRate > 0 else { throw DictationTrouble.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: natural) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationTrouble.noMicrophone
        }
        audio = engine
    }

    func stop() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        // End of audio asks the recogniser for its final result, which
        // closes the run.
        request?.endAudio()
    }

    func cancel() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        task?.cancel()
        task = nil
        request = nil
        close(nil)
    }

    private func close(_ trouble: String?) {
        guard !done else { return }
        done = true
        ended?(trouble)
    }
}

// MARK: - the microphone's format, for the analyzer's

/// A buffer from the microphone (48 kHz, float) is not what a transcriber
/// asks for, so each one is converted before it is fed in. `AVAudioConverter`
/// rather than `AnalyzerInputConverter`, which needs macOS 27.
private final class AudioPipe {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat
    private let ratio: Double

    init(from natural: AVAudioFormat, to format: AVAudioFormat) throws {
        self.format = format
        ratio = natural.sampleRate > 0 ? format.sampleRate / natural.sampleRate : 1
        if natural.isEqual(format) {
            converter = nil
        } else if let converter = AVAudioConverter(from: natural, to: format) {
            self.converter = converter
        } else {
            throw DictationTrouble.noMicrophone
        }
    }

    /// Only ever called from the audio engine's tap thread.
    func take(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, condition in
            if given {
                condition.pointee = .noDataNow
                return nil
            }
            given = true
            condition.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

// MARK: - the pill

/// "Listening · what you said — Done · ×", at the foot of the screen, for as
/// long as dictation runs. It never takes the keyboard: the field you were
/// in keeps it, and the words go there when they settle.
private final class DictationPanel: NSPanel {
    private let content: NSHostingView<DictationPill>

    init(dictation: Dictation) {
        content = NSHostingView(rootView: DictationPill(dictation: dictation))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Its size for what it says, at the foot of the screen, centred.
    func fit() {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + 24,
                           width: size.width, height: size.height)
        content.frame = NSRect(origin: .zero, size: size)
        setFrame(isVisible ? NSRect(origin: self.frame.origin, size: size) : frame, display: true)
    }
}

struct DictationPill: View {
    @ObservedObject var dictation: Dictation

    private var title: String {
        if dictation.trouble != nil { return "Dictation stopped" }
        return dictation.phase == .preparing ? "Getting ready…" : "Listening"
    }

    private var line: String {
        if let trouble = dictation.trouble { return trouble }
        if !dictation.shown.isEmpty { return dictation.shown }
        return dictation.phase == .preparing ? "The speech model is loading." : "Speak."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: dictation.trouble == nil ? "mic.fill" : "mic.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dictation.trouble == nil ? Color(nsColor: .systemRed) : Palette.unsafe)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer(minLength: 4)

            if dictation.trouble == nil {
                Button { dictation.stop() } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keep what was said")

                Button { dictation.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Palette.hover, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Throw away what was said")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation")
    }
}
