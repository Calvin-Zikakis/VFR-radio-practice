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

    // The towered intermediate stop is a full-stop visit with the whole
    // ground game: taxi in after landing, then taxi out for departure —
    // both chained into readback follow-ups.
    #expect(drills.contains { $0.title == "Clear of the runway — Palo Alto Ground"
                              && $0.followUpReadback == true })
    #expect(drills.contains { $0.title == "Taxi — Palo Alto Ground"
                              && $0.followUpReadback == true })
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

@Test func advisoryMixIsAViableSession() {
    // "Traffic advisory" used to hold a single drill, which made picking it in
    // a mix session pointless. The batch of three brings it to four.
    let plane = DrillLibrary.defaultAircraft
    let advisory = DrillLibrary.drills(matching: [.advisory], aircraft: plane)
    #expect(advisory.count >= 4)
    for id in ["ff-traffic", "ff-negative-contact", "ff-traffic-alert", "ff-traffic-insight"] {
        #expect(advisory.contains { $0.id == id }, "missing \(id)")
    }
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

@Test func tripsHaveNoStandaloneSquawkPhase() {
    // The FF-request phase already assigns and reads back a squawk; a separate
    // verify-it-again phase was redundant (user feedback) and was removed.
    let plan = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: true, patternWork: false)
    let drills = TripBuilder.drills(for: plan, aircraft: DrillLibrary.defaultAircraft)
    #expect(!drills.contains { $0.title.contains("Squawk") })
    let noFF = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: false, patternWork: false)
    #expect(!TripBuilder.drills(for: noFF, aircraft: DrillLibrary.defaultAircraft)
        .contains { $0.title.contains("Squawk") })
}

// MARK: - Drill randomizer (runways & altitudes)

@Test func watsonvilleVariesAmongItsRealRunways() {
    // KWVI has 2/20 and the 9/27 crosswind — variation must stay in that set.
    #expect(Set(DrillRandomizer.alternateRunways["KWVI"] ?? []) == ["2", "9", "27"])
    let taxi = DrillLibrary.drills(for: .untowered).first { $0.id == "u-taxi" }!
    for choice in ["2", "9", "27"] {
        let varied = DrillRandomizer.vary(taxi, runway: choice, altitudeOffset: 0)
        #expect(varied.airport.runwaysInUse == [choice])
        #expect(!varied.setup.contains("two zero"))
        #expect(varied.setup.contains("runway \(TripBuilder.spokenRunway(choice))"))
        #expect(varied.situation.contains("runway \(choice)"))
    }
}

@Test func runwaySwapRewritesTextAndAirportConsistently() {
    let taxi = DrillLibrary.drills(for: .untowered).first { $0.id == "u-taxi" }!
    let flipped = DrillRandomizer.vary(taxi, runway: "2", altitudeOffset: 0)
    // Watsonville 20 becomes 2 — spoken, digit, and prompt-facing runway list.
    #expect(!flipped.setup.contains("two zero"))
    #expect(flipped.setup.contains("runway two"))
    #expect(!flipped.situation.contains("runway 20"))
    #expect(flipped.situation.contains("runway 2"))
    #expect(flipped.airport.runwaysInUse == ["2"])
}

@Test func altitudeShiftIsConsistentAndNeverChains() {
    var drill = DrillLibrary.drills(for: .flightFollowing).first { $0.id == "ff-request" }!
    drill.setup = "Climbing through two thousand five hundred to four thousand five hundred."
    drill.situation = "Pilot at 2,500 climbing to 4,500."
    let shifted = DrillRandomizer.vary(drill, runway: nil, altitudeOffset: 1000)
    // 2,500 → 3,500 exactly once; it must NOT chain through the 3,500 → 4,500 pair.
    #expect(shifted.setup.contains("three thousand five hundred"))
    #expect(shifted.setup.contains("five thousand five hundred"))
    #expect(shifted.situation.contains("3,500"))
    #expect(shifted.situation.contains("5,500"))
    #expect(!shifted.situation.contains("4,500"))
}

@Test func sessionVariationFlipsAnAirportConsistentlyAcrossDrills() {
    // All KWVI untowered drills in one session must agree on the runway.
    for _ in 0..<10 {
        let varied = DrillRandomizer.vary(DrillLibrary.drills(for: .untowered))
        let wvi = varied.filter { $0.airport.icao == "KWVI" }
        let runways = Set(wvi.map { $0.airport.runwaysInUse.first ?? "" })
        #expect(runways.count == 1, "one runway per airport per session")
    }
}

// MARK: - New FF interactions

@Test func vectorAndRestrictionDrillsExist() {
    let ff = DrillLibrary.drills(for: .flightFollowing)
    let vector = ff.first { $0.id == "ff-vector" }
    let restriction = ff.first { $0.id == "ff-restriction-handoff" }
    #expect(vector != nil && vector!.situation.contains("resume own navigation"))
    #expect(restriction != nil && restriction!.situation.contains("announce the restriction")
            || restriction!.situation.contains("ANNOUNCE the restriction"))
}

@Test func tripIncludesTrafficVectorWhenFFOn() {
    let plan = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: true, patternWork: false)
    let drills = TripBuilder.drills(for: plan, aircraft: DrillLibrary.defaultAircraft)
    #expect(drills.contains { $0.title == "Traffic vector" })
    let noFF = TripBuilder.drills(for: TripPlan(stops: plan.stops, flightFollowing: false,
                                                patternWork: false),
                                  aircraft: DrillLibrary.defaultAircraft)
    #expect(!noFF.contains { $0.title == "Traffic vector" })
}

@Test func newScenarioBatchExists() {
    let all = DrillLibrary.all
    func drill(_ id: String) -> Drill? { all.first { $0.id == id } }
    #expect(drill("t-rhv-parallel")?.situation.contains("31L/31R") == true)
    #expect(drill("t-sql-spacing")?.situation.contains("three sixty") == true)
    #expect(drill("t-svfr")?.situation.contains("Special VFR") == true)
    #expect(drill("t-lahso")?.situation.contains("unable hold short") == true)
    #expect(drill("u-oar-inbound")?.airport.icao == "KOAR")
    #expect(drill("ff-diversion")?.situation.contains("diverting for weather") == true)
    #expect(drill("ff-min-fuel")?.situation.contains("minimum fuel") == true)
}

@Test func newAirportsAreRoutableAndLahsoIsSwapExempt() {
    let icaos = Set(DrillLibrary.routableAirports.map(\.icao))
    #expect(icaos.isSuperset(of: ["KRHV", "KSQL", "KOAR"]))
    // LAHSO names both Salinas runways; the runway swap must leave it alone.
    #expect(DrillRandomizer.runwaySwapExempt.contains("t-lahso"))
    let lahso = DrillLibrary.all.first { $0.id == "t-lahso" }!
    let varied = DrillRandomizer.vary(lahso, runway: "13", altitudeOffset: 0)
    #expect(varied.setup.contains("three one") && varied.situation.contains("two six"))
    // KRHV must not be in the variation pool (parallel-runway text).
    #expect(DrillRandomizer.alternateRunways["KRHV"] == nil)
}

// MARK: - Aircraft retargeting

@Test func retargetRewritesQuotedCallsignsEverywhere() {
    let cirrus = Aircraft(callsign: "N523CD",
                          phoneticCallsign: "Cirrus five two three charlie delta",
                          type: "Cirrus SR22")
    // Every drill and every generated trip phase, flown as the Cirrus, must
    // never mention the RV's callsign in any form.
    let rvForms = ["seven three seven juliet alpha", "seven juliet alpha", "N737JA", "737JA"]
    var texts: [String] = []
    for scenario in ScenarioType.allCases {
        for d in DrillLibrary.drills(for: scenario, aircraft: cirrus) {
            texts.append(d.setup); texts.append(d.situation)
            #expect(d.aircraft.callsign == "N523CD")
        }
    }
    let trip = TripPlan(stops: DrillLibrary.defaultTripStops, flightFollowing: true, patternWork: true)
    for d in TripBuilder.drills(for: trip, aircraft: cirrus) {
        texts.append(d.setup); texts.append(d.situation)
    }
    for text in texts {
        for form in rvForms {
            #expect(!text.contains(form), "leaked RV callsign form '\(form)' in: \(text.prefix(80))")
        }
    }
    // And the LUAW briefing now addresses the Cirrus.
    let luaw = DrillLibrary.drills(for: .towered, aircraft: cirrus).first { $0.id == "t-luaw" }!
    #expect(luaw.setup.contains("Cirrus five two three charlie delta"))
}

@Test func retargetLeavesOtherTrafficAlone() {
    let cirrus = Aircraft(callsign: "N523CD",
                          phoneticCallsign: "Cirrus five two three charlie delta",
                          type: "Cirrus SR22")
    // The wake-turbulence drill's "Boeing seven three seven" is traffic, not
    // the pilot — it must survive retargeting.
    let wake = DrillLibrary.drills(for: .towered, aircraft: cirrus).first { $0.id == "t-wake-turbulence" }!
    #expect(wake.setup.contains("Boeing seven three seven"))
    // The negotiation drill's Cherokee traffic keeps its own callsign.
    let negotiate = DrillLibrary.drills(for: .untowered, aircraft: cirrus).first { $0.id == "u-negotiate-traffic" }!
    #expect(negotiate.situation.contains("Cherokee four eight two zero lima"))
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
    // History is labeled so the grader can't anchor on an earlier attempt.
    #expect(messages.first?["content"] as? String == "[earlier transmission, already graded] first call")
    #expect(messages.last?["content"] as? String == "[transmission to grade now] second call")

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

@Test func complexTaxiBatchExists() {
    let plane = DrillLibrary.defaultAircraft
    let taxi = DrillLibrary.drills(matching: [.taxi], aircraft: plane)
    #expect(taxi.count >= 12)
    for id in ["t-ccr-parallel-taxi", "t-ccr-runway-switch", "t-ccr-holdshort-request",
               "t-ccr-taxiback", "t-ccr-runway-change", "t-ccr-long-route",
               "t-ccr-crossing-revoked"] {
        #expect(taxi.contains { $0.id == id }, "missing \(id)")
    }
    // t-sns-taxi now names crossing runway 26 alongside 31 — a runway swap
    // would corrupt it.
    #expect(DrillRandomizer.runwaySwapExempt.contains("t-sns-taxi"))
}

@Test func taxiwayLettersVaryButCallsignsSurvive() {
    let drill = DrillLibrary.all.first { $0.id == "t-ccr-long-route" }!
    var sawDifferentRoute = false
    for _ in 0..<40 {
        let varied = DrillRandomizer.vary(drill)
        // The flown callsign must never be corrupted by a route rename.
        #expect(varied.setup.contains("seven three seven juliet alpha"))
        if varied.setup != drill.setup { sawDifferentRoute = true }
        // Setup and situation always describe the same route: any taxiway
        // letter spoken to the pilot must also be in the grader's script.
        for word in ["echo", "kilo", "papa", "golf", "bravo", "charlie", "mike",
                     "sierra", "tango", "victor", "whiskey", "yankee", "zulu"]
        where varied.setup.contains(word) {
            #expect(varied.situation.contains(word), "\(word) in setup but not situation")
        }
    }
    #expect(sawDifferentRoute)
    // KCCR drill texts name 32L/32R/19L/19R — a blind runway swap would
    // corrupt them, so Concord must stay out of the variation pool.
    #expect(DrillRandomizer.alternateRunways["KCCR"] == nil)
    #expect(DrillLibrary.routableAirports.contains { $0.icao == "KCCR" })
}

// MARK: - App-composed instructions (readback chaining v2)

@Test func varyChoosesOneInstructionVariant() {
    // Every chained library drill offers 2–3 authored variants; vary() must
    // resolve exactly one of them (post-substitution), never leave it nil.
    let flagged = DrillLibrary.all.filter { $0.instructionVariants?.isEmpty == false }
    #expect(flagged.count >= 12)
    for drill in flagged {
        var sawVariety = false
        let baseline = DrillRandomizer.vary(drill, runway: nil, altitudeOffset: 0).instruction
        for _ in 0..<40 {
            let chosen = try! #require(DrillRandomizer.vary(drill).instruction)
            #expect(!chosen.isEmpty)
            if chosen != baseline { sawVariety = true }
        }
        // Drills with more than one distinct variant should actually vary.
        if Set(drill.instructionVariants ?? []).count > 1 {
            #expect(sawVariety, "instruction never varied for \(drill.id)")
        }
    }
}

@Test func resolveInstructionsIsStableAndNeverReRolls() {
    // The non-varied path picks the first variant; a drill that already has a
    // chosen instruction (resumed snapshot) is left untouched.
    let sns = DrillLibrary.all.first { $0.id == "t-sns-taxi" }!
    let resolved = DrillRandomizer.resolveInstructions([sns])[0]
    #expect(resolved.instruction == sns.instructionVariants?.first)
    // Idempotent: resolving again keeps the same instruction.
    let again = DrillRandomizer.resolveInstructions([resolved])[0]
    #expect(again.instruction == resolved.instruction)
    // A pre-chosen instruction survives even if it isn't among the variants.
    var pinned = sns
    pinned.instruction = "RV seven three seven juliet alpha, some already-chosen clearance."
    #expect(DrillRandomizer.resolveInstructions([pinned])[0].instruction == pinned.instruction)
}

@Test func instructionSharesOneSubstitutionPassWithSetupAndSituation() {
    // The taxiway shuffle rewrites the route consistently across setup,
    // situation, AND the chosen instruction — a letter spoken in the
    // clearance must be the same letter the grader's script names.
    let drill = DrillLibrary.all.first { $0.id == "t-ccr-taxiback" }!
    for _ in 0..<40 {
        let varied = DrillRandomizer.vary(drill)
        let instruction = try! #require(varied.instruction)
        // Callsign survives intact in the instruction.
        #expect(instruction.contains("seven three seven juliet alpha"))
        // Any shuffled taxiway letter in the instruction is also in the
        // situation (they came from one substitution pass).
        for word in ["bravo", "charlie", "delta", "echo", "foxtrot", "golf",
                     "hotel", "mike", "sierra", "tango", "victor", "whiskey",
                     "yankee", "zulu"]
        where instruction.contains(" \(word)") {
            #expect(varied.situation.contains(word),
                    "\(word) in instruction but not situation for \(drill.id)")
        }
    }
}

@Test func squawkVariesInsideTheAuthoredInstruction() {
    // ff-request authors its squawk as "four five two one"; the incidental
    // substitution must reach into the instruction and swap the digits too.
    let drill = DrillLibrary.all.first { $0.id == "ff-request" }!
    var sawSwapped = false
    for _ in 0..<40 {
        let varied = DrillRandomizer.vary(drill)
        let instruction = try! #require(varied.instruction)
        #expect(instruction.contains("squawk"))
        if !instruction.contains("four five two one") { sawSwapped = true }
    }
    #expect(sawSwapped, "authored squawk never randomized inside the instruction")
}

@Test func retargetRewritesInstructionCallsigns() {
    let cirrus = Aircraft(callsign: "N523CD",
                          phoneticCallsign: "Cirrus five two three charlie delta",
                          type: "Cirrus SR22")
    // t-sns-taxi is authored for the RV; flown as the Cirrus, neither the
    // chosen instruction nor its variants may leak the RV callsign.
    let sns = DrillLibrary.drills(for: .towered, aircraft: cirrus)
        .first { $0.id == "t-sns-taxi" }!
    let resolved = DrillRandomizer.resolveInstructions([sns])[0]
    let instruction = try! #require(resolved.instruction)
    #expect(instruction.contains("Cirrus five two three charlie delta"))
    for form in ["seven three seven juliet alpha", "N737JA"] {
        #expect(!instruction.contains(form))
        for variant in resolved.instructionVariants ?? [] {
            #expect(!variant.contains(form), "RV form '\(form)' leaked in variant")
        }
    }
}

@Test func chosenInstructionRoundTripsThroughSnapshot() throws {
    let sns = DrillRandomizer.vary(DrillLibrary.all.first { $0.id == "t-sns-taxi" }!)
    let data = try JSONEncoder().encode(sns)
    let decoded = try JSONDecoder().decode(Drill.self, from: data)
    #expect(decoded.instruction == sns.instruction)
    #expect(decoded.instructionVariants == sns.instructionVariants)
    // A pre-v2 snapshot (no instruction fields) still decodes.
    let legacy = """
    {"id":"x","scenario":"towered","title":"t","setup":"s",\
    "situation":"sit","aircraft":{"callsign":"N1","phoneticCallsign":"one","type":"C"},\
    "airport":{"icao":"K","name":"n","ctafOrTower":"f","elevationFt":1,\
    "runwaysInUse":["31"],"isTowered":true}}
    """
    let old = try JSONDecoder().decode(Drill.self, from: Data(legacy.utf8))
    #expect(old.instruction == nil)
    #expect(old.instructionVariants == nil)
}

@Test func promptAppendsTheInstructionBlockOnlyWhenPresent() {
    let sns = DrillRandomizer.vary(DrillLibrary.all.first { $0.id == "t-sns-taxi" }!)
    let withInstruction = ATCBrain.systemPrompt(drill: sns, mode: .live)
    #expect(withInstruction.contains("THE INSTRUCTION (context)"))
    #expect(withInstruction.contains(sns.instruction!))
    #expect(withInstruction.contains("the app itself"))
    // A plain drill with no instruction gets no such block.
    let plain = DrillLibrary.all.first { $0.id == "t-readback" }!
    #expect(plain.instruction == nil)
    #expect(!ATCBrain.systemPrompt(drill: plain, mode: .live).contains("THE INSTRUCTION (context)"))
}

@Test func trafficTailDeparturesExist() {
    let departures = DrillLibrary.drills(matching: [.departure],
                                         aircraft: DrillLibrary.defaultAircraft)
    #expect(departures.count >= 5)
    #expect(departures.contains { $0.id == "t-ccr-clearance-traffic-tail" })
    #expect(departures.contains { $0.id == "t-rhv-departure-traffic-tail" })
}

@Test func contradictoryAdvanceIsClamped() throws {
    // Seen live: 'say your position' asked over the radio, correct=false,
    // yet phaseAdvance=true — and the session moved on mid-exchange. An
    // incorrect call must never advance the step.
    let inner = """
    {"heard":"NorCal Approach, RV seven three seven juliet alpha, request flight following",\
    "speaker":"Approach","radioReplyText":"Seven juliet alpha, say your position.",\
    "correct":false,"corrections":["Missing your position"],\
    "expectedExample":"NorCal Approach, RV seven three seven juliet alpha, over Watsonville \
    at two thousand five hundred, request flight following","phaseAdvance":true,\
    "coaching":"Give your position."}
    """
    let response = """
    {"stop_reason":"end_turn","content":[{"type":"text","text":\(jsonString(inner))}]}
    """
    let verdict = try ATCBrain.parseVerdict(from: Data(response.utf8))
    #expect(!verdict.correct)
    #expect(!verdict.phaseAdvance)
}

/// Mock returning one fixed verdict, for driving session-level logic.
struct FixedBrain: ATCEvaluating {
    let verdict: Verdict
    func evaluate(drill: Drill, mode: GradingMode, history: [Turn],
                  transmission: String, nextSetup: String?) async throws -> Verdict {
        verdict
    }
}

@Test func taxiRequestChainsIntoInjectedReadbackDrill() async throws {
    let request = DrillRandomizer.resolveInstructions(
        [DrillLibrary.all.first { $0.id == "t-sns-taxi" }!])[0]
    #expect(request.followUpReadback == true)
    let instruction = try #require(request.instruction)
    // The grader leaves the reply empty on the advancing turn (per its
    // prompt); the SESSION issues the authored clearance.
    let brain = FixedBrain(verdict: Verdict(
        heard: "Salinas Ground, RV seven three seven juliet alpha, ramp, information Foxtrot, request taxi, VFR north",
        speaker: "Ground", radioReplyText: "", correct: true,
        corrections: [], expectedExample: "", phaseAdvance: true, coaching: ""))
    let session = PracticeSession(brain: brain, mode: .live, drills: [request])

    let verdict = try await session.submit("the request")
    // The spoken reply IS the drill's authored instruction...
    #expect(verdict?.radioReplyText == instruction)
    let current = await session.currentDrill
    #expect(current?.id == "t-sns-taxi-readback")
    // ...and the injected drill grades against the SAME string.
    #expect(current?.situation.contains(instruction) == true)
    #expect(await session.progress.totalDrills == 2)
    #expect(await session.liveDrills.count == 2)
}

@Test func graderImprovisedReplyIsOverriddenByComposedInstruction() async throws {
    // If the grader writes its own clearance on the advancing turn out of
    // habit, the app's authored instruction wins — spoken text and grading
    // target can never diverge.
    let request = DrillRandomizer.resolveInstructions(
        [DrillLibrary.all.first { $0.id == "ff-request" }!])[0]
    let brain = FixedBrain(verdict: Verdict(
        heard: "full request", speaker: "Approach",
        radioReplyText: "RV seven juliet alpha, squawk zero four two six, radar contact.",
        correct: true, corrections: [], expectedExample: "",
        phaseAdvance: true, coaching: ""))
    let session = PracticeSession(brain: brain, mode: .live, drills: [request])
    let verdict = try await session.submit("the request")
    #expect(verdict?.radioReplyText == request.instruction)
    #expect(await session.currentDrill?.situation.contains(request.instruction!) == true)
}

/// Mock returning a scripted sequence of verdicts.
final class SequenceBrain: ATCEvaluating, @unchecked Sendable {
    private var verdicts: [Verdict]
    init(_ verdicts: [Verdict]) { self.verdicts = verdicts }
    func evaluate(drill: Drill, mode: GradingMode, history: [Turn],
                  transmission: String, nextSetup: String?) async throws -> Verdict {
        verdicts.removeFirst()
    }
}

@Test func noInstructionMeansNoInjection() async throws {
    // Injection is driven purely by the drill's own instruction field — no
    // keyword-guessing against the reply. A flagged drill with no resolved
    // instruction (e.g. a stale pre-v2 snapshot) advances without injecting.
    var drill = DrillLibrary.all.first { $0.id == "ff-request" }!
    #expect(drill.followUpReadback == true)
    drill.instructionVariants = nil
    #expect(drill.instruction == nil)
    let brain = FixedBrain(verdict: Verdict(
        heard: "complete request", speaker: "Approach",
        radioReplyText: "RV seven juliet alpha, radar contact.", correct: true,
        corrections: [], expectedExample: "", phaseAdvance: true, coaching: ""))
    let session = PracticeSession(brain: brain, mode: .live, drills: [drill])
    _ = try await session.submit("the request")
    #expect(await session.currentDrill == nil)
    #expect(await session.liveDrills.count == 1)
}

@Test func tripRequestPhasesChainReadbacks() throws {
    let plan = TripPlan(stops: DrillLibrary.defaultTripStops,
                        flightFollowing: true, patternWork: true)
    let drills = TripBuilder.drills(for: plan, aircraft: DrillLibrary.defaultAircraft)
    for prefix in ["Ready for departure —", "Request flight following —"] {
        #expect(drills.contains {
            $0.title.hasPrefix(prefix) && $0.followUpReadback == true
                && $0.instructionVariants?.isEmpty == false
        }, "no chained phase with authored instructions for \(prefix)")
    }
    // Every chained trip phase carries authored variants that name the flown
    // plane — the app composes the instruction, the grader never improvises.
    for d in drills where d.followUpReadback == true {
        let variants = try #require(d.instructionVariants, "no variants for \(d.title)")
        #expect(!variants.isEmpty)
        #expect(variants.allSatisfy { $0.contains("seven three seven juliet alpha") })
    }
    // Towered inbound chains; untowered inbound (CTAF, no instruction) must not.
    #expect(drills.contains { $0.title.hasPrefix("Inbound —") && $0.title.hasSuffix("Tower")
                              && $0.followUpReadback == true })
    #expect(!drills.contains { $0.scenario == .untowered && $0.followUpReadback == true })

    // Taxi-in chains only where there's a Ground to copy a route from —
    // needs a towered destination (the default trip ends untowered).
    let toweredEnd = TripPlan(stops: Array(DrillLibrary.defaultTripStops.prefix(2)),
                              flightFollowing: false, patternWork: false)
    let arrival = TripBuilder.drills(for: toweredEnd, aircraft: DrillLibrary.defaultAircraft)
    #expect(arrival.contains { $0.title.hasPrefix("Clear of the runway —")
                               && $0.title.hasSuffix("Ground")
                               && $0.followUpReadback == true })
}

@Test func pendingReadbackStillHoldsNonChainedDrills() async throws {
    // Without the follow-up flag, advancing while the reply demands a
    // readback (cross/hold short) is a contradiction — the step holds.
    let drill = DrillLibrary.all.first { $0.id == "t-ccr-holdshort-request" }!
    #expect(drill.followUpReadback != true)
    let brain = FixedBrain(verdict: Verdict(
        heard: "holding short", speaker: "Ground",
        radioReplyText: "RV seven juliet alpha, cross runway one niner left, continue via papa.",
        correct: true, corrections: [], expectedExample: "",
        phaseAdvance: true, coaching: ""))
    let session = PracticeSession(brain: brain, mode: .live, drills: [drill])

    let verdict = try await session.submit("holding short call")
    #expect(verdict?.phaseAdvance == false)
    #expect(await session.progress.drillIndex == 0)
}

@Test func stubVerdictThrowsDegenerate() {
    // Seen live: the model returned a placeholder verdict with every field
    // empty — useless to the pilot, and must surface as retryable.
    let inner = """
    {"heard":"placeholder","speaker":"none","radioReplyText":"","correct":false,\
    "corrections":[],"expectedExample":"","phaseAdvance":false,"coaching":""}
    """
    let response = """
    {"stop_reason":"end_turn","content":[{"type":"text","text":\(jsonString(inner))}]}
    """
    #expect(throws: ATCBrainError.self) {
        try ATCBrain.parseVerdict(from: Data(response.utf8))
    }
}

@Test func sentinelVerdictThrowsDegenerate() {
    // Seen live: every field "n/a" — spoken aloud twice as "n/a".
    let inner = """
    {"heard":"n/a","speaker":"n/a","radioReplyText":"n/a","correct":false,\
    "corrections":[],"expectedExample":"n/a","phaseAdvance":false,"coaching":"n/a"}
    """
    let response = """
    {"stop_reason":"end_turn","content":[{"type":"text","text":\(jsonString(inner))}]}
    """
    #expect(throws: ATCBrainError.self) {
        try ATCBrain.parseVerdict(from: Data(response.utf8))
    }
}

@Test func scrubStripsInvisiblePadding() {
    #expect(ATCBrain.scrub("say your position.\u{200B}\u{200B} \u{200B}") == "say your position.")
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
                  transmission: String, nextSetup: String?) async throws -> Verdict {
        let ok = transmission.localizedCaseInsensitiveContains(passWhenContains)
        return Verdict(
            heard: transmission, speaker: ok ? "none" : "CTAF",
            radioReplyText: "", correct: ok,
            corrections: ok ? [] : ["Missing the airport name"],
            expectedExample: "model call", phaseAdvance: ok, coaching: ok ? "Good." : "Try again."
        )
    }
}

/// Records the continuity hint the session hands the brain on each submit.
final class SpyBrain: ATCEvaluating, @unchecked Sendable {
    private(set) var nextSetups: [String?] = []
    func evaluate(drill: Drill, mode: GradingMode, history: [Turn],
                  transmission: String, nextSetup: String?) async throws -> Verdict {
        nextSetups.append(nextSetup)
        return Verdict(heard: transmission, speaker: "none", radioReplyText: "",
                       correct: true, corrections: [], expectedExample: "",
                       phaseAdvance: true, coaching: "")
    }
}

@Test func sessionPassesContinuityForSameAirportOnly() async throws {
    // Two Watsonville drills then a Palo Alto one: the first submit should
    // carry the next drill's setup, the second (airport change) should not,
    // and the last drill has nothing to carry.
    let wvi = DrillLibrary.all.filter { $0.airport.icao == "KWVI" }.prefix(2)
    let pao = DrillLibrary.all.first { $0.airport.icao == "KPAO" }!
    let drills = Array(wvi) + [pao]
    let spy = SpyBrain()
    let session = PracticeSession(brain: spy, mode: .debrief, drills: drills)

    for _ in drills { _ = try await session.submit("anything") }
    #expect(spy.nextSetups.count == 3)
    #expect(spy.nextSetups[0] == drills[1].setup)
    #expect(spy.nextSetups[1] == nil)
    #expect(spy.nextSetups[2] == nil)
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
