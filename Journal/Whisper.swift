import AVFoundation
import Foundation
import Network
import Observation
import WhisperKit

/// The Whisper speech model, run on this iPhone with WhisperKit.
///
/// It rewrites a voice entry once you tap Stop: the audio of that take is
/// held in memory, transcribed here, then dropped. Nothing is written to disk
/// or uploaded. The only network use is the one-time model download from
/// Hugging Face.
@MainActor
@Observable
final class WhisperModel {
    static let shared = WhisperModel()

    enum State: Equatable {
        case off
        /// Waiting for Wi-Fi, or for a tap on Download.
        case notDownloaded
        case downloading(Double)
        /// Loading into memory. The first load after a download takes a few minutes.
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var isOn: Bool

    static let preferredVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private static let onKey = "whisperOn"
    private static let folderKey = "whisperModelFolder"
    private static let loadingKey = "whisperLoadUnfinished"

    private let defaults: UserDefaults
    private var kit: WhisperKit?
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.object(forKey: Self.onKey) as? Bool ?? true
        state = isOn ? .notDownloaded : .off
    }

    var isReady: Bool { state == .ready }

    /// The model this iPhone should run: the large turbo model where the
    /// device supports it, otherwise WhisperKit's own pick for the device.
    static var variant: String {
        let support = WhisperKit.recommendedModels()
        return support.supported.contains(preferredVariant) ? preferredVariant : support.default
    }

    /// Downloads the model if needed and loads it. Safe to call often.
    /// A download only starts on its own on Wi-Fi; `userInitiated` allows cellular.
    func prepare(userInitiated: Bool = false) {
        guard isOn, task == nil, kit == nil else { return }
        // The last load never finished, most likely because iOS ended the app
        // for using too much memory. Don't try again on every launch.
        if defaults.bool(forKey: Self.loadingKey), !userInitiated {
            state = .failed("Whisper didn't finish loading last time.")
            return
        }
        task = Task {
            defer { task = nil }
            do {
                let base = try Self.baseFolder()
                var folder = storedFolder(in: base)
                if folder == nil {
                    if !userInitiated, await Self.onExpensiveNetwork() {
                        state = .notDownloaded
                        return
                    }
                    state = .downloading(0)
                    let url = try await WhisperKit.download(variant: Self.variant, downloadBase: base) { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in WhisperModel.shared.report(fraction) }
                    }
                    guard isOn else { return }
                    defaults.set(Self.relativePath(of: url, in: base), forKey: Self.folderKey)
                    folder = url
                }
                guard let folder, isOn else { return }

                state = .loading
                defaults.set(true, forKey: Self.loadingKey)
                let config = WhisperKitConfig(model: Self.variant, downloadBase: base, modelFolder: folder.path,
                                              verbose: false, logLevel: .error,
                                              prewarm: true, load: true, download: false)
                let loaded = try await WhisperKit(config)
                defaults.set(false, forKey: Self.loadingKey)
                guard isOn else { return }
                kit = loaded
                state = .ready
            } catch {
                defaults.set(false, forKey: Self.loadingKey)
                state = isOn ? .failed(error.localizedDescription) : .off
            }
        }
    }

    func setOn(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: Self.onKey)
        if on {
            state = .notDownloaded
            prepare(userInitiated: true)
        } else {
            task?.cancel()
            kit = nil
            state = .off
            defaults.set(false, forKey: Self.loadingKey)
            defaults.removeObject(forKey: Self.folderKey)
            if let base = try? Self.baseFolder() { try? FileManager.default.removeItem(at: base) }
        }
    }

    /// Transcribes 16 kHz mono samples. Returns nil when Whisper isn't ready,
    /// fails, or hears no speech, so the caller keeps the text it already has.
    func transcribe(_ samples: [Float]) async -> String? {
        guard isOn, let kit, samples.count >= Self.sampleRate / 2 else { return nil }
        let options = DecodingOptions(task: .transcribe, language: Self.language,
                                      skipSpecialTokens: true, chunkingStrategy: .vad)
        guard let results = try? await kit.transcribe(audioArray: samples, decodeOptions: options) else { return nil }
        let text = Self.clean(results.map(\.text).joined(separator: " "))
        return text.isEmpty ? nil : text
    }

    private func report(_ fraction: Double) {
        if case .downloading = state { state = .downloading(fraction) }
    }

    // MARK: - Helpers

    static let sampleRate = 16_000
    /// The audio format Whisper takes.
    nonisolated static var audioFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    private static var language: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Whisper marks noise and silence with tags like `[BLANK_AUDIO]` or
    /// `[MUSIC]`. Drop those and tidy the spacing.
    nonisolated static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\[[A-Za-z_ ]+\]"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func baseFolder() throws -> URL {
        var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // A model that can be downloaded again doesn't belong in backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// The app's container path changes between installs, so the model's
    /// location is remembered relative to the base folder.
    nonisolated static func relativePath(of url: URL, in base: URL) -> String {
        let full = url.standardizedFileURL.path, root = base.standardizedFileURL.path
        guard full.hasPrefix(root) else { return url.lastPathComponent }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func storedFolder(in base: URL) -> URL? {
        guard let relative = defaults.string(forKey: Self.folderKey), !relative.isEmpty else { return nil }
        let url = base.appendingPathComponent(relative, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True on cellular, a hotspot or Low Data Mode.
    private static func onExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The audio of one take, kept in memory only, for Whisper to transcribe
/// after Stop. Filled from the audio thread.
final class SampleCollector: @unchecked Sendable {
    /// Half an hour. Past this the live transcript is kept as it is.
    static let maxSamples = 16_000 * 60 * 30

    private let lock = NSLock()
    private var samples: [Float] = []
    private var overflowed = false

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        append(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        if samples.count + chunk.count > Self.maxSamples {
            overflowed = true
            samples = []
            return
        }
        samples.append(contentsOf: chunk)
    }

    /// Hands over the samples and forgets them. Empty if the take ran too long.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
