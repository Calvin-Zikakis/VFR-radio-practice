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

    /// Session-specific phrases (callsign, airport names) the controller sets
    /// so the recognizer biases toward them instead of guessing homophones.
    var contextualPhrases: [String] = []

    /// Radio vocabulary the on-device recognizer reliably mangles without a
    /// bias list: "VFR" → "BFR", "niner" → "diner", "juliet" → "Julia",
    /// "holding short" → "Holden short".
    private static let aviationVocabulary: [String] = [
        "VFR", "IFR", "CTAF", "ATIS", "UNICOM",
        "niner", "juliet", "alpha", "bravo", "charlie", "delta", "echo",
        "foxtrot", "golf", "hotel", "india", "kilo", "lima", "mike",
        "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango",
        "uniform", "victor", "whiskey", "x-ray", "yankee", "zulu",
        "holding short", "line up and wait", "cleared for takeoff",
        "cleared to land", "left downwind", "right downwind", "left base",
        "right base", "final", "crosswind", "upwind", "go around",
        "touch and go", "full stop", "the option", "traffic in sight",
        "negative contact", "looking for traffic", "squawk", "ident",
        "radar contact", "flight following", "frequency change approved",
        "altimeter", "wilco", "unable", "say again", "roger",
        "taxiing", "back-taxi", "midfield", "straight-in", "overhead",
        "departing", "inbound", "outbound", "maintain", "climbing", "descending",
        "minimum fuel", "mayday", "pan-pan", "resume own navigation"
    ]

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
    /// True while hands-free finalization is flushing the recognizer's tail.
    private var flushing = false
    private let voice = VoiceActivity()

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
    /// returning so the last words aren't clipped. Waits for `isFinal` or a
    /// timeout, whichever comes first. The timeout must be generous: on a
    /// full-length radio call the final result can trail the release by well
    /// over a second, and returning early hands back a stale partial with the
    /// tail of the call missing.
    func stopAndCollect() async -> String {
        if torn { return latest }
        // Stop feeding new audio; keep the task alive to emit the final result.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        isListening = false

        let text: String = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            finalContinuation = c
            finalTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.deliverFinal() }
            }
        }
        _ = teardown()
        print("VFR: PTT heard: \(text.isEmpty ? "<nothing>" : text)")
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
        flushing = false
        self.autoSilence = autoSilence
        voice.reset()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = Self.aviationVocabulary + contextualPhrases
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
        let activity = voice
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            // Skip empty buffers — the first tap callback often delivers a
            // zero-length buffer, which logs "mDataByteSize (0) should be
            // non-zero" and gives the recognizer nothing anyway.
            guard buffer.frameLength > 0 else { return }
            capturedRequest.append(buffer)
            // Track voice energy directly from the mic. The silence-detection
            // timer trusts this over transcription updates: the recognizer
            // often stalls its partials for seconds mid-utterance, and
            // finalizing during such a stall truncates the call.
            if let data = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
                activity.update(rms: (sum / Float((n + 3) / 4)).squareRoot())
            }
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
                    if self.autoSilence != nil, !self.flushing { self.armSilence() }
                }
                if isFinal {
                    self.deliverFinal()                  // push-to-talk: full result is in
                    self.deliverAuto()                   // hands-free flush: tail is in
                }
                if hadError {
                    if self.autoSilence != nil { self.deliverAuto() }
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
                guard let self, !self.flushing else { return }
                guard !self.latest.isEmpty else { self.armSilence(); return }
                // The mic is the authority on whether the pilot went quiet —
                // partials stall mid-call, and finalizing on a stall clips it.
                if self.voice.secondsSinceVoice < t {
                    self.armSilence()
                } else {
                    self.finishAuto()
                }
            }
        }
    }

    /// Hands-free finalization: stop feeding audio and give the recognizer a
    /// moment to emit its FINAL result — it frequently contains trailing words
    /// no partial ever showed. `deliverAuto` resumes the listen either on that
    /// final or on the timeout.
    private func finishAuto() {
        guard continuation != nil, !flushing else { return }
        flushing = true
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        isListening = false
        finalTimer?.invalidate()
        finalTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.deliverAuto() }
        }
    }

    private func deliverAuto() {
        guard let c = continuation else { return }
        continuation = nil
        flushing = false
        c.resume(returning: teardown())
    }

    @discardableResult
    private func teardown() -> String {
        if torn { return latest }
        torn = true
        flushing = false
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

/// Cheap voice-activity detector fed from the mic tap (real-time audio
/// thread), read from the main actor's silence timer. Tracks a slow-moving
/// noise floor so steady cabin/road noise doesn't read as speech, while
/// speech — which spikes well above the floor — refreshes `secondsSinceVoice`.
private final class VoiceActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var floor: Float = 0.005
    private var lastVoice: TimeInterval = ProcessInfo.processInfo.systemUptime

    func reset() {
        lock.lock()
        floor = 0.005
        lastVoice = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func update(rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        // Floor falls quickly, rises slowly: transient speech barely lifts it,
        // but sustained noise (a car at speed) is absorbed within seconds so
        // silence detection still works over it.
        floor = rms < floor ? 0.9 * floor + 0.1 * rms
                            : 0.995 * floor + 0.005 * rms
        if rms > max(0.008, floor * 2.5) {
            lastVoice = ProcessInfo.processInfo.systemUptime
        }
    }

    var secondsSinceVoice: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastVoice
    }
}
