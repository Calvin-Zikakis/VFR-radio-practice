import Foundation
import Speech
import AVFoundation

/// Speech-to-text supporting two input styles:
///  - `listenWithSilence(timeout:)` — hands-free: auto-finalizes after the pilot
///    goes quiet for `timeout` seconds.
///  - `start()` / `stopAndCollect()` — push-to-talk: caller controls start/stop
///    (press = start, release = stop), like a real radio PTT.
@MainActor
final class SpeechRecognizer: NSObject, ObservableObject {
    enum RecognizerError: Error, LocalizedError {
        case notAuthorized, recognizerUnavailable, audioSession(String)
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech or microphone permission was denied. Enable it in Settings."
            case .recognizerUnavailable: return "Speech recognition is unavailable on this device."
            case .audioSession(let s): return "Audio session error: \(s)"
            }
        }
    }

    @Published private(set) var isListening = false
    @Published private(set) var partialText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var continuation: CheckedContinuation<String, Error>?
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var finalTimer: Timer?
    private var latest = ""
    private var autoSilence: TimeInterval?
    private var torn = true

    // `nonisolated`: the TCC permission callbacks fire on a background queue.
    // If this method were main-actor-isolated, those callbacks would inherit
    // main-actor isolation and crash (dispatch queue assertion) when invoked
    // off the main thread. It touches no isolated state, so nonisolated is safe.
    nonisolated func requestAuthorization() async -> Bool {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioApplication.shared.recordPermission
        print("VFR: auth — speech=\(speechStatus.rawValue) mic=\(micStatus.rawValue)")

        // Only request when not yet determined; re-requesting an already-granted
        // permission can hang because the completion handler never fires.
        let speechOK: Bool
        if speechStatus == .authorized {
            speechOK = true
        } else if speechStatus == .notDetermined {
            speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization {
                    print("VFR: speech auth callback \($0.rawValue)")
                    c.resume(returning: $0 == .authorized)
                }
            }
        } else {
            speechOK = false
        }
        print("VFR: speechOK=\(speechOK)")
        guard speechOK else { return false }

        if micStatus == .granted { return true }
        if micStatus == .denied { return false }
        let micOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission {
                print("VFR: mic auth callback \($0)")
                c.resume(returning: $0)
            }
        }
        print("VFR: micOK=\(micOK)")
        return micOK
    }

    // MARK: - Push-to-talk (manual)

    /// Begin capturing. Call `stopAndCollect()` when the pilot releases the button.
    func start() throws {
        try startEngine(autoSilence: nil)
    }

    /// Stop capturing, but let the recognizer flush its FINAL result before
    /// returning so the last word isn't clipped. Waits for `isFinal` (usually
    /// well under a second) or a short timeout, whichever comes first.
    func stopAndCollect() async -> String {
        if torn { return latest }
        // Stop feeding new audio; keep the task alive to emit the final result.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        isListening = false

        let text: String = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            finalContinuation = c
            finalTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.deliverFinal() }
            }
        }
        _ = teardown()
        return text
    }

    private func deliverFinal() {
        finalTimer?.invalidate(); finalTimer = nil
        guard let c = finalContinuation else { return }
        finalContinuation = nil
        c.resume(returning: latest)
    }

    // MARK: - Hands-free (auto silence)

    func listenWithSilence(timeout: TimeInterval) async throws -> String {
        try startEngine(autoSilence: timeout)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            self.continuation = c
            self.armSilence()   // fallback if nothing is ever heard
        }
    }

    /// Hard-cancel from anywhere; resumes any pending `listenWithSilence`.
    func cancel() {
        let text = teardown()
        if let c = continuation { continuation = nil; c.resume(returning: text) }
    }

    // MARK: - Internals

    private func startEngine(autoSilence: TimeInterval?) throws {
        guard let recognizer, recognizer.isAvailable else { throw RecognizerError.recognizerUnavailable }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw RecognizerError.notAuthorized }

        latest = ""
        partialText = ""
        torn = false
        self.autoSilence = autoSilence

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        print("VFR: startEngine — activating audio session")
        do { try AudioSession.activatePlayAndRecord() }
        catch { throw RecognizerError.audioSession(error.localizedDescription) }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        print("VFR: input format \(format.sampleRate)Hz \(format.channelCount)ch")
        input.removeTap(onBus: 0)
        // The tap runs on the real-time audio thread, and the recognition
        // handler on an arbitrary queue. Both closures are explicitly @Sendable
        // (non-isolated) so they never inherit main-actor isolation and never
        // trip the dispatch queue assertion. `append` is thread-safe; the
        // handler hops to the main actor itself.
        nonisolated(unsafe) let capturedRequest = request
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            // Skip empty buffers — the first tap callback often delivers a
            // zero-length buffer, which logs "mDataByteSize (0) should be
            // non-zero" and gives the recognizer nothing anyway.
            guard buffer.frameLength > 0 else { return }
            capturedRequest.append(buffer)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)

        audioEngine.prepare()
        do { try audioEngine.start() }
        catch { throw RecognizerError.audioSession(error.localizedDescription) }
        print("VFR: audio engine started, listening")
        isListening = true

        let handler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
            // Extract Sendable values off the callback thread, then hop to main.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hadError = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.latest = text
                    self.partialText = text
                    if self.autoSilence != nil { self.armSilence() }
                }
                if isFinal { self.deliverFinal() }       // push-to-talk: full result is in
                if hadError {
                    if self.autoSilence != nil { self.finishAuto() }
                    else { self.deliverFinal() }         // don't hang the manual wait
                }
            }
        }
        task = recognizer.recognitionTask(with: request, resultHandler: handler)
    }

    private func armSilence() {
        guard let t = autoSilence else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.latest.isEmpty { self.finishAuto() } else { self.armSilence() }
            }
        }
    }

    private func finishAuto() {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: teardown())
    }

    @discardableResult
    private func teardown() -> String {
        if torn { return latest }
        torn = true
        silenceTimer?.invalidate(); silenceTimer = nil
        finalTimer?.invalidate(); finalTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        if let c = finalContinuation { finalContinuation = nil; c.resume(returning: latest) }
        return latest
    }
}
