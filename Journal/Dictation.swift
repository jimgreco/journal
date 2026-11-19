import AVFoundation
import Foundation
import Observation
import Speech

/// Live speech-to-text that runs only on the iPhone.
///
/// Uses the iOS 26 `SpeechTranscriber` model, which runs entirely on the
/// device. While that model is still downloading, or where it isn't
/// supported, it falls back to the older recognizer with
/// `requiresOnDeviceRecognition` set. Either way audio buffers go straight
/// into the recognizer and are never written to disk or uploaded; only the
/// resulting text is kept.
@MainActor
@Observable
final class Dictation {
    private(set) var isRecording = false
    /// Between tapping Speak and the microphone opening.
    private(set) var isPreparing = false
    /// After Stop, while the last words are still being transcribed.
    private(set) var isFinishing = false
    private(set) var transcript = ""
    private var segments = TranscriptSegments()
    private(set) var level: Float = 0
    var error: String?

    var isBusy: Bool { isRecording || isPreparing || isFinishing }

    private let engine = AVAudioEngine()
    /// Bumped on every start and teardown so a late callback from an earlier
    /// session can't touch the one that is running now.
    private var session = 0
    /// Builds the closure that hands microphone buffers, in the given
    /// format, to whichever recognizer is running.
    private var sinkFactory: ((AVAudioFormat) -> ((AVAudioPCMBuffer) -> Void)?)?
    private var observers: [NSObjectProtocol] = []

    // SpeechTranscriber
    private var analyzer: SpeechAnalyzer?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var modelDownload: Task<Void, Never>?

    // Older recognizer
    private var recognizer: SFSpeechRecognizer?
    private var requestBox: RequestBox?
    private var task: SFSpeechRecognitionTask?
    /// Recognizer restarts in a row that produced no words.
    private var emptyRestarts = 0

    func start() async {
        guard !isRecording, !isPreparing else { return }
        // Starting again while the last words of the previous take are still
        // being transcribed: give up on those rather than refuse to listen.
        if isFinishing { tearDown() }
        error = nil
        transcript = ""
        segments = TranscriptSegments()
        emptyRestarts = 0
        session += 1
        let current = session
        isPreparing = true
        defer { isPreparing = false }

        guard await Self.requestPermissions() else {
            error = "Journal needs microphone and speech recognition access. Turn them on in Settings."
            return
        }
        guard session == current else { return }

        do {
            let audio = AVAudioSession.sharedInstance()
            // `.default` keeps the system's gain control and microphone
            // processing on, which `.measurement` switches off: that matters
            // outdoors and in other noisy places.
            try audio.setCategory(.record, mode: .default, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)

            if !(await startAnalyzer(session: current)) {
                guard session == current else { return tearDown() }
                try startOlderRecognizer(session: current)
            }
            // Stop was tapped, or the screen closed, while getting ready.
            guard session == current else { return tearDown() }
            try startAudio()
            observeAudioChanges()
            isRecording = true
        } catch let failure as DictationError {
            fail(failure.message)
        } catch {
            fail("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    /// Stops listening; the last words arrive shortly after, and
    /// `isFinishing` stays true until they have.
    func stop() {
        if isPreparing { session += 1 } // start() notices and backs out
        guard isRecording else { return }
        isRecording = false
        level = 0
        stopAudio()
        isFinishing = true
        let current = session

        if let analyzer {
            analyzerInput?.finish()
            let results = resultsTask
            Task {
                let finishing = Task {
                    _ = try? await analyzer.finalizeAndFinishThroughEndOfInput()
                    await results?.value
                }
                // Never leave the entry stuck on "Finishing".
                let timeout = Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    results?.cancel()
                    await analyzer.cancelAndFinishNow()
                }
                await finishing.value
                timeout.cancel()
                if self.session == current { self.tearDown() }
            }
        } else {
            // The recognizer's final result ends the session; this is the backstop.
            requestBox?.endAudio()
            Task {
                try? await Task.sleep(for: .seconds(5))
                if self.session == current { self.tearDown() }
            }
        }
    }

    // MARK: - SpeechTranscriber

    /// Returns false when the new model can't be used right now, so the
    /// caller falls back to the older recognizer.
    private func startAnalyzer(session current: Int) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let locale else { return false }

        do {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                // The model isn't on this iPhone yet. Fetch it in the
                // background for next time instead of making this entry wait.
                if modelDownload == nil {
                    modelDownload = Task { [weak self] in
                        _ = try? await request.downloadAndInstall()
                        self?.modelDownload = nil
                    }
                }
                return false
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                return false
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            guard session == current else {
                input.finish()
                await analyzer.cancelAndFinishNow()
                return true
            }

            self.analyzer = analyzer
            analyzerInput = input
            sinkFactory = { source in
                guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
                return { buffer in
                    if let converted = Self.convert(buffer, with: converter, to: format) {
                        input.yield(AnalyzerInput(buffer: converted))
                    }
                }
            }
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.session == current else { return }
                        self.segments.set(String(result.text.characters), isFinal: result.isFinal)
                        self.transcript = self.segments.text
                    }
                } catch is CancellationError {
                } catch {
                    guard let self, self.session == current else { return }
                    self.fail("Transcription stopped: \(error.localizedDescription) Your words so far are kept.")
                }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Older recognizer

    private func startOlderRecognizer(session current: Int) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else {
            throw DictationError(message: "On-device transcription isn't available for your language, so voice entries are off. You can still type.")
        }
        guard recognizer.isAvailable else {
            throw DictationError(message: "Speech recognition isn't available right now. Try again in a moment.")
        }
        self.recognizer = recognizer
        let box = RequestBox()
        requestBox = box
        sinkFactory = { _ in { buffer in box.append(buffer) } }
        startRecognitionTask(session: current)
    }

    private func startRecognitionTask(session current: Int) {
        guard let recognizer, let requestBox else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        requestBox.set(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            // On-device recognition ends an utterance after a pause (it
            // then attaches metadata) and starts the next one from empty.
            let utteranceEnded = result?.speechRecognitionMetadata != nil
            let failed = error != nil
            Task { @MainActor in
                // Ignore callbacks from a request that has been replaced.
                guard let self, self.session == current, self.requestBox?.current === request else { return }
                if let text {
                    if !text.isEmpty { self.emptyRestarts = 0 }
                    self.segments.update(text, utteranceEnded: utteranceEnded)
                    self.transcript = self.segments.text
                }
                guard failed || isFinal else { return }
                if self.isRecording {
                    self.recoverRecognition(session: current)
                } else {
                    self.tearDown()
                }
            }
        }
    }

    /// The recognizer gave up on its own (a stretch of noise or silence, or
    /// an internal error) while the microphone is still open. Start a fresh
    /// request and keep everything said so far, rather than going quiet.
    private func recoverRecognition(session current: Int) {
        segments.endUtterance()
        emptyRestarts += 1
        guard emptyRestarts <= 3 else {
            fail("Stopped listening because no speech was heard. Tap Keep talking to carry on.")
            return
        }
        task?.cancel()
        startRecognitionTask(session: current)
    }

    // MARK: - Audio

    private func startAudio() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let sink = sinkFactory?(format) else {
            throw DictationError(message: "The microphone isn't available right now. Try again in a moment.")
        }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            sink(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Headphones connecting, a call ending or Siri finishing all stop the
    /// audio engine. Pick the microphone back up instead of recording nothing.
    private func observeAudioChanges() {
        removeObservers()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeAudio() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
                Task { @MainActor in self?.resumeAudio() }
            }
        ]
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func resumeAudio() {
        guard isRecording else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            stopAudio()
            try startAudio()
        } catch {
            fail("Recording was interrupted. Tap Keep talking to carry on.")
        }
    }

    // MARK: - Ending

    /// Ends the session and says why. The transcript so far is kept.
    private func fail(_ message: String) {
        tearDown()
        error = message
    }

    private func tearDown() {
        session += 1
        stopAudio()
        removeObservers()
        sinkFactory = nil

        analyzerInput?.finish()
        analyzerInput = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil

        requestBox?.endAudio()
        requestBox = nil
        task?.cancel()
        task = nil
        recognizer = nil

        isRecording = false
        isFinishing = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }

    /// Resamples one microphone buffer into the format the model wants.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

private struct DictationError: Error {
    let message: String
}

/// The older recognizer's current request, shared with the audio thread so
/// the request can be replaced without reinstalling the microphone tap.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var current: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func set(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        current?.append(buffer)
    }

    func endAudio() {
        current?.endAudio()
    }
}


/// Joins the utterances of one long dictation.
///
/// The recognizer reports each utterance as a growing, sometimes revised,
/// string, then starts over from empty for the next one. Without this, a new
/// utterance replaced everything said before it.
struct TranscriptSegments {
    private(set) var finished: [String] = []
    private(set) var current = ""

    var text: String { (finished + [current]).filter { !$0.isEmpty }.joined(separator: " ") }

    mutating func update(_ partial: String, utteranceEnded: Bool) {
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.startsOver(previous: current, next: partial) { commit() }
        current = partial
        if utteranceEnded { commit() }
    }

    /// One result from the newer model: a provisional guess at the words
    /// being said now, or the settled text that replaces that guess.
    mutating func set(_ text: String, isFinal: Bool) {
        current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { commit() }
    }

    /// Closes the utterance in progress so a fresh recognizer request
    /// can't overwrite it.
    mutating func endUtterance() {
        commit()
    }

    private mutating func commit() {
        if !current.isEmpty { finished.append(current) }
        current = ""
    }

    /// True when `next` is a fresh utterance rather than a revision of
    /// `previous`: it's shorter and doesn't begin the way `previous` does.
    /// Revisions keep the start stable and usually only grow.
    static func startsOver(previous: String, next: String) -> Bool {
        let p = normalized(previous), n = normalized(next)
        guard !p.isEmpty, !n.isEmpty, n.count < p.count else { return false }
        let probe = String(n.prefix(min(n.count, 6)))
        return !p.hasPrefix(probe)
    }

    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(Character.init))
    }
}
