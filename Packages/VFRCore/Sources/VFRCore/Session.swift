import Foundation

/// Drives one practice session: presents drills, sends transmissions to the
/// ATC brain, tracks progress, and produces a debrief. UI- and audio-agnostic
/// so it is fully testable on macOS.
public actor PracticeSession {
    public struct Progress: Sendable, Equatable {
        public var drillIndex: Int
        public var totalDrills: Int
        public var attemptsOnCurrent: Int
    }

    /// A saved note for the end-of-session debrief. Codable so an in-flight
    /// session can be snapshotted and resumed across app launches.
    public struct DebriefEntry: Sendable, Equatable, Codable {
        public var drillTitle: String
        public var pilotSaid: String
        public var corrections: [String]
        public var expectedExample: String

        public init(drillTitle: String, pilotSaid: String,
                    corrections: [String], expectedExample: String) {
            self.drillTitle = drillTitle
            self.pilotSaid = pilotSaid
            self.corrections = corrections
            self.expectedExample = expectedExample
        }
    }

    private let brain: any ATCEvaluating
    private let mode: GradingMode
    private let drills: [Drill]
    private var index = 0
    private var attempts = 0
    private var history: [Turn] = []
    private(set) public var debrief: [DebriefEntry] = []

    /// `startIndex` and `debrief` support resuming a snapshotted session (or
    /// starting a scenario from a chosen drill).
    public init(brain: any ATCEvaluating, mode: GradingMode, drills: [Drill],
                startIndex: Int = 0, debrief: [DebriefEntry] = []) {
        self.brain = brain
        self.mode = mode
        self.drills = drills
        self.index = min(max(0, startIndex), drills.count)
        self.debrief = debrief
    }

    public var currentDrill: Drill? {
        index < drills.count ? drills[index] : nil
    }

    public var isFinished: Bool { index >= drills.count }

    public var progress: Progress {
        Progress(drillIndex: index, totalDrills: drills.count, attemptsOnCurrent: attempts)
    }

    /// Submit a pilot transmission for the current drill. Returns the verdict,
    /// or nil if the session is already finished.
    public func submit(_ transmission: String) async throws -> Verdict? {
        guard let drill = currentDrill else { return nil }
        attempts += 1
        // Continuity: when the session continues at the same airport, the
        // grader is told what the script does next so its improvised replies
        // can't contradict it (e.g. "report right base" before a scripted
        // left-downwind report).
        let next = index + 1 < drills.count ? drills[index + 1] : nil
        let nextSetup = next?.airport.icao == drill.airport.icao ? next?.setup : nil
        let verdict = try await brain.evaluate(drill: drill, mode: mode,
                                               history: history, transmission: transmission,
                                               nextSetup: nextSetup)
        history.append(Turn(pilot: verdict.heard, reply: verdict.radioReplyText))

        if !verdict.correct {
            recordDebrief(drill: drill, verdict: verdict)
        }
        if verdict.phaseAdvance {
            advance()
        }
        return verdict
    }

    /// Skip the current drill without grading (e.g. voice command "skip").
    public func skip() {
        advance()
    }

    private func advance() {
        index += 1
        attempts = 0
        history.removeAll()
    }

    private func recordDebrief(drill: Drill, verdict: Verdict) {
        debrief.append(DebriefEntry(
            drillTitle: drill.title,
            pilotSaid: verdict.heard,
            corrections: verdict.corrections,
            expectedExample: verdict.expectedExample
        ))
    }
}
