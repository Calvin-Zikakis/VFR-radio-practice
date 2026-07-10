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
    /// Mutable: passing a `followUpReadback` drill inserts a synthesized
    /// readback drill right after it.
    private var drills: [Drill]
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

    /// The live drill list, including any injected readback follow-ups —
    /// snapshots must save this (not the original set) so resuming lands on
    /// the right drill.
    public var liveDrills: [Drill] { drills }

    /// True when the current drill's exchange has already started — resuming
    /// then must NOT re-brief the drill from the top.
    public var isMidExchange: Bool { !history.isEmpty }

    /// The controller's most recent radio line in the current exchange, for
    /// re-anchoring the pilot after a pause.
    public var lastRadioReply: String? {
        history.last(where: { !$0.reply.isEmpty })?.reply
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
        var verdict = try await brain.evaluate(drill: drill, mode: mode,
                                               history: history, transmission: transmission,
                                               nextSetup: nextSetup)

        // App-composed instruction: on the advancing turn the SESSION issues
        // the drill's authored clearance, not the grader. Whatever reply the
        // model improvised is replaced, so the spoken instruction and the
        // injected drill's grading target are the same string by construction.
        let willInject = drill.followUpReadback == true && drill.instruction != nil
        if verdict.phaseAdvance, willInject, let instruction = drill.instruction {
            if !verdict.radioReplyText.isEmpty, verdict.radioReplyText != instruction {
                vfrLog("grader improvised a reply on an app-composed advance — overridden")
            }
            verdict.radioReplyText = instruction
        }

        // A crossing or hold-short in the radio reply always demands a
        // readback. When an injected follow-up drill will grade it, that's
        // fine; anywhere else, advancing past it is a grader contradiction
        // (seen live) — hold the step.
        if verdict.phaseAdvance, !willInject {
            let reply = verdict.radioReplyText.lowercased()
            if reply.contains("cross runway") || reply.contains("hold short") {
                vfrLog("grader contradiction — advance while reply demands a readback; holding the step")
                verdict.phaseAdvance = false
            }
        }

        history.append(Turn(pilot: verdict.heard, reply: verdict.radioReplyText))

        if !verdict.correct {
            recordDebrief(drill: drill, verdict: verdict)
        }
        if verdict.phaseAdvance {
            if willInject, let instruction = drill.instruction {
                let followUp = readbackFollowUp(for: drill, verdict: verdict,
                                                instruction: instruction)
                drills.insert(followUp, at: index + 1)
                vfrLog("injected readback drill for '\(drill.id)'")
            }
            advance()
        }
        return verdict
    }

    /// The synthesized drill that grades the pilot's readback of the exact
    /// instruction the session just spoke. Inherits the parent drill's
    /// (already randomized) context; the clearance text itself is the content.
    private func readbackFollowUp(for drill: Drill, verdict: Verdict,
                                  instruction: String) -> Drill {
        let voice: String
        switch verdict.speaker {
        case "Ground", "Tower": voice = "\(drill.airport.name) \(verdict.speaker)"
        case "Approach", "Center": voice = "NorCal \(verdict.speaker)"
        case "", "none": voice = "\(drill.airport.name) \(drill.airport.isTowered ? "Tower" : "Ground")"
        default: voice = verdict.speaker
        }
        return Drill(
            id: "\(drill.id)-readback",
            scenario: drill.scenario,
            title: "Read back your instructions",
            setup: "\(voice) has just given you your instructions. Read them back — and if you missed part of it, ask them to say again.",
            situation: "You are \(voice). You just issued exactly this instruction: '\(instruction)'. Grade the pilot's readback against it — every element that requires a readback must be VERBATIM: runway instructions (assigned runway, route, crossings, hold shorts), squawk codes, frequencies, altitude restrictions, and clearances, plus the callsign. Advisory extras in your instruction (traffic, weather, 'radar contact') need no readback. If anything required is missing or wrong, say exactly which item to read back and do not advance. If the pilot asks you to say again, repeat the instruction verbatim and do not advance. Set phaseAdvance true only on a complete, correct readback.",
            aircraft: drill.aircraft,
            airport: drill.airport,
            callType: .readback,
            injectedReadback: true)
    }

    /// Skip the current drill without grading (e.g. voice command "skip").
    public func skip() {
        advance()
    }

    /// Fetch the model call for the current drill on demand (voice command
    /// "example"). Goes to the brain but leaves history, attempts, and the
    /// debrief untouched — asking to hear the ideal call isn't an attempt.
    public func modelExample() async throws -> String? {
        guard let drill = currentDrill else { return nil }
        let verdict = try await brain.evaluate(
            drill: drill, mode: mode, history: history,
            transmission: "(Not a radio call: the pilot asks to hear the model call for this situation before trying. Put the ideal transmission in expectedExample; do not grade or advance.)",
            nextSetup: nil)
        return verdict.expectedExample
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
