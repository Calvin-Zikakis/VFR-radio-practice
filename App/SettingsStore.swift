import Foundation
import VFRCore

/// App appearance override: follow the system, or force light/dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How the pilot talks to the app.
enum InteractionMode: String, CaseIterable {
    case handsFree      // continuous listen + silence detection (driving)
    case pushToTalk     // hold-to-talk button (phone in hand)

    var displayName: String {
        switch self {
        case .handsFree: return "Hands-free"
        case .pushToTalk: return "Push-to-talk"
        }
    }
}

/// User-configurable settings. API key lives in the Keychain; everything else
/// in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: "anthropic_api_key") }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: "model") }
    }
    @Published var gradingMode: GradingMode {
        didSet { defaults.set(gradingMode.rawValue, forKey: "gradingMode") }
    }
    /// Shuffle drill order each session so you don't drill the same sequence.
    @Published var randomizeDrills: Bool {
        didSet { defaults.set(randomizeDrills, forKey: "randomizeDrills") }
    }
    @Published var interactionMode: InteractionMode {
        didSet { defaults.set(interactionMode.rawValue, forKey: "interactionMode") }
    }
    /// Hands-free only: seconds of silence before we decide you're done talking.
    @Published var endOfSpeechPause: Double {
        didSet { defaults.set(endOfSpeechPause, forKey: "endOfSpeechPause") }
    }
    /// Chosen TTS voice identifier; nil = best available automatically.
    @Published var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
    /// Speech rate for the synthesized voices (AVSpeechUtterance scale).
    @Published var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: "speechRate") }
    }
    /// Run the radio/ATC voices through a bandpass + static "over the air" effect.
    @Published var radioEffect: Bool {
        didSet { defaults.set(radioEffect, forKey: "radioEffect") }
    }
    /// How demanding the controller and grading are.
    @Published var difficulty: Difficulty {
        didSet { defaults.set(difficulty.rawValue, forKey: "difficulty") }
    }
    /// Controller/radio speech rate, separate from the instructor's — real
    /// controllers talk fast.
    @Published var controllerSpeechRate: Double {
        didSet { defaults.set(controllerSpeechRate, forKey: "controllerSpeechRate") }
    }
    /// Vary incidental drill details (ATIS letter, distances, squawk codes)
    /// each session so answers can't be memorized.
    @Published var varyDetails: Bool {
        didSet { defaults.set(varyDetails, forKey: "varyDetails") }
    }
    /// Simulate a busy frequency: background calls from other aircraft, and
    /// occasionally your transmission gets stepped on.
    @Published var busyFrequency: Bool {
        didSet { defaults.set(busyFrequency, forKey: "busyFrequency") }
    }
    /// After a missed call, the instructor reads the model call so you can
    /// shadow it.
    @Published var echoModelCall: Bool {
        didSet { defaults.set(echoModelCall, forKey: "echoModelCall") }
    }
    /// Light / dark / follow-the-system appearance.
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Speak coaching aloud even when the call passed. Off by default — notes
    /// on a pass are usually minor polish and slow the session down; they stay
    /// visible in the transcript and debrief either way.
    @Published var speakPassNotes: Bool {
        didSet { defaults.set(speakPassNotes, forKey: "speakPassNotes") }
    }
    /// Speak instructor prompts/notes aloud in push-to-talk mode too. Off by
    /// default — in PTT you're usually reading the screen; hands-free always
    /// speaks them regardless.
    @Published var speakInstructorInPTT: Bool {
        didSet { defaults.set(speakInstructorInPTT, forKey: "speakInstructorInPTT") }
    }
    /// The airplanes available to practice in. Seeded with the built-in fleet;
    /// the user can add/edit/remove custom planes.
    @Published var aircraftFleet: [Aircraft] {
        didSet { saveFleet() }
    }
    /// Which plane to fly. Empty = use all planes (a random one per session);
    /// otherwise the callsign of the single plane to fly every session.
    @Published var selectedAircraftCallsign: String {
        didSet { defaults.set(selectedAircraftCallsign, forKey: "selectedAircraftCallsign") }
    }

    static let models = ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-8"]

    private let defaults = UserDefaults.standard

    init() {
        self.apiKey = Keychain.get("anthropic_api_key") ?? ""
        // Sonnet by default: best grading quality; sessions cost ~10–15¢.
        // Switch to Haiku for lower latency/cost while driving.
        self.model = defaults.string(forKey: "model") ?? "claude-sonnet-5"
        self.gradingMode = GradingMode(rawValue: defaults.string(forKey: "gradingMode") ?? "") ?? .live
        self.randomizeDrills = defaults.bool(forKey: "randomizeDrills")   // default false
        self.interactionMode = InteractionMode(rawValue: defaults.string(forKey: "interactionMode") ?? "") ?? .handsFree
        let savedPause = defaults.double(forKey: "endOfSpeechPause")
        self.endOfSpeechPause = savedPause > 0 ? savedPause : 2.0
        self.voiceIdentifier = defaults.string(forKey: "voiceIdentifier")
        let savedRate = defaults.double(forKey: "speechRate")
        self.speechRate = savedRate > 0 ? savedRate : 0.5   // AVSpeechUtterance default
        self.radioEffect = defaults.bool(forKey: "radioEffect")   // default false
        self.difficulty = Difficulty(rawValue: defaults.string(forKey: "difficulty") ?? "") ?? .checkride
        let savedControllerRate = defaults.double(forKey: "controllerSpeechRate")
        self.controllerSpeechRate = savedControllerRate > 0 ? savedControllerRate : 0.52
        self.varyDetails = defaults.object(forKey: "varyDetails") as? Bool ?? true   // default on
        self.busyFrequency = defaults.bool(forKey: "busyFrequency")                  // default off
        self.echoModelCall = defaults.bool(forKey: "echoModelCall")                  // default off
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        self.speakPassNotes = defaults.bool(forKey: "speakPassNotes")   // default off (quiet passes)
        self.speakInstructorInPTT = defaults.bool(forKey: "speakInstructorInPTT")   // default off (read the screen)
        if let data = defaults.data(forKey: "aircraftFleet"),
           let fleet = try? JSONDecoder().decode([Aircraft].self, from: data),
           !fleet.isEmpty {
            self.aircraftFleet = fleet
        } else {
            self.aircraftFleet = DrillLibrary.fleet   // seed with the built-ins
        }
        self.selectedAircraftCallsign = defaults.string(forKey: "selectedAircraftCallsign") ?? ""
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Aircraft fleet editing

    private func saveFleet() {
        if let data = try? JSONEncoder().encode(aircraftFleet) {
            defaults.set(data, forKey: "aircraftFleet")
        }
    }

    /// Add a new plane, or replace an existing one with the same callsign.
    func upsertAircraft(_ a: Aircraft, replacing originalCallsign: String? = nil) {
        if let original = originalCallsign,
           let i = aircraftFleet.firstIndex(where: { $0.callsign == original }) {
            aircraftFleet[i] = a
            if selectedAircraftCallsign == original { selectedAircraftCallsign = a.callsign }
        } else if let i = aircraftFleet.firstIndex(where: { $0.callsign == a.callsign }) {
            aircraftFleet[i] = a
        } else {
            aircraftFleet.append(a)
        }
    }

    func removeAircraft(callsign: String) {
        aircraftFleet.removeAll { $0.callsign == callsign }
        if aircraftFleet.isEmpty { aircraftFleet = DrillLibrary.fleet }   // never empty
        if selectedAircraftCallsign == callsign { selectedAircraftCallsign = "" }
    }

    func resetFleetToDefaults() {
        aircraftFleet = DrillLibrary.fleet
        selectedAircraftCallsign = ""
    }
}

/// Minimal Keychain wrapper for a single string secret.
enum Keychain {
    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
