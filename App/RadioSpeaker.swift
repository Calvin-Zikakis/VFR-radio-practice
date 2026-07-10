import AVFoundation
import VFRCore

/// Speaks text aloud via the on-device synthesizer. `await speak(_:)` returns
/// only once the utterance has finished, so the hands-free loop can sequence
/// "speak, then listen" without overlap. A watchdog guarantees it always
/// returns even if the synthesizer never reports completion.
///
/// When `radioEffect` is on, the radio/ATC voices (not the instructor) are
/// rendered to audio buffers and pushed through an engine with a bandpass EQ,
/// a radio distortion, and a low static bed so they sound like they came over
/// the air. The clean `AVSpeechSynthesizer.speak` path is the fallback.
@MainActor
final class RadioSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum VoiceRole { case controller, traffic, scene, instructor, notes }

    @Published private(set) var isSpeaking = false

    /// Default voice identifier (from Settings). When nil, the best-quality
    /// installed en-US voice is chosen automatically. Per-role overrides below
    /// fall back to this when nil, so one picker can still voice everything.
    var voiceIdentifier: String?
    /// Per-role voice overrides (nil = use `voiceIdentifier`). The radio voice
    /// covers both the controller and other traffic.
    var radioVoiceIdentifier: String?
    var sceneVoiceIdentifier: String?
    var instructorVoiceIdentifier: String?
    var notesVoiceIdentifier: String?

    /// Instructor speech rate (AVSpeechUtterance scale, ~0.0–1.0; default 0.5).
    var speechRate: Float = 0.5

    /// Controller/radio speech rate, separate — real controllers talk fast.
    var controllerRate: Float = 0.52

    /// Apply the "over the air" radio effect to controller/traffic voices.
    var radioEffect = false

    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// The utterance we're currently speaking. Used to ignore stale delegate
    /// callbacks from an utterance we already interrupted.
    private var currentUtterance: AVSpeechUtterance?

    // Radio-effect audio graph.
    private let fxEngine = AVAudioEngine()
    private let voicePlayer = AVAudioPlayerNode()
    private let noisePlayer = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let distortion = AVAudioUnitDistortion()
    private var fxConfigured = false
    private var graphFormat: AVAudioFormat?
    private var effectContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self

        // Light radio color, tuned by ear: a wide ~200–4800 Hz band (true comm
        // radio is 300–3000, but that much filtering sounds robotic on a
        // synthesized voice) + just a whisper of the radio distortion. Most of
        // the "over the air" feel comes from the static bed, not the filter.
        // Configured once; the graph is wired lazily when we know the format.
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 200
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .lowPass
        eq.bands[1].frequency = 4800
        eq.bands[1].bypass = false
        eq.globalGain = -2   // headroom: resonant filters overshoot near cutoff
        distortion.loadFactoryPreset(.speechRadioTower)
        distortion.wetDryMix = 4    // barely there — 12 sounded ring-modulated
    }

    /// `volume` scales this one utterance (0–1, default full); used for the
    /// instructor/pass-note volume sliders. Radio voices always play full.
    func speak(_ text: String, as role: VoiceRole = .controller, volume: Float = 1.0) async {
        let trimmed = Self.sanitizeForSpeech(text)
        guard !trimmed.isEmpty, volume > 0.001 else { return }

        do { try AudioSession.activatePlayAndRecord() }
        catch { vfrLog("audio session activate failed in speak: \(error)") }

        // If something is already speaking (e.g. the user tapped Replay again),
        // cut it off cleanly instead of queueing a second utterance behind it.
        if isSpeaking { stop() }
        vfrLog("speaking: \(trimmed.prefix(40))…")

        // Radio effect for the over-the-air voices only; the human voices
        // (scene, instructor, notes) stay clean.
        if radioEffect, Self.isRadio(role) {
            let ok = await speakWithEffect(trimmed, role: role)
            if ok { return }
            vfrLog("radio effect failed, falling back to clean voice")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            let utterance = makeUtterance(trimmed, role: role, volume: volume)
            self.currentUtterance = utterance
            isSpeaking = true
            synth.speak(utterance)

            // Safety net: never let a wedged utterance hang the session loop.
            let words = max(1, trimmed.split(separator: " ").count)
            let maxSeconds = Double(words) * 1.0 + 6.0
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishSpeaking()
            }
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        voicePlayer.stop()
        noisePlayer.stop()
        if fxEngine.isRunning { fxEngine.stop() }
        finishEffect()
        finishSpeaking()
    }

    /// The grader very occasionally leaks JSON syntax into a string field
    /// (e.g. `…readback correct.corrections.: [],`). Never read that aloud:
    /// cut at the first JSON-ish character and strip stray quotes.
    static func sanitizeForSpeech(_ text: String) -> String {
        var t = text
        if let i = t.firstIndex(where: { "{}[]".contains($0) }) {
            t = String(t[..<i])
        }
        // Degenerate grader output has been seen appending meta-notes chained
        // with arrows ("…Watsonville.-> ACTUALLY use corrections field below").
        // No legitimate spoken line contains "->": cut there too.
        if let r = t.range(of: "->") {
            t = String(t[..<r.lowerBound])
        }
        // Leaked JSON string-array syntax: a reply ending "…one niner left.','7JA'"
        // (quote-comma-quote is never spoken). Cut at the first such fragment.
        if let r = t.range(of: "','") {
            t = String(t[..<r.lowerBound])
        }
        t = t.replacingOccurrences(of: "\"", with: "")
        // A leaked field name or stray quote right at the cut point
        // ("….corrections.:", "…left.'") — drop trailing punctuation/quotes.
        while let last = t.last, ":.,;-'` ".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeUtterance(_ text: String, role: VoiceRole,
                               volume: Float = 1.0) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        // The radio voices talk faster (their own slider); the human voices
        // (scene, instructor, notes) use the instructor rate.
        utterance.rate = Self.isRadio(role) ? controllerRate : speechRate
        utterance.postUtteranceDelay = 0.1
        // 0.85, not 1.0: enhanced/premium voices at full scale clip on the
        // iPhone loudspeaker (audible crackle on loud syllables).
        utterance.volume = 0.85 * min(max(volume, 0), 1)
        utterance.voice = resolvedVoice(for: role)
        return utterance
    }

    /// The over-the-air voices (controller + other traffic), as opposed to the
    /// human voices spoken clean (scene, instructor, notes).
    static func isRadio(_ role: VoiceRole) -> Bool {
        role == .controller || role == .traffic
    }

    private func finishSpeaking() {
        watchdog?.cancel()
        watchdog = nil
        isSpeaking = false
        currentUtterance = nil
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    // MARK: - Radio effect

    /// Render the utterance to buffers and play them through the effect graph.
    /// Returns false on any failure so the caller can fall back to clean speech.
    private func speakWithEffect(_ text: String, role: VoiceRole) async -> Bool {
        let utterance = makeUtterance(text, role: role)
        let native = await renderBuffers(for: utterance)
        guard let first = native.first,
              let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: first.format.sampleRate,
                                            channels: first.format.channelCount,
                                            interleaved: false) else { return false }

        let voice = native.compactMap { convert($0, to: canonical) }
        guard !voice.isEmpty else { return false }

        configureGraph(format: canonical)
        do { try fxEngine.start() } catch { vfrLog("fxEngine start failed: \(error)"); return false }

        isSpeaking = true
        startNoise(format: canonical)

        let totalFrames = voice.reduce(0) { $0 + Int($1.frameLength) }
        let seconds = Double(totalFrames) / canonical.sampleRate

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.effectContinuation = cont
            for (i, buffer) in voice.enumerated() {
                let isLast = i == voice.count - 1
                voicePlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard isLast else { return }
                    Task { @MainActor in self?.finishEffect() }
                }
            }
            voicePlayer.play()

            // Watchdog: never hang if a completion handler is dropped.
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((seconds + 3.0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finishEffect()
            }
        }

        noisePlayer.stop()
        isSpeaking = false
        return true
    }

    private func finishEffect() {
        watchdog?.cancel()
        watchdog = nil
        let cont = effectContinuation
        effectContinuation = nil
        cont?.resume()
    }

    /// Collect the synthesizer's PCM buffers for one utterance (the terminal
    /// empty buffer signals completion).
    private func renderBuffers(for utterance: AVSpeechUtterance) async -> [AVAudioPCMBuffer] {
        await withCheckedContinuation { (cont: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            let collector = BufferCollector()
            synth.write(utterance) { audioBuffer in
                guard let pcm = audioBuffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    collector.finish(cont)          // done
                } else {
                    collector.append(pcm)
                }
            }
        }
    }

    /// Convert an Int16/other PCM buffer to the canonical Float32 format (same
    /// sample rate, so no resampling — just a format change).
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else { return nil }
        // The converter's input block runs synchronously on this thread, so the
        // buffer is safe to hand back; mark the capture to satisfy Sendable.
        nonisolated(unsafe) let source = buffer
        var supplied = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }
        return status == .haveData ? out : nil
    }

    private func configureGraph(format: AVAudioFormat) {
        if fxConfigured, graphFormat == format { return }
        if fxConfigured {
            [voicePlayer, noisePlayer, eq, distortion].forEach { fxEngine.detach($0) }
        }
        [voicePlayer, noisePlayer, eq, distortion].forEach { fxEngine.attach($0) }
        // Same headroom as the clean path: filters + distortion add gain, and
        // summed peaks over full scale hard-clip (crackle at loud syllables).
        voicePlayer.volume = 0.8
        let mixer = fxEngine.mainMixerNode
        fxEngine.connect(voicePlayer, to: eq, format: format)
        fxEngine.connect(eq, to: distortion, format: format)
        fxEngine.connect(distortion, to: mixer, format: format)
        fxEngine.connect(noisePlayer, to: mixer, format: format)
        fxConfigured = true
        graphFormat = format
        fxEngine.prepare()
    }

    private func startNoise(format: AVAudioFormat) {
        guard let noise = makeNoiseBuffer(format: format, seconds: 1.0) else { return }
        noisePlayer.volume = 0.018  // faint static bed
        noisePlayer.scheduleBuffer(noise, at: nil, options: [.loops], completionHandler: nil)
        noisePlayer.play()
    }

    private func makeNoiseBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) { data[c][i] = Float.random(in: -1...1) }
        }
        return buffer
    }

    // MARK: - Voice selection

    private func resolvedVoice(for role: VoiceRole) -> AVSpeechSynthesisVoice? {
        let override: String?
        switch role {
        case .controller, .traffic: override = radioVoiceIdentifier
        case .scene: override = sceneVoiceIdentifier
        case .instructor: override = instructorVoiceIdentifier
        case .notes: override = notesVoiceIdentifier
        }
        if let id = override ?? voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return Self.bestQualityEnglishVoice()
    }

    /// Pick the most natural installed English voice: premium > enhanced >
    /// default, preferring en-US, then anything the compact default.
    static func bestQualityEnglishVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        let ranked = english.sorted { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            // Tie-break: prefer en-US.
            return lhs.language == "en-US" && rhs.language != "en-US"
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Installed English voices for the Settings picker, best quality first.
    static func selectableEnglishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        finishIfCurrent(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        finishIfCurrent(utterance)
    }

    /// Only complete the pending `speak` if the callback belongs to the utterance
    /// we're actually speaking now — a late callback from an interrupted one must
    /// not cut off the utterance that replaced it. `ObjectIdentifier` is Sendable,
    /// so we compare identity across the actor hop without capturing the utterance.
    nonisolated private func finishIfCurrent(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.currentUtterance,
                  ObjectIdentifier(current) == id else { return }
            self.finishSpeaking()
        }
    }
}

/// Thread-safe collector for `AVSpeechSynthesizer.write` buffers. The write
/// callback may fire on a background queue; this serializes appends and resumes
/// the continuation exactly once when the terminal empty buffer arrives.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var done = false

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); buffers.append(buffer); lock.unlock()
    }

    func finish(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: buffers)
    }
}
