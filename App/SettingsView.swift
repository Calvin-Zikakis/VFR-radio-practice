import SwiftUI
import AVFoundation
import VFRCore

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var previewSpeaker = RadioSpeaker()
    @State private var editingAircraft: AircraftDraft?
    @ObservedObject private var stats = StatsStore.shared
    /// Loaded once on appear — the enumeration is slow, and iOS caches the
    /// installed-voice list until app relaunch anyway.
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Anthropic API Key") {
                    SecureField("sk-ant-…", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Stored on-device in the Keychain. Get a key at console.anthropic.com.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Model") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(SettingsStore.models, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Haiku is cheapest and fastest. Sonnet/Opus grade more strictly.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Grading") {
                    Picker("Feedback", selection: $settings.gradingMode) {
                        ForEach(GradingMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Difficulty", selection: $settings.difficulty) {
                        ForEach(Difficulty.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text("Student: patient controller, lenient grading. Checkride: FAA/AIM standard. Rapid-fire: busy, terse controller who talks fast and grades strictly.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Realism") {
                    Toggle(isOn: $settings.varyDetails) {
                        Label("Vary drill details", systemImage: "dice")
                    }
                    Text("Randomizes ATIS letters, distances, and squawk codes each session.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(isOn: $settings.busyFrequency) {
                        Label("Busy frequency", systemImage: "person.wave.2")
                    }
                    Text("Other aircraft on frequency — and sometimes your call gets stepped on.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(isOn: $settings.echoModelCall) {
                        Label("Read model call after a miss", systemImage: "waveform.and.mic")
                    }
                    Text("Shadow practice: when a call needs another try, the instructor reads the ideal version first.")
                        .font(.caption).foregroundStyle(.secondary)
                    SmoothSliderRow(title: "Scene voice",
                                    titleIcon: "text.bubble",
                                    range: 0...1, step: 0.05,
                                    format: Self.percentLabel,
                                    value: $settings.sceneVolume)
                    Text("The instructor setting up each drill — what to do next. Keep this up so you always hear the scene.")
                        .font(.caption).foregroundStyle(.secondary)
                    SmoothSliderRow(title: "Instructor voice",
                                    titleIcon: "speaker.wave.2.bubble.left",
                                    range: 0...1, step: 0.05,
                                    format: Self.percentLabel,
                                    value: $settings.instructorVolume)
                    Text("What the instructor says AFTER your call — coaching and the 'read it back' prompt. Zero lets you answer the controller yourself with this help on screen only.")
                        .font(.caption).foregroundStyle(.secondary)
                    SmoothSliderRow(title: "Notes on passed calls",
                                    titleIcon: "bubble.left.and.text.bubble.right",
                                    range: 0...1, step: 0.05,
                                    format: Self.percentLabel,
                                    value: $settings.passNotesVolume)
                    Text("Polish notes when a call passes — in every mode. Zero keeps passes snappy; the notes still appear on screen and in the debrief.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                progressSection

                aircraftSection

                Section("Voice") {
                    Picker("Voice", selection: $settings.voiceIdentifier) {
                        Text("Automatic (best installed)").tag(String?.none)
                        // Cached: enumerating system voices is expensive, and
                        // doing it in `body` ran it on every form re-render.
                        ForEach(voices, id: \.identifier) { v in
                            Text(voiceLabel(v)).tag(Optional(v.identifier))
                        }
                    }
                    // Identical ranges so Slow/Normal/Fast sit at the same
                    // physical spot on both tracks.
                    SmoothSliderRow(title: "Speech speed",
                                    range: 0.3...0.75, speedScale: true,
                                    format: Self.speedLabel,
                                    value: $settings.speechRate)
                    SmoothSliderRow(title: "Controller speed",
                                    range: 0.3...0.75, speedScale: true,
                                    format: Self.speedLabel,
                                    value: $settings.controllerSpeechRate)
                    Text("Controllers talk faster than instructors — train your ear separately.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(isOn: $settings.radioEffect) {
                        Label("Radio effect (static + bandpass)", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        previewVoice()
                    } label: {
                        Label("Preview voice", systemImage: "play.circle")
                    }
                    Text("Apple doesn't allow apps to use the Siri voices, so they won't appear here. For the most natural voice, download a **Premium** (best) or **Enhanced** English voice in iOS Settings → Accessibility → Spoken Content → Voices → English — “Zoe” has a Premium tier. Then fully quit and reopen this app and pick it here (iOS caches the voice list until relaunch).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Input") {
                    Picker("Mode", selection: $settings.interactionMode) {
                        ForEach(InteractionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    SmoothSliderRow(title: "End-of-speech pause",
                                    range: 1.0...3.5, step: 0.1,
                                    format: { String(format: "%.1fs", $0) },
                                    value: $settings.endOfSpeechPause)
                    Text("Hands-free only: how long you can pause before we decide you're done talking.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear { voices = RadioSpeaker.selectableEnglishVoices() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingAircraft) { draft in
                AircraftEditorView(draft: draft) { plane, original in
                    settings.upsertAircraft(plane, replacing: original)
                }
            }
        }
    }

    // MARK: - Aircraft

    private var aircraftSection: some View {
        Section("Aircraft") {
            Picker("Fly", selection: $settings.selectedAircraftCallsign) {
                Text("All (varied each session)").tag("")
                ForEach(settings.aircraftFleet) { a in
                    Text("\(a.type) · \(a.callsign)").tag(a.callsign)
                }
            }

            ForEach(settings.aircraftFleet) { a in
                Button {
                    editingAircraft = AircraftDraft(originalCallsign: a.callsign,
                                                    type: a.type,
                                                    callsign: a.callsign,
                                                    phonetic: a.phoneticCallsign)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a.type)  ·  \(a.callsign)").foregroundStyle(.primary)
                        Text("“\(a.phoneticCallsign)”").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { settings.aircraftFleet[$0].callsign }
                    .forEach { settings.removeAircraft(callsign: $0) }
            }

            Button {
                editingAircraft = AircraftDraft()
            } label: {
                Label("Add aircraft", systemImage: "plus.circle")
            }
            Button(role: .destructive) {
                settings.resetFleetToDefaults()
            } label: {
                Label("Reset to default aircraft", systemImage: "arrow.counterclockwise")
            }
            Text("Pick **All** to rotate through every plane, or select one to fly it every session. The spoken callsign is how ATC “hears” you — it's what grading uses. Tap a plane to edit it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch v.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Default"
        }
        return "\(v.name) — \(quality)"
    }

    static func speedLabel(_ rate: Double) -> String {
        switch rate {
        case ..<0.42: return "Slow"
        case ..<0.56: return "Normal"
        default: return "Fast"
        }
    }

    static func percentLabel(_ v: Double) -> String {
        v < 0.01 ? "Off" : "\(Int((v * 100).rounded()))%"
    }

    // MARK: - Progress (per-call-type stats)

    @ViewBuilder
    private var progressSection: some View {
        let attempted = CallType.allCases.compactMap { type -> (CallType, StatsStore.Tally)? in
            guard let t = stats.tally(for: type), t.attempts > 0 else { return nil }
            return (type, t)
        }
        Section("Progress") {
            if attempted.isEmpty {
                Text("Fly some sessions and your pass rates per call type will show up here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(attempted, id: \.0) { type, tally in
                    HStack {
                        Text(type.displayName)
                        Spacer()
                        Text("\(tally.passed)/\(tally.attempts)")
                            .foregroundStyle(.secondary)
                        Text(passRateText(tally))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tally.failRate > 0.4 ? .red : (tally.failRate > 0.15 ? .orange : .green))
                    }
                }
                Button(role: .destructive) {
                    stats.reset()
                } label: {
                    Label("Reset stats", systemImage: "trash")
                }
            }
        }
    }

    private func passRateText(_ t: StatsStore.Tally) -> String {
        "\(Int(((1 - t.failRate) * 100).rounded()))%"
    }

    private func previewVoice() {
        previewSpeaker.voiceIdentifier = settings.voiceIdentifier
        previewSpeaker.speechRate = Float(settings.speechRate)
        previewSpeaker.controllerRate = Float(settings.controllerSpeechRate)
        previewSpeaker.radioEffect = settings.radioEffect
        Task {
            await previewSpeaker.speak(
                "Watsonville traffic, RV seven three seven juliet alpha, left downwind runway two zero, Watsonville.",
                as: .controller)
        }
    }
}

/// A being-edited aircraft. `originalCallsign` is nil for a brand-new plane.
struct AircraftDraft: Identifiable {
    let id = UUID()
    var originalCallsign: String?
    var type: String = ""
    var callsign: String = ""
    var phonetic: String = ""
}

/// Add / edit a single custom aircraft.
private struct AircraftEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: AircraftDraft
    let onSave: (Aircraft, String?) -> Void

    @State private var type: String
    @State private var callsign: String
    @State private var phonetic: String

    init(draft: AircraftDraft, onSave: @escaping (Aircraft, String?) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _type = State(initialValue: draft.type)
        _callsign = State(initialValue: draft.callsign)
        _phonetic = State(initialValue: draft.phonetic)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Aircraft") {
                    TextField("Make & model (e.g. Van's RV-12)", text: $type)
                    TextField("Tail number (e.g. N737JA)", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Spoken callsign") {
                    TextField("e.g. RV seven three seven juliet alpha",
                              text: $phonetic, axis: .vertical)
                    Button {
                        phonetic = Self.suggestPhonetic(from: callsign)
                    } label: {
                        Label("Suggest from tail number", systemImage: "wand.and.stars")
                    }
                    .disabled(callsign.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("How you say the callsign on the radio — this is what ATC “hears”, so grading uses it. Edit the prefix to match how you call (e.g. “RV”, “Skyhawk”, “Cirrus”, or “November”).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(draft.originalCallsign == nil ? "Add Aircraft" : "Edit Aircraft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let plane = Aircraft(
                            callsign: callsign.trimmingCharacters(in: .whitespaces).uppercased(),
                            phoneticCallsign: phonetic.trimmingCharacters(in: .whitespacesAndNewlines),
                            type: type.trimmingCharacters(in: .whitespaces))
                        onSave(plane, draft.originalCallsign)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        [type, callsign, phonetic].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Spell a tail number into spoken words as a starting point ("N737JA" →
    /// "November seven three seven juliet alpha"). The pilot edits the prefix.
    static func suggestPhonetic(from callsign: String) -> String {
        let digits: [Character: String] = [
            "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
            "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "niner"]
        let nato: [Character: String] = [
            "A": "alpha", "B": "bravo", "C": "charlie", "D": "delta", "E": "echo",
            "F": "foxtrot", "G": "golf", "H": "hotel", "I": "india", "J": "juliet",
            "K": "kilo", "L": "lima", "M": "mike", "N": "november", "O": "oscar",
            "P": "papa", "Q": "quebec", "R": "romeo", "S": "sierra", "T": "tango",
            "U": "uniform", "V": "victor", "W": "whiskey", "X": "x-ray",
            "Y": "yankee", "Z": "zulu"]
        var words: [String] = []
        for (i, ch) in callsign.uppercased().trimmingCharacters(in: .whitespaces).enumerated() {
            if i == 0 && ch == "N" { words.append("November"); continue }
            if let d = digits[ch] { words.append(d) }
            else if let l = nato[ch] { words.append(l) }
        }
        return words.joined(separator: " ")
    }
}

/// Slider row that tracks the drag against local state and writes the bound
/// setting only when the finger lifts. Binding straight to the settings store
/// re-rendered the entire Settings form on every tick of the drag (including
/// the expensive system-voice enumeration), which made every slider stutter.
struct SmoothSliderRow: View {
    let title: String
    var titleIcon: String? = nil
    let range: ClosedRange<Double>
    var step: Double? = nil
    /// Show the tortoise/hare speed icons around the track.
    var speedScale = false
    let format: (Double) -> String
    @Binding var value: Double

    @State private var local = 0.0
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if let titleIcon {
                    Label(title, systemImage: titleIcon)
                } else {
                    Text(title)
                }
                Spacer()
                Text(format(dragging ? local : value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                if speedScale { Image(systemName: "tortoise") }
                if let step {
                    Slider(value: $local, in: range, step: step, onEditingChanged: editingChanged)
                } else {
                    Slider(value: $local, in: range, onEditingChanged: editingChanged)
                }
                if speedScale { Image(systemName: "hare") }
            }
        }
        .onAppear { local = value }
        // External change (reset, another screen) while not dragging.
        .onChange(of: value) { _, new in if !dragging { local = new } }
    }

    private func editingChanged(_ began: Bool) {
        if began {
            local = value
            dragging = true
        } else {
            dragging = false
            value = local
        }
    }
}
