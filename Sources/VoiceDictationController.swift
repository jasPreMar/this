import AVFoundation
import Foundation
import Speech

final class VoiceDictationController {
    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onLevelChange: ((CGFloat) -> Void)?
    var onTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: .autoupdatingCurrent)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            DispatchQueue.main.async { [state, onStateChange] in
                onStateChange?(state)
            }
        }
    }

    private var latestTranscript = ""
    private var finishWorkItem: DispatchWorkItem?
    private var hasDeliveredResult = false
    private var startGeneration: UInt = 0

    func start() {
        guard case .idle = state else { return }

        let generation = startGeneration
        requestPermissions { [weak self] granted in
            guard let self, self.startGeneration == generation else { return }
            guard granted else {
                self.fail("Microphone and speech access are required.")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.startGeneration == generation else { return }
                self.beginRecognitionSession()
            }
        }
    }

    func stop() {
        guard case .listening = state else { return }

        state = .transcribing
        finishWorkItem?.cancel()

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()

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
        recognitionTask?.cancel()
        teardownRecognitionSession()
        state = .idle
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { microphoneGranted in
            guard microphoneGranted else {
                completion(false)
                return
            }

            SFSpeechRecognizer.requestAuthorization { status in
                completion(status == .authorized)
            }
        }
    }

    private func beginRecognitionSession() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            fail("Speech recognition is unavailable right now.")
            return
        }

        teardownRecognitionSession()
        latestTranscript = ""
        hasDeliveredResult = false
        onLevelChange?(0)

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        self.recognitionRequest = recognitionRequest

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.latestTranscript = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if result.isFinal {
                    self.finish(with: self.latestTranscript)
                    return
                }
            }

            if let error {
                if !self.latestTranscript.isEmpty {
                    self.finish(with: self.latestTranscript)
                } else {
                    self.fail(error.localizedDescription)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            recognitionRequest.append(buffer)
            self.publishLevel(for: buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            state = .listening
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func publishLevel(for buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channel = channelData[0]
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameCount))
        let normalizedLevel = max(0.08, min(CGFloat(rms) * 10, 1))

        DispatchQueue.main.async { [weak self] in
            self?.onLevelChange?(normalizedLevel)
        }
    }

    private func finish(with transcript: String) {
        guard !hasDeliveredResult else { return }
        hasDeliveredResult = true

        finishWorkItem?.cancel()
        recognitionTask?.cancel()
        teardownRecognitionSession()
        state = .idle

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [onTranscript] in
            onTranscript?(trimmed)
        }
    }

    private func fail(_ message: String) {
        finishWorkItem?.cancel()
        recognitionTask?.cancel()
        teardownRecognitionSession()
        state = .failed(message)

        DispatchQueue.main.async { [weak self] in
            self?.onLevelChange?(0)
        }
    }

    private func teardownRecognitionSession() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
    }
}
