import AVFoundation
import Foundation
import WhisperKit

final class VoiceDictationController {
    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onLevelChange: ((CGFloat) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?

    private var streamTranscriber: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?
    private var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            DispatchQueue.main.async { [state, onStateChange] in
                onStateChange?(state)
            }
        }
    }

    private(set) var hasTranscribedSpeech = false
    private var latestTranscript = ""
    private var lastPublishedPartialTranscript = ""
    private var finishWorkItem: DispatchWorkItem?
    private var hasDeliveredResult = false
    private var startGeneration: UInt = 0

    // MARK: - Shared WhisperKit instance

    private static var sharedWhisperKit: WhisperKit?
    private static var initTask: Task<WhisperKit, Error>?

    static func getOrInitWhisperKit() async throws -> WhisperKit {
        if let existing = sharedWhisperKit { return existing }
        if let pending = initTask { return try await pending.value }

        let task = Task<WhisperKit, Error> {
            guard let modelPath = Bundle.main.path(forResource: "openai_whisper-tiny.en", ofType: nil) else {
                throw NSError(domain: "VoiceDictation", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Whisper model not found in app bundle"])
            }
            let config = WhisperKitConfig(
                model: "tiny.en",
                modelFolder: modelPath,
                verbose: false,
                logLevel: .error,
                download: false
            )
            let kit = try await WhisperKit(config)
            sharedWhisperKit = kit
            return kit
        }
        initTask = task
        do {
            let kit = try await task.value
            return kit
        } catch {
            initTask = nil
            throw error
        }
    }

    // MARK: - Public API

    func start() {
        guard case .idle = state else { return }

        let generation = startGeneration
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self, self.startGeneration == generation else { return }
            guard granted else {
                self.fail("Microphone access is required.")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.startGeneration == generation else { return }
                self.beginStreamingSession()
            }
        }
    }

    func stop() {
        guard case .listening = state else { return }

        state = .transcribing
        finishWorkItem?.cancel()

        Task { [weak self] in
            await self?.streamTranscriber?.stopStreamTranscription()
        }

        let fallback = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hasDeliveredResult { return }
            self.finish(with: self.latestTranscript)
        }
        finishWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: fallback)
    }

    func cancel() {
        startGeneration &+= 1
        finishWorkItem?.cancel()
        streamTask?.cancel()
        let transcriber = streamTranscriber
        streamTranscriber = nil
        Task {
            await transcriber?.stopStreamTranscription()
        }
        streamTask = nil
        state = .idle
    }

    // MARK: - Private

    private func beginStreamingSession() {
        latestTranscript = ""
        lastPublishedPartialTranscript = ""
        hasDeliveredResult = false
        hasTranscribedSpeech = false
        onLevelChange?(0)

        let generation = startGeneration

        streamTask = Task { [weak self] in
            guard let self else { return }

            do {
                let kit = try await Self.getOrInitWhisperKit()
                guard self.startGeneration == generation else { return }

                guard let tokenizer = kit.tokenizer else {
                    throw NSError(domain: "VoiceDictation", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Tokenizer failed to load"])
                }

                let options = DecodingOptions(
                    language: "en",
                    wordTimestamps: false
                )

                let transcriber = AudioStreamTranscriber(
                    audioEncoder: kit.audioEncoder,
                    featureExtractor: kit.featureExtractor,
                    segmentSeeker: kit.segmentSeeker,
                    textDecoder: kit.textDecoder,
                    tokenizer: tokenizer,
                    audioProcessor: kit.audioProcessor,
                    decodingOptions: options,
                    requiredSegmentsForConfirmation: 2,
                    silenceThreshold: 0.3,
                    useVAD: true,
                    stateChangeCallback: { [weak self] _, newState in
                        self?.handleStreamStateChange(newState)
                    }
                )

                self.streamTranscriber = transcriber

                await MainActor.run { self.state = .listening }
                try await transcriber.startStreamTranscription()

                // Stream ended normally (stopStreamTranscription was called)
                await MainActor.run { [weak self] in
                    guard let self, !self.hasDeliveredResult else { return }
                    self.finish(with: self.latestTranscript)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.latestTranscript.isEmpty {
                        self.finish(with: self.latestTranscript)
                    } else {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handleStreamStateChange(_ newState: AudioStreamTranscriber.State) {
        // Audio level from buffer energy
        let energy = newState.bufferEnergy.last ?? 0
        let normalizedLevel = max(0.08, min(CGFloat(energy) * 10, 1))

        // Build combined text from confirmed + unconfirmed segments
        let confirmedText = newState.confirmedSegments.map(\.text).joined(separator: " ")
        let unconfirmedText = newState.unconfirmedSegments.map(\.text).joined(separator: " ")
        let currentText = newState.currentText
        let parts = [confirmedText, unconfirmedText, currentText]
            .filter { !$0.isEmpty }
        let combined = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onLevelChange?(normalizedLevel)

            // Filter out the "Waiting for speech..." placeholder
            let displayText = combined == "Waiting for speech..." ? "" : combined

            if !displayText.isEmpty, displayText != self.lastPublishedPartialTranscript {
                self.hasTranscribedSpeech = true
                self.latestTranscript = displayText
                self.lastPublishedPartialTranscript = displayText
                self.onPartialTranscript?(displayText)
            }
        }
    }

    private func finish(with transcript: String) {
        guard !hasDeliveredResult else { return }
        hasDeliveredResult = true

        finishWorkItem?.cancel()
        teardownStreamingSession()
        state = .idle

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [onTranscript] in
            onTranscript?(trimmed)
        }
    }

    private func fail(_ message: String) {
        finishWorkItem?.cancel()
        teardownStreamingSession()
        state = .failed(message)

        DispatchQueue.main.async { [weak self] in
            self?.onLevelChange?(0)
        }
    }

    private func teardownStreamingSession() {
        streamTask?.cancel()
        streamTask = nil
        streamTranscriber = nil
    }
}
