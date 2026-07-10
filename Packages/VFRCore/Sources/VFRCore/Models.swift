import Foundation

/// The three VFR communication environments this app trains.
public enum ScenarioType: String, Codable, CaseIterable, Sendable {
    case untowered        // CTAF self-announce, no ATC
    case towered          // Ground / Tower / (Clearance)
    case flightFollowing  // Approach / Center radar advisories

    public var displayName: String {
        switch self {
        case .untowered: return "Untowered (CTAF)"
        case .towered: return "Towered (ATC)"
        case .flightFollowing: return "Flight Following"
        }
    }
}

/// A kind of radio call, used to build a focused "mix" session from specific
/// call types across the drill library.
public enum CallType: String, Codable, Sendable, CaseIterable, Identifiable {
    case taxi            // ground / taxi calls
    case departure       // takeoff / departure calls
    case arrival         // inbound to land
    case pattern         // downwind, base, final, pattern reports, touch-and-go
    case readback        // read back a clearance
    case flightFollowing // request / terminate / altitude change with Approach
    case advisory        // respond to a traffic advisory
    case bravo           // Class B/C airspace: clearances, denials, entry
    case afterLanding    // clear of the runway / taxi to parking
    case emergency       // emergencies & abnormals: mayday, lost, radio failure

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .taxi: return "Ground / Taxi"
        case .departure: return "Departure"
        case .arrival: return "Arrival"
        case .pattern: return "Pattern work"
        case .readback: return "Readbacks"
        case .flightFollowing: return "Flight following"
        case .advisory: return "Traffic advisory"
        case .bravo: return "Airspace (B/C/D)"
        case .afterLanding: return "After landing"
        case .emergency: return "Emergencies"
        }
    }
}

/// How demanding the simulated controller and the grading are.
public enum Difficulty: String, Codable, CaseIterable, Sendable, Identifiable {
    case student    // patient controller, lenient grading
    case checkride  // FAA/AIM standard (the default)
    case rapidFire  // busy, terse controller; strict grading

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .student: return "Student"
        case .checkride: return "Checkride"
        case .rapidFire: return "Rapid-fire"
        }
    }
}

/// When to surface phraseology feedback to the pilot.
public enum GradingMode: String, Codable, CaseIterable, Sendable {
    case live      // spoken coaching after every transmission
    case debrief   // stay silent, collect notes, review at the end

    public var displayName: String {
        switch self {
        case .live: return "Live coaching"
        case .debrief: return "Debrief at end"
        }
    }
}

/// Fixed facts a drill needs. Kept small and deterministic so the Claude
/// system prompt is stable and cacheable across a session.
public struct Aircraft: Codable, Sendable, Equatable, Identifiable {
    public var callsign: String        // e.g. "N172SP"
    public var phoneticCallsign: String // e.g. "Skyhawk one seven two sierra papa"
    public var type: String            // e.g. "Cessna 172"

    /// Tail number is the natural identity; the app keeps callsigns unique.
    public var id: String { callsign }

    public init(callsign: String, phoneticCallsign: String, type: String) {
        self.callsign = callsign
        self.phoneticCallsign = phoneticCallsign
        self.type = type
    }
}

public struct Airport: Codable, Sendable, Equatable, Identifiable {
    public var icao: String            // e.g. "KPAO"
    public var name: String            // e.g. "Palo Alto"
    public var ctafOrTower: String     // frequency spoken form, e.g. "one one eight point six"
    public var elevationFt: Int
    public var runwaysInUse: [String]  // e.g. ["31"]
    public var isTowered: Bool         // true = Ground/Tower; false = CTAF self-announce

    public var id: String { icao }

    public init(icao: String, name: String, ctafOrTower: String, elevationFt: Int,
                runwaysInUse: [String], isTowered: Bool = false) {
        self.icao = icao
        self.name = name
        self.ctafOrTower = ctafOrTower
        self.elevationFt = elevationFt
        self.runwaysInUse = runwaysInUse
        self.isTowered = isTowered
    }
}

/// One bite-sized radio exchange the pilot practices.
public struct Drill: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var scenario: ScenarioType
    public var title: String
    /// Spoken to the pilot to set the scene, e.g.
    /// "You're holding short of runway three one, ready for departure. Make your call."
    public var setup: String
    /// Extra situational facts handed to the ATC brain (not spoken to the pilot).
    public var situation: String
    public var aircraft: Aircraft
    public var airport: Airport
    /// Explicit call-type tag. When nil, `DrillLibrary.callType(for:)` derives
    /// one from the drill id (legacy drills).
    public var callType: CallType?
    /// When true, passing this drill injects a synthesized follow-up drill
    /// that grades the pilot's readback of the exact instruction issued at
    /// the end of the exchange (taxi clearances etc.). The app owns that
    /// sequencing, so the readback can never be skipped by a grader whim.
    /// Optional so older session snapshots keep decoding.
    public var followUpReadback: Bool?
    /// Authored templates for the instruction a chained drill ends with — the
    /// exact clearance the controller issues once the pilot's request is
    /// complete (2–3 per drill, each including the callsign address). The app,
    /// not the grader, owns this content: the session speaks the chosen one
    /// verbatim and the injected readback drill grades against the same
    /// string, so they can never diverge.
    public var instructionVariants: [String]?
    /// The variant chosen for this session, randomized in the same pass as
    /// setup/situation. Codable so a resumed snapshot keeps its clearance.
    public var instruction: String?
    /// True on a synthesized readback follow-up drill (built by
    /// `PracticeSession.readbackFollowUp`). Its clearance was already spoken by
    /// the controller in the previous step, so its "read it back" briefing is
    /// post-reply instructor talk — the app can keep it on-screen only.
    public var injectedReadback: Bool?
    /// Authored templates for a follow-on AMENDMENT the controller issues after
    /// the pilot reads back the initial clearance (a runway change, a revoked
    /// crossing). Lets a drill start from the pilot's request yet still train
    /// the mid-taxi amendment: request → initial clearance → readback →
    /// amendment → readback. Propagated onto the first readback drill so it can
    /// chain the second.
    public var amendmentVariants: [String]?
    /// The chosen amendment for this session (resolved + varied like
    /// `instruction`); nil when the drill has no amendment.
    public var amendment: String?

    public init(id: String, scenario: ScenarioType, title: String, setup: String,
                situation: String, aircraft: Aircraft, airport: Airport,
                callType: CallType? = nil, followUpReadback: Bool? = nil,
                instructionVariants: [String]? = nil, instruction: String? = nil,
                injectedReadback: Bool? = nil,
                amendmentVariants: [String]? = nil, amendment: String? = nil) {
        self.id = id
        self.scenario = scenario
        self.title = title
        self.setup = setup
        self.situation = situation
        self.aircraft = aircraft
        self.airport = airport
        self.callType = callType
        self.followUpReadback = followUpReadback
        self.instructionVariants = instructionVariants
        self.instruction = instruction
        self.injectedReadback = injectedReadback
        self.amendmentVariants = amendmentVariants
        self.amendment = amendment
    }
}

/// The ATC brain's structured verdict on one pilot transmission.
public struct Verdict: Codable, Sendable, Equatable {
    /// What the brain believes the pilot actually said, after correcting for
    /// speech-to-text mangling of callsigns and numbers.
    public var heard: String
    /// Who replies over the radio, spoken form: "Tower", "Ground", "Approach",
    /// "Traffic", "CTAF", or "none".
    public var speaker: String
    /// What the radio says back, ready to speak aloud. Empty when no reply is due.
    public var radioReplyText: String
    /// Was the pilot's phraseology correct and complete for this situation?
    public var correct: Bool
    /// Specific issues, each a short phrase, e.g. "Missing your altitude".
    public var corrections: [String]
    /// A model example of the ideal call for this situation.
    public var expectedExample: String
    /// True once the pilot has satisfied this drill step.
    public var phaseAdvance: Bool
    /// One short spoken coaching line, used only in live grading mode.
    public var coaching: String

    public init(heard: String, speaker: String, radioReplyText: String, correct: Bool,
                corrections: [String], expectedExample: String, phaseAdvance: Bool, coaching: String) {
        self.heard = heard
        self.speaker = speaker
        self.radioReplyText = radioReplyText
        self.correct = correct
        self.corrections = corrections
        self.expectedExample = expectedExample
        self.phaseAdvance = phaseAdvance
        self.coaching = coaching
    }
}
