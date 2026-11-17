import AVFoundation
import Foundation
import Observation
import Speech

/// Live speech-to-text that runs only on the iPhone.
///
/// `requiresOnDeviceRecognition` is always set, so audio is never sent to
/// Apple's servers. Audio buffers go straight into the recognizer and are
/// never written to disk or uploaded; only the resulting text is kept.
@MainActor
@Observable
final class Dictation {
    private(set) var isRecording = false
    private(set) var transcript = ""
    private(set) var level: Float = 0
    var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    func start() async {
        guard !isRecording else { return }
        error = nil
        transcript = ""

        guard await Self.requestPermissions() else {
            error = "Journal needs microphone and speech recognition access. Turn them on in Settings."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else {
            error = "On-device transcription isn't available for your language, so voice entries are off. You can still type."
            return
        }
        guard recognizer.isAvailable else {
            error = "Speech recognition isn't available right now. Try again in a moment."
            return
        }
        self.recognizer = recognizer

        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if error != nil || isFinal { self.finish() }
                }
            }
        } catch {
            self.error = "Couldn't start recording: \(error.localizedDescription)"
            finish()
        }
    }

    /// Stops listening; the final transcript arrives shortly after.
    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        level = 0
    }

    private func finish() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
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
}
