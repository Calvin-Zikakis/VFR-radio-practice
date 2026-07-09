import Testing
import Foundation
@testable import VFRCore

// MARK: - Drill library

@Test func libraryCoversAllThreeScenarios() {
    for scenario in ScenarioType.allCases {
        #expect(!DrillLibrary.drills(for: scenario).isEmpty,
                "expected drills for \(scenario)")
    }
}

@Test func untoweredFliesTheRV12() {
    let drills = DrillLibrary.drills(for: .untowered)
    #expect(drills.allSatisfy { $0.aircraft.callsign == "N737JA" })
    #expect(drills.first?.aircraft.type.contains("RV-12") == true)
    #expect(drills.contains { $0.airport.icao == "KWVI" }) // Watsonville is home base
}

@Test func drillIDsAreUnique() {
    let ids = DrillLibrary.all.map(\.id)
    #expect(Set(ids).count == ids.count)
}

// MARK: - Trip builder

@Test func tripGeneratesACoherentOrderedFlight() {
    // Watsonville (untowered) → Palo Alto (towered) → Watsonville (untowered).
    let plan = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: true, patternWork: true)
    let plane = DrillLibrary.defaultAircraft
    let drills = TripBuilder.drills(for: plan, aircraft: plane)

    #expect(!drills.isEmpty)
    #expect(Set(drills.map(\.id)).count == drills.count)            // unique ids
    #expect(drills.allSatisfy { $0.aircraft == plane })            // one plane throughout

    // Starts departing the untowered origin, ends with a full-stop untowered arrival.
    #expect(drills.first?.scenario == .untowered)
    #expect(drills.last?.scenario == .untowered)
    #expect(drills.last?.airport.icao == "KWVI")
    #expect(drills.last?.title.contains("Clear of the runway") == true)

    // Covers all three environments: CTAF, tower, and flight following.
    #expect(drills.contains { $0.scenario == .towered && $0.airport.icao == "KPAO" })
    #expect(drills.contains { $0.scenario == .flightFollowing })
}

@Test func tripOmitsFlightFollowingWhenDisabled() {
    let plan = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: false, patternWork: false)
    let drills = TripBuilder.drills(for: plan, aircraft: DrillLibrary.defaultAircraft)
    #expect(!drills.contains { $0.scenario == .flightFollowing })
    // Pattern work off → no downwind/base calls at the stops.
    #expect(!drills.contains { $0.title.contains("Downwind") })
}

@Test func tripNeedsAtLeastTwoStops() {
    let single = TripPlan(stops: Array(DrillLibrary.defaultTripStops.prefix(1)))
    #expect(!single.isValid)
    #expect(TripBuilder.drills(for: single, aircraft: DrillLibrary.defaultAircraft).isEmpty)
}

@Test func spokenRunwayHandlesSuffixes() {
    #expect(TripBuilder.spokenRunway("31") == "three one")
    #expect(TripBuilder.spokenRunway("28R") == "two eight right")
    #expect(TripBuilder.spokenRunway("20") == "two zero")
}

// MARK: - Call-type mix

@Test func callTypeClassificationIsSensible() {
    func type(_ id: String) -> CallType {
        DrillLibrary.callType(for: DrillLibrary.all.first { $0.id == id }!)
    }
    #expect(type("t-readback") == .readback)
    #expect(type("ff-traffic") == .advisory)
    #expect(type("ff-bravo-denied") == .bravo)
    #expect(type("ff-request") == .flightFollowing)
    #expect(type("u-clear") == .afterLanding)
    #expect(type("t-clearance-vfr") == .taxi)      // "clearance" must not read as "clear"
    #expect(type("u-departure") == .departure)
    #expect(type("u-downwind") == .pattern)
    #expect(type("t-inbound") == .arrival)
}

@Test func mixReturnsOnlyMatchingCallTypes() {
    let plane = DrillLibrary.defaultAircraft
    let patternOnly = DrillLibrary.drills(matching: [.pattern], aircraft: plane)
    #expect(!patternOnly.isEmpty)
    #expect(patternOnly.allSatisfy { DrillLibrary.callType(for: $0) == .pattern })
    #expect(patternOnly.allSatisfy { $0.aircraft == plane })

    // Every call type is represented by at least one library drill.
    for type in CallType.allCases {
        #expect(!DrillLibrary.drills(matching: [type], aircraft: plane).isEmpty,
                "no drills for \(type)")
    }
}

// MARK: - New scenario batch (emergencies, airspace, curveballs)

@Test func newScenariosCoverTheirCallTypes() {
    let plane = DrillLibrary.defaultAircraft
    // Emergencies exist and include the big three: declare, lost, radio failure.
    let emergencies = DrillLibrary.drills(matching: [.emergency], aircraft: plane)
    #expect(emergencies.contains { $0.id == "ff-emergency-declare" })
    #expect(emergencies.contains { $0.id == "ff-lost-vectors" })
    #expect(emergencies.contains { $0.id == "t-radio-failure" })

    // Airspace covers Class C entry, Bravo granted, and the D transition.
    let airspace = DrillLibrary.drills(matching: [.bravo], aircraft: plane)
    #expect(airspace.contains { $0.id == "ff-classc-entry" })
    #expect(airspace.contains { $0.id == "ff-bravo-granted" })
    #expect(airspace.contains { $0.id == "t-class-d-transition" })

    // Hold-short and LUAW are readbacks; Salinas-closed is an untowered arrival.
    #expect(DrillLibrary.callType(for: DrillLibrary.all.first { $0.id == "t-luaw" }!) == .readback)
    #expect(DrillLibrary.callType(for: DrillLibrary.all.first { $0.id == "t-holdshort-cross" }!) == .readback)
    let snsClosed = DrillLibrary.all.first { $0.id == "u-sns-tower-closed" }!
    #expect(snsClosed.scenario == .untowered)
}

// MARK: - Drill randomizer

@Test func randomizerKeepsSetupAndSituationConsistent() {
    let atisDrill = DrillLibrary.all.first { $0.id == "t-arrival-atis" }!
    for _ in 0..<20 {
        let varied = DrillRandomizer.vary(atisDrill)
        // Whatever letter the setup briefs is the letter the grader is told.
        let letter = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf",
                      "Hotel", "India", "Juliet", "Kilo", "Lima", "Mike", "November",
                      "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform",
                      "Victor", "Whiskey", "X-ray", "Yankee", "Zulu"]
            .first { varied.setup.contains("information \($0)") }
        #expect(letter != nil)
        if let letter {
            #expect(varied.situation.contains("information \(letter)"))
        }
        // The original "Class Bravo" style phrases must never be corrupted:
        #expect(!varied.setup.contains("information  "))
    }
}

@Test func randomizerVariesSquawkConsistently() {
    let drill = DrillLibrary.all.first { $0.id == "ff-squawk-verify" }!
    let varied = DrillRandomizer.vary(drill)
    // Some spoken 4-digit code is present in both fields, and it's valid.
    #expect(!varied.setup.contains("4521") || varied.setup.contains("four five two one"))
    // Extract nothing fancy — just confirm setup/situation agree on the spoken code.
    let code = DrillRandomizer.randomSquawk()
    #expect(code.count == 4)
    #expect(code.allSatisfy { "01234567".contains($0) })
    #expect(!["1200", "7500", "7600", "7700"].contains(code))
    #expect(DrillRandomizer.spoken(squawk: "4521") == "four five two one")
}

@Test func randomizerVariesDistances() {
    let drill = DrillLibrary.all.first { $0.id == "u-e16-inbound" }!  // "10 miles north"
    var seen = Set<String>()
    for _ in 0..<30 {
        let varied = DrillRandomizer.vary(drill)
        if let range = varied.setup.range(of: #"\d+ miles"#, options: .regularExpression) {
            seen.insert(String(varied.setup[range]))
        }
    }
    #expect(seen.count > 1, "distance should vary across runs")
}

// MARK: - Difficulty

@Test func difficultyChangesTheGradingContract() {
    let drill = DrillLibrary.all.first!
    let student = ATCBrain.systemPrompt(drill: drill, mode: .live, difficulty: .student)
    let checkride = ATCBrain.systemPrompt(drill: drill, mode: .live, difficulty: .checkride)
    let rapid = ATCBrain.systemPrompt(drill: drill, mode: .live, difficulty: .rapidFire)
    #expect(student.contains("DIFFICULTY: STUDENT"))
    #expect(student.contains("hold-short readbacks") || student.contains("hold-short"))
    #expect(!checkride.contains("DIFFICULTY:"))
    #expect(rapid.contains("DIFFICULTY: RAPID-FIRE"))
    // Squawk guidance rides along at every difficulty.
    #expect(checkride.contains("verify squawk"))
}

@Test func tripsIncludeSquawkVerifyWithFlightFollowing() {
    let plan = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: true, patternWork: false)
    let drills = TripBuilder.drills(for: plan, aircraft: DrillLibrary.defaultAircraft)
    #expect(drills.contains { $0.title.contains("Squawk") })
    let noFF = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: false, patternWork: false)
    #expect(!TripBuilder.drills(for: noFF, aircraft: DrillLibrary.defaultAircraft)
        .contains { $0.title.contains("Squawk") })
}

// MARK: - System prompt

@Test func systemPromptCarriesTheKeyFacts() {
    let drill = DrillLibrary.drills(for: .untowered).first!
    let prompt = ATCBrain.systemPrompt(drill: drill, mode: .live)
    #expect(prompt.contains("KWVI"))
    #expect(prompt.contains("N737JA"))
    #expect(prompt.contains("one two two point eight")) // CTAF, spoken form
    #expect(prompt.contains("speech recognition"))       // STT-noise instruction
}

@Test func flightFollowingPromptGradesCallOrder() {
    let ff = DrillLibrary.drills(for: .flightFollowing).first!
    let prompt = ATCBrain.systemPrompt(drill: ff, mode: .live)
    #expect(prompt.contains("CALL ORDER MATTERS"))
    #expect(prompt.contains("four Ws"))
    #expect(prompt.contains("go ahead")) // busy-frequency two-step order
}

@Test func flightFollowingPromptExemptsReadbacksFromCallsignFirst() {
    let ff = DrillLibrary.drills(for: .flightFollowing).first!
    let prompt = ATCBrain.systemPrompt(drill: ff, mode: .live)
    // Readbacks/acknowledgments put the callsign at the END, not first.
    #expect(prompt.contains("READBACKS & ACKNOWLEDGMENTS ARE DIFFERENT"))
    #expect(prompt.contains("callsign conventionally"))
    #expect(prompt.contains("Never tell the pilot to put the callsign first"))
}

@Test func untoweredPromptRequiresClosingAirportName() {
    let u = DrillLibrary.drills(for: .untowered).first!
    let prompt = ATCBrain.systemPrompt(drill: u, mode: .live)
    #expect(prompt.contains("BOOKEND"))
    #expect(prompt.contains("airport name AGAIN at the END"))
    #expect(prompt.contains("REQUIRED"))
}

@Test func livePromptAsksForCoachingDebriefDoesNot() {
    let drill = DrillLibrary.all.first!
    #expect(ATCBrain.systemPrompt(drill: drill, mode: .live).contains("coaching`"))
    #expect(ATCBrain.systemPrompt(drill: drill, mode: .debrief).contains("empty"))
}

// MARK: - Request body

@Test func requestBodyOrdersHistoryThenTransmission() {
    let brain = ATCBrain(apiKey: "test")
    let drill = DrillLibrary.all.first!
    let history = [Turn(pilot: "first call", reply: "roger")]
    let body = brain.requestBody(drill: drill, mode: .live, history: history,
                                 transmission: "second call")

    #expect(body["model"] as? String == "claude-haiku-4-5")
    let messages = body["messages"] as! [[String: Any]]
    #expect(messages.count == 3) // user, assistant, user
    #expect(messages.first?["content"] as? String == "first call")
    #expect(messages.last?["content"] as? String == "second call")

    // System prompt is cacheable.
    let system = body["system"] as! [[String: Any]]
    #expect((system.first?["cache_control"] as? [String: String])?["type"] == "ephemeral")
}

// MARK: - Response parsing

@Test func parsesStructuredVerdict() throws {
    let inner = """
    {"heard":"Watsonville traffic, Experimental 737JA, taxiing runway 20, Watsonville",\
    "speaker":"none","radioReplyText":"","correct":true,"corrections":[],\
    "expectedExample":"Watsonville traffic, Experimental seven three seven juliet alpha, \
    taxiing to runway two zero, Watsonville","phaseAdvance":true,"coaching":"Nicely done."}
    """
    let response = """
    {"stop_reason":"end_turn","content":[{"type":"text","text":\(jsonString(inner))}]}
    """
    let verdict = try ATCBrain.parseVerdict(from: Data(response.utf8))
    #expect(verdict.correct)
    #expect(verdict.phaseAdvance)
    #expect(verdict.speaker == "none")
}

@Test func refusalStopReasonThrows() {
    let response = #"{"stop_reason":"refusal","content":[]}"#
    #expect(throws: ATCBrainError.self) {
        try ATCBrain.parseVerdict(from: Data(response.utf8))
    }
}

// MARK: - Session flow (mocked brain, no network)

/// Mock grader: marks the pilot correct once their text contains `passWhenContains`.
struct MockBrain: ATCEvaluating {
    let passWhenContains: String
    func evaluate(drill: Drill, mode: GradingMode, history: [Turn],
                  transmission: String) async throws -> Verdict {
        let ok = transmission.localizedCaseInsensitiveContains(passWhenContains)
        return Verdict(
            heard: transmission, speaker: ok ? "none" : "CTAF",
            radioReplyText: "", correct: ok,
            corrections: ok ? [] : ["Missing the airport name"],
            expectedExample: "model call", phaseAdvance: ok, coaching: ok ? "Good." : "Try again."
        )
    }
}

@Test func sessionAdvancesOnCorrectAndDebriefsOnWrong() async throws {
    let drills = Array(DrillLibrary.drills(for: .untowered).prefix(2))
    let session = PracticeSession(brain: MockBrain(passWhenContains: "watsonville"),
                                  mode: .debrief, drills: drills)

    // Wrong answer: stays on drill 0, records a debrief note.
    let v1 = try await session.submit("uh, taxiing out")
    #expect(v1?.correct == false)
    #expect(await session.progress.drillIndex == 0)
    #expect(await session.debrief.count == 1)

    // Correct answer: advances to drill 1.
    let v2 = try await session.submit("Watsonville traffic, RV-12 737JA, taxiing")
    #expect(v2?.correct == true)
    #expect(await session.progress.drillIndex == 1)

    // Finish drill 1, session complete.
    _ = try await session.submit("Watsonville traffic, departing")
    #expect(await session.isFinished)
}

// MARK: - Helpers

/// JSON-encode a string so it can be embedded as a value in a larger JSON blob.
private func jsonString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s], options: []), encoding: .utf8)!
        .dropFirst().dropLast().description // strip the surrounding [ ]
}
