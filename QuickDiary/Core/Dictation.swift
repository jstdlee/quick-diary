import AVFoundation
import Speech

/// On-device speech-to-text for the Quick entry sheet. Nothing is saved or sent anywhere;
/// demo mode never touches the microphone or the speech recognizer (see `LaunchOptions.isDemo`).
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    struct Denied: LocalizedError {
        var errorDescription: String? {
            String(localized: "Speech recognition or the microphone is off for Quick Diary. Turn it on in the Settings app to dictate.")
        }
    }

    /// Starts listening; calls `onChunk` with the growing transcript as speech is recognized.
    /// Stops itself on a final result or an error; `stop()` ends it early.
    func start(onChunk: @escaping (String) -> Void) async throws {
        guard await requestSpeechAuthorization(), await requestMicAuthorization() else { throw Denied() }
        let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw Denied() }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    onChunk(result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }

    private func requestMicAuthorization() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        default: return false
        }
    }
}
