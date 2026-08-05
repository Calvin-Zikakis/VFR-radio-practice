import Foundation

/// Starter library of bite-sized drills. Later these chain into full flight
/// arcs (see `Arc`), but each stands alone so you can drill one call at a time.
public enum DrillLibrary {

    // Reusable fixtures.
    static let skyhawk = Aircraft(
        callsign: "N172SP",
        phoneticCallsign: "Skyhawk one seven two sierra papa",
        type: "Cessna 172"
    )

    static let rv12 = Aircraft(
        callsign: "N737JA",
        phoneticCallsign: "RV seven three seven juliet alpha",
        type: "Van's RV-12 (Light Sport)"
    )

    // A small fleet so sessions can vary the airplane. The banner on screen
    // always tells the pilot which one they're flying.
    static let cirrus = Aircraft(
        callsign: "N523CD",
        phoneticCallsign: "Cirrus five two three charlie delta",
        type: "Cirrus SR22"
    )

    static let cherokee = Aircraft(
        callsign: "N4820L",
        phoneticCallsign: "Cherokee four eight two zero lima",
        type: "Piper Cherokee"
    )

    static let bonanza = Aircraft(
        callsign: "N9017Q",
        phoneticCallsign: "Bonanza niner zero one seven quebec",
        type: "Beechcraft Bonanza"
    )

    /// The user's own airplane — the default when not randomizing.
    public static let defaultAircraft = rv12

    /// Airplanes a session may pick from when "shuffle" is on. RV-12 first.
    public static let fleet: [Aircraft] = [rv12, skyhawk, cirrus, cherokee, bonanza]

    static let paloAlto = Airport(
        icao: "KPAO", name: "Palo Alto",
        ctafOrTower: "one one eight point six",
        elevationFt: 7, runwaysInUse: ["31"], isTowered: true
    )

    static let watsonville = Airport(
        icao: "KWVI", name: "Watsonville",
        ctafOrTower: "one two two point eight",
        elevationFt: 163, runwaysInUse: ["20"]
    )

    static let monterey = Airport(
        icao: "KMRY", name: "Monterey",
        ctafOrTower: "one one eight point four",
        elevationFt: 257, runwaysInUse: ["28R"], isTowered: true
    )

    /// San Francisco Class B, used as context for Bravo-clearance drills. The
    /// "frequency" here is the relevant NorCal Approach sector.
    static let sfoBravo = Airport(
        icao: "KSFO", name: "San Francisco",
        ctafOrTower: "one three five point six five",
        elevationFt: 13, runwaysInUse: ["28R"], isTowered: true
    )

    // Frequencies/elevations/runways verified against AirNav (FAA data),
    // 2026-07. They don't affect phraseology grading, only what's spoken —
    // but real numbers keep the muscle memory honest.
    static let southCounty = Airport(
        icao: "E16", name: "South County",   // San Martin
        ctafOrTower: "one two two point seven",
        elevationFt: 284, runwaysInUse: ["32"]
    )

    static let hollister = Airport(
        icao: "KCVH", name: "Hollister",
        ctafOrTower: "one two three point zero",
        elevationFt: 230, runwaysInUse: ["31"]
    )

    static let salinas = Airport(
        icao: "KSNS", name: "Salinas",       // towered (part-time tower)
        ctafOrTower: "one one niner point five two five",
        elevationFt: 84, runwaysInUse: ["31"], isTowered: true
    )

    static let livermore = Airport(
        icao: "KLVK", name: "Livermore",
        ctafOrTower: "one one eight point one",
        elevationFt: 400, runwaysInUse: ["25R"], isTowered: true
    )

    static let halfMoonBay = Airport(
        icao: "KHAF", name: "Half Moon Bay",
        ctafOrTower: "one two two point eight",
        elevationFt: 66, runwaysInUse: ["30"]
    )

    static let reidHillview = Airport(
        icao: "KRHV", name: "Reid-Hillview",
        ctafOrTower: "one one niner point eight",
        elevationFt: 135, runwaysInUse: ["31R"], isTowered: true   // parallel 31L/31R
    )

    static let sanCarlos = Airport(
        icao: "KSQL", name: "San Carlos",
        ctafOrTower: "one one niner point zero",
        elevationFt: 6, runwaysInUse: ["30"], isTowered: true
    )

    static let marina = Airport(
        icao: "KOAR", name: "Marina",
        ctafOrTower: "one two two point seven",
        elevationFt: 137, runwaysInUse: ["29"]
    )

    /// Buchanan Field: parallel 32L/32R crossed by 1R/19L and 1L/19R — the
    /// Bay Area's best geometry for complex taxi-route work.
    static let concord = Airport(
        icao: "KCCR", name: "Concord",
        ctafOrTower: "one one niner point seven",
        elevationFt: 26, runwaysInUse: ["32L", "32R"], isTowered: true
    )

    /// Airports you can route a trip through (landable stops; excludes the SFO
    /// Bravo context, which is used only for clearance drills).
    public static let routableAirports: [Airport] =
        [watsonville, southCounty, hollister, halfMoonBay, marina,
         salinas, paloAlto, livermore, monterey, reidHillview, sanCarlos,
         concord]

    /// A sensible starter route: untowered → towered → back to untowered.
    public static let defaultTripStops: [Airport] = [watsonville, paloAlto, watsonville]

    public static let all: [Drill] = untowered + towered + flightFollowing

    public static func drills(for scenario: ScenarioType) -> [Drill] {
        all.filter { $0.scenario == scenario }
    }

    /// Drills for a scenario, all flown in the given airplane. Overrides each
    /// drill's default aircraft so an entire session uses one consistent plane
    /// (you fly one airplane per flight), and the on-screen banner can name it.
    public static func drills(for scenario: ScenarioType, aircraft: Aircraft) -> [Drill] {
        drills(for: scenario).map { retarget($0, to: aircraft) }
    }

    /// Re-aim a drill at a different airplane: swaps the `aircraft` field AND
    /// rewrites any quoted callsigns in the briefing/situation text (many
    /// drills quote ATC addressing the pilot — "Tower says: RV seven three
    /// seven juliet alpha, …" — which must match the plane actually flown).
    static func retarget(_ drill: Drill, to plane: Aircraft) -> Drill {
        var d = drill
        let old = drill.aircraft
        d.aircraft = plane
        guard old.callsign != plane.callsign else { return d }

        var subs: [(String, String)] = [
            (old.phoneticCallsign, plane.phoneticCallsign),                 // "RV seven three seven juliet alpha"
            (bareCallsign(old), bareCallsign(plane)),                       // "seven three seven juliet alpha"
            (shortCallsign(old), shortCallsign(plane)),                     // "seven juliet alpha"
            (old.callsign, plane.callsign),                                 // "N737JA"
        ]
        // Tail number without the leading N ("737JA") appears in a few texts.
        if old.callsign.hasPrefix("N") && plane.callsign.hasPrefix("N") {
            subs.append((String(old.callsign.dropFirst()), String(plane.callsign.dropFirst())))
        }
        for (from, to) in subs where from != to && !from.isEmpty {
            d.setup = d.setup.replacingOccurrences(of: from, with: to)
            d.situation = d.situation.replacingOccurrences(of: from, with: to)
            d.instruction = d.instruction?.replacingOccurrences(of: from, with: to)
            d.instructionVariants = d.instructionVariants?.map {
                $0.replacingOccurrences(of: from, with: to)
            }
            d.amendment = d.amendment?.replacingOccurrences(of: from, with: to)
            d.amendmentVariants = d.amendmentVariants?.map {
                $0.replacingOccurrences(of: from, with: to)
            }
        }
        return d
    }

    private static let digitWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five",
        "six", "seven", "eight", "niner", "nine"]

    /// The phonetic without its type prefix ("RV …" → "…"). If the phonetic
    /// starts straight into digits (no prefix), it's returned unchanged.
    static func bareCallsign(_ a: Aircraft) -> String {
        let words = a.phoneticCallsign.split(separator: " ").map(String.init)
        guard let first = words.first, !digitWords.contains(first.lowercased()) else {
            return a.phoneticCallsign
        }
        return words.dropFirst().joined(separator: " ")
    }

    /// The abbreviated form controllers use after first contact — the last
    /// three phonetic elements ("seven juliet alpha").
    static func shortCallsign(_ a: Aircraft) -> String {
        let words = a.phoneticCallsign.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return a.phoneticCallsign }
        return words.suffix(3).joined(separator: " ")
    }

    /// Classify a library drill into a `CallType`. Prefers the drill's explicit
    /// tag; falls back to deriving one from its stable id (legacy drills).
    public static func callType(for drill: Drill) -> CallType {
        if let tagged = drill.callType { return tagged }
        let id = drill.id
        if id.contains("readback") { return .readback }
        if id.contains("bravo") { return .bravo }
        if id.contains("traffic") { return .advisory }
        if id.hasPrefix("ff-") { return .flightFollowing } // initial/request/from-towered/altitude/terminate
        if id.contains("taxi") || id.contains("clearance") { return .taxi }
        if id.hasSuffix("clear") || id.contains("afterlanding") { return .afterLanding }
        if id.contains("departure") { return .departure }
        if id.contains("downwind") || id.contains("base")
            || id.contains("teardrop") || id.contains("touchgo") { return .pattern }
        if id.contains("inbound") || id.contains("arrival") { return .arrival }
        // Fallback by scenario (shouldn't be reached for the current library).
        return drill.scenario == .flightFollowing ? .flightFollowing : .arrival
    }

    /// A shuffled-friendly set of drills matching any of the given call types,
    /// all flown in `aircraft`. Used by the "mix" session mode.
    public static func drills(matching types: Set<CallType>, aircraft: Aircraft) -> [Drill] {
        all.filter { types.contains(callType(for: $0)) }
           .map { retarget($0, to: aircraft) }
    }

    // MARK: - Untowered (CTAF self-announce)

    public static let untowered: [Drill] = [
        Drill(
            id: "u-taxi",
            scenario: .untowered,
            title: "Taxi self-announce",
            setup: "You're at Watsonville, about to taxi from the ramp for departure on runway two zero. Make your taxi call.",
            situation: "Uncontrolled field. Pilot is taxiing from the transient ramp toward runway 20. Expect a CTAF self-announce: airport, aircraft, and where they're taxiing (to runway 20), airport again. A taxi call does NOT require departure intentions or direction of flight — never ask for those here; they belong in the departure call.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "u-departure",
            scenario: .untowered,
            title: "Departing the pattern",
            setup: "You're holding short of runway two zero at Watsonville, ready to depart to the north. Make your departure call.",
            situation: "Uncontrolled field. Pilot is departing runway 20, will depart the pattern to the north. Expect a self-announce with airport, aircraft, departing runway 20, direction of departure, airport.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "u-inbound",
            scenario: .untowered,
            title: "Inbound for landing",
            setup: "You're ten miles south of Watsonville, inbound to land. Make your inbound call.",
            situation: "Uncontrolled field. Pilot is 10 miles south inbound. Expect airport, aircraft, position and altitude, intentions (inbound for landing / to enter the pattern), request for airport advisories, airport.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "u-downwind",
            scenario: .untowered,
            title: "Midfield downwind",
            setup: "You're entering a left downwind for runway two zero at Watsonville. Make your downwind call.",
            situation: "Uncontrolled field. Pilot is on left downwind for runway 20. Expect airport, aircraft, position in the pattern (left downwind 20), intentions (touch and go / full stop), airport.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "u-base-final",
            scenario: .untowered,
            title: "Base and final",
            setup: "You're turning left base for runway two zero at Watsonville, full stop. Make your base call.",
            situation: "Uncontrolled field. Pilot is turning base to final for runway 20. Expect airport, aircraft, position (left base or final 20), intentions, airport. A separate short 'final' call is also acceptable.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "u-clear",
            scenario: .untowered,
            title: "Clear of the runway",
            setup: "You've just landed and taxied clear of runway two zero at Watsonville. Make your call.",
            situation: "Uncontrolled field. Pilot has exited the runway. Expect a brief self-announce that they are clear of runway 20, airport name. Keep it short.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "u-e16-departure",
            scenario: .untowered,
            title: "Departure — South County (E16)",
            setup: "You're holding short of runway three two at South County, San Martin, ready to depart to the south. Make your departure call.",
            situation: "Uncontrolled field (South County / San Martin, E16). Pilot is departing runway 32 to the south. Expect airport, aircraft, departing runway 32, direction, airport.",
            aircraft: rv12, airport: southCounty
        ),
        Drill(
            id: "u-e16-inbound",
            scenario: .untowered,
            title: "Inbound — South County (E16)",
            setup: "You're 10 miles north of South County, San Martin, inbound to land. Make your inbound call.",
            situation: "Uncontrolled field (South County / San Martin, E16). Pilot is 10 miles north inbound. Expect airport, aircraft, position and altitude, intentions, airport.",
            aircraft: rv12, airport: southCounty
        ),
        Drill(
            id: "u-cvh-inbound",
            scenario: .untowered,
            title: "Inbound — Hollister",
            setup: "You're 10 miles west of Hollister, inbound to land. Make your inbound call.",
            situation: "Uncontrolled field (Hollister, KCVH). Pilot is 10 miles west inbound. Expect airport, aircraft, position and altitude, intentions, and a request for airport advisories, airport.",
            aircraft: rv12, airport: hollister
        ),
        Drill(
            id: "u-cvh-downwind",
            scenario: .untowered,
            title: "Downwind — Hollister",
            setup: "You're entering a left downwind for runway three one at Hollister. Make your downwind call.",
            situation: "Uncontrolled field (Hollister, KCVH). Pilot is on left downwind for runway 31. Expect airport, aircraft, position in the pattern, intentions, airport.",
            aircraft: rv12, airport: hollister
        ),
        Drill(
            id: "u-cvh-teardrop",
            scenario: .untowered,
            title: "Teardrop / overhead entry — Hollister",
            setup: "You're arriving at Hollister and will cross overhead midfield to enter the left downwind for runway three one using a teardrop entry. Make the call announcing your crossing and intentions.",
            situation: "Uncontrolled field (Hollister, KCVH). The pilot is doing an overhead / teardrop entry: cross midfield above pattern altitude, then teardrop out and back to enter the 45 for the left downwind, runway 31. Grade the self-announce: airport, aircraft, position (crossing midfield / overhead), the intention to teardrop and enter the left downwind for 31, and airport. It's good practice to state altitude and that they'll descend on the upwind side. There is no controller reply, but other traffic may respond.",
            aircraft: rv12, airport: hollister
        ),
        Drill(
            id: "u-sns-tower-closed",
            scenario: .untowered,
            title: "Salinas after the tower closes",
            setup: "It's late evening and Salinas Tower is closed — the field is now non-towered and the tower frequency works as the CTAF. You're 10 miles south, inbound to land. Make your call.",
            situation: "Salinas (KSNS) has a part-time tower and it is CLOSED — the field currently operates as an uncontrolled airport with the tower frequency serving as CTAF. This drill tests recognizing the switch: the pilot must SELF-ANNOUNCE ('Salinas traffic, …, Salinas'), NOT call 'Salinas Tower'. If they address the tower, mark it wrong and explain the tower is closed. Grade like any CTAF call: airport first, aircraft, position and altitude, intentions, airport again at the end. No controller reply; another aircraft in the pattern may respond.",
            aircraft: rv12, airport: salinas, callType: .arrival
        ),
        Drill(
            id: "u-negotiate-traffic",
            scenario: .untowered,
            title: "Negotiate with conflicting traffic",
            setup: "You're on a 45 for the left downwind, runway two zero at Watsonville. A Cherokee announces they're also entering the downwind from a crosswind entry — you'll arrive at the same point at about the same time. Work it out over the radio.",
            situation: "Uncontrolled field (Watsonville). A Cherokee (Cherokee four eight two zero lima) and the pilot are converging on the left downwind for runway 20. Play the Cherokee. The right move is direct, plain-language coordination addressed to the other aircraft: identify yourself, state position, and propose a sequence (e.g. 'Cherokee two zero lima, RV seven three seven juliet alpha is on the forty-five for left downwind two zero, I have you in sight, I'll follow you' or offering to extend). Grade: did they address the Cherokee, state their own position, and establish an unambiguous sequence? Plain language is CORRECT here — this is cooperative traffic coordination, not an ATC call. As the Cherokee, agree to the plan ('sounds good, Cherokee two zero lima is midfield downwind, we'll be number one').",
            aircraft: rv12, airport: watsonville, callType: .pattern
        ),
        Drill(
            id: "u-ifr-straightin-traffic",
            scenario: .untowered,
            title: "IFR traffic on a straight-in",
            setup: "You're on left downwind for runway two zero at Watsonville. A Pilatus announces: Watsonville traffic, Pilatus on the RNAV two zero, five mile final, straight-in runway two zero, Watsonville. Respond so you can sequence safely.",
            situation: "Uncontrolled field (Watsonville). An IFR Pilatus is on a 5-mile straight-in final for runway 20 off the RNAV approach; the pilot is on left downwind for the same runway. Play the Pilatus if a reply is warranted. Grade the pilot's response: announce their position in the pattern, state whether they have the traffic in sight, and state a clear intention that resolves the conflict (e.g. extend downwind and follow the Pilatus, or state they're turning base ahead with adequate spacing — following is the safer choice to coach). The call should be addressed as a CTAF self-announce with the airport name bookend. Coach: straight-in IFR traffic doesn't own the pattern, but courtesy and predictability win.",
            aircraft: rv12, airport: watsonville, callType: .pattern
        ),
        Drill(
            id: "u-oar-inbound",
            scenario: .untowered,
            title: "Marina — under the Class Charlie shelf",
            setup: "You're 10 miles north of Marina at one thousand five hundred, inbound to land. Marina is untowered, but it sits under the Monterey Class Charlie shelf — you're staying below it, so it's a normal CTAF arrival. Make your inbound call.",
            situation: "Uncontrolled field (Marina, KOAR), which lies beneath the Monterey Class C shelf. The pilot is inbound at 1,500, below the shelf, so no NorCal contact is required — this is a standard CTAF self-announce: airport, aircraft, position and altitude, intentions, airport again (bookend required). If the pilot announces an altitude that would put them IN the shelf, note in coaching that above the shelf floor they'd need two-way contact with NorCal first. No controller reply; pattern traffic may respond.",
            aircraft: rv12, airport: marina, callType: .arrival
        ),
        Drill(
            id: "u-straightin-etiquette",
            scenario: .untowered,
            title: "Straight-in arrival etiquette",
            setup: "You're 10 miles west of Hollister, aligned with runway three one, and you'd like to fly a straight-in. Make the call — and make it early and unambiguous.",
            situation: "Uncontrolled field (Hollister, KCVH). The pilot wants to fly a straight-in to runway 31. Straight-ins at non-towered fields are legal but demand extra care: announce EARLY and repeatedly, use 'straight-in runway three one' explicitly with distance (e.g. 'ten mile straight-in final'), and yield to traffic established in the pattern. Grade the self-announce: airport, aircraft, position with distance, the words 'straight-in' with the runway, intentions, airport again. In coaching, note they should re-announce at 5 miles, 3 miles, and short final, and break off if pattern traffic conflicts.",
            aircraft: rv12, airport: hollister, callType: .arrival
        )
    ]

    // MARK: - Towered (ATC: Ground / Tower)

    public static let towered: [Drill] = [
        Drill(
            id: "t-taxi",
            scenario: .towered,
            title: "Request taxi (Ground)",
            setup: "You're at Palo Alto ground with information Tango, parked at the transient ramp, ready to taxi for a VFR departure to the south. Call ground for taxi.",
            situation: "Towered field, you are Palo Alto Ground. Runway 31 in use; taxiways here are alpha (parallel) and bravo/charlie (ramp exits). Grade the request — who they're calling, aircraft, position, the ATIS letter (current is information Tango; a different letter gets 'verify you have information Tango'), request, direction of flight.",
            aircraft: skyhawk, airport: paloAlto, followUpReadback: true,
            instructionVariants: [
                "Skyhawk one seven two sierra papa, Palo Alto Ground, runway three one, taxi via bravo, alpha.",
                "Skyhawk one seven two sierra papa, Palo Alto Ground, runway three one, taxi via charlie, alpha.",
                "Skyhawk one seven two sierra papa, Palo Alto Ground, runway three one, taxi via bravo, alpha, give way to a Citabria taxiing right to left off the ramp.",
            ]
        ),
        Drill(
            id: "t-tower-departure",
            scenario: .towered,
            title: "Ready for departure (Tower)",
            setup: "You're holding short of runway three one at Palo Alto, ready for a downwind departure. Call the tower.",
            situation: "Towered field, you are Palo Alto Tower. Pilot is holding short runway 31, requesting departure. Expect who they're calling, aircraft, position (holding short 31), request/intentions.",
            aircraft: skyhawk, airport: paloAlto, followUpReadback: true,
            instructionVariants: [
                "Skyhawk one seven two sierra papa, runway three one, cleared for takeoff, left downwind departure approved.",
                "Skyhawk one seven two sierra papa, runway three one, line up and wait, traffic crossing downfield.",
                "Skyhawk one seven two sierra papa, runway three one, cleared for takeoff, left downwind departure approved, traffic is a Cirrus on a three mile final.",
            ]
        ),
        Drill(
            id: "t-inbound",
            scenario: .towered,
            title: "Inbound to a towered field (Tower)",
            setup: "You're ten miles west of Palo Alto inbound to land with information Bravo. Call the tower.",
            situation: "Towered field, you are Palo Alto Tower. Pilot inbound 10 west with ATIS Bravo. Expect who they're calling, aircraft, position and altitude, ATIS letter, request (landing).",
            aircraft: skyhawk, airport: paloAlto, followUpReadback: true,
            instructionVariants: [
                "Skyhawk one seven two sierra papa, Palo Alto Tower, enter left downwind runway three one, report midfield.",
                "Skyhawk one seven two sierra papa, Palo Alto Tower, enter left base runway three one, report two mile left base.",
                "Skyhawk one seven two sierra papa, Palo Alto Tower, enter left downwind runway three one, report midfield, traffic is a Bonanza departing ahead of your arrival.",
            ]
        ),
        Drill(
            id: "t-readback",
            scenario: .towered,
            title: "Read back a clearance",
            setup: "Palo Alto Tower tells you: cleared to land runway three one. Read it back.",
            situation: "Towered field. The tower has just issued 'cleared to land runway 31'. Grade the pilot's readback: it must include the clearance and the callsign. No further ATC reply is needed unless the readback is wrong.",
            aircraft: skyhawk, airport: paloAlto
        ),
        Drill(
            id: "t-arrival-atis",
            scenario: .towered,
            title: "Untowered → towered arrival (with ATIS)",
            setup: "You flew up from Watsonville to Monterey. You're 10 miles south of Monterey at three thousand five hundred, inbound to land, and you have information Zulu. Call Monterey Tower.",
            situation: "Towered field, you are Monterey Tower. Pilot is arriving VFR from an untowered field, 10 south at 3,500 with ATIS information Zulu. Expect: who they're calling, aircraft, position and altitude, the ATIS code ('with information Zulu'), and request. This tests remembering to include the current ATIS letter.",
            aircraft: rv12, airport: monterey, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Monterey Tower, enter left downwind runway two eight right, report midfield.",
                "RV seven three seven juliet alpha, Monterey Tower, enter left base runway two eight right, report two mile left base.",
                "RV seven three seven juliet alpha, Monterey Tower, enter left downwind runway two eight right, report midfield, traffic is a Skyhawk ahead on the downwind.",
            ]
        ),
        Drill(
            id: "t-clearance-vfr",
            scenario: .towered,
            title: "VFR departure request (Ground)",
            setup: "You're parked on the transient ramp at Monterey with information Zulu, ready to taxi for a VFR departure to the south. Call ground, then read back your taxi instructions.",
            situation: "Towered field, you are Monterey Ground (Class C). Grade the request — who they're calling, aircraft, position on the field (transient ramp), ATIS code, and the request with direction of flight. A requested altitude is OPTIONAL — fine if offered, but never require it or ask for it when direction of flight is given.",
            aircraft: rv12, airport: monterey, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Monterey Ground, runway two eight right, taxi via alpha, maintain VFR at or below one thousand five hundred, departure frequency one two seven point one five, squawk four five two one.",
                "RV seven three seven juliet alpha, Monterey Ground, runway two eight right, taxi via alpha, charlie, squawk four five two one, departure frequency one two seven point one five.",
            ]
        ),
        Drill(
            id: "t-pattern-touchgo",
            scenario: .towered,
            title: "Pattern work (report downwind)",
            setup: "You're doing closed traffic at Palo Alto. The tower asked you to report midfield left downwind for runway three one. Make that report.",
            situation: "Towered field, you are Palo Alto Tower. Pilot is doing pattern work and was told to report midfield downwind. Expect callsign plus position report ('midfield left downwind three one'). Reply with a landing clearance or 'continue' / sequence with traffic.",
            aircraft: skyhawk, airport: paloAlto
        ),
        Drill(
            id: "t-afterlanding",
            scenario: .towered,
            title: "After landing (taxi to parking)",
            setup: "You've landed at Palo Alto and are clear of runway three one. The tower said contact ground. Call Palo Alto Ground to taxi to the transient ramp, then read back the route you're given.",
            situation: "Towered field, you are Palo Alto Ground. Pilot has just cleared the runway. Grade the call — who they're calling, aircraft, position (clear of 31 / on the taxiway), request to taxi to transient parking.",
            aircraft: skyhawk, airport: paloAlto, followUpReadback: true,
            instructionVariants: [
                "Skyhawk one seven two sierra papa, Palo Alto Ground, taxi to the transient ramp via alpha, charlie.",
                "Skyhawk one seven two sierra papa, Palo Alto Ground, taxi to the transient ramp via alpha, bravo.",
                "Skyhawk one seven two sierra papa, Palo Alto Ground, taxi to the transient ramp via alpha, charlie, give way to the fuel truck at the charlie intersection.",
            ]
        ),
        Drill(
            id: "t-sns-taxi",
            scenario: .towered,
            title: "Request taxi — Salinas Ground",
            setup: "You're at Salinas with information Foxtrot, parked at the ramp, ready to taxi for a VFR departure to the north. Call Salinas Ground — then read back the taxi instructions you get; runway two six crosses your route.",
            situation: "Towered field, you are Salinas Ground (KSNS, part-time tower — it is open). Runway 31 in use; runway 26 crosses the taxi route; taxiways alpha and bravo. Grade the request — who they're calling, aircraft, position, the ATIS letter (current is information Foxtrot; a different letter gets 'verify you have information Foxtrot'), request, direction of flight.",
            aircraft: rv12, airport: salinas, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Salinas Ground, runway three one, taxi via alpha, cross runway two six.",
                "RV seven three seven juliet alpha, Salinas Ground, runway three one, taxi via alpha, hold short of runway two six.",
                "RV seven three seven juliet alpha, Salinas Ground, runway three one, taxi via bravo, alpha, cross runway two six.",
            ]
        ),
        Drill(
            id: "t-sns-inbound",
            scenario: .towered,
            title: "Inbound — Salinas Tower",
            setup: "You're 10 miles south of Salinas at two thousand five hundred, inbound to land with information Kilo. Call Salinas Tower.",
            situation: "Towered field, you are Salinas Tower (KSNS). Pilot is 10 south at 2,500 inbound to land. Expect who they're calling, aircraft, position and altitude, the ATIS letter (current is information Kilo), request.",
            aircraft: rv12, airport: salinas, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Salinas Tower, enter left downwind runway three one, report midfield.",
                "RV seven three seven juliet alpha, Salinas Tower, make straight-in runway three one, report three mile final.",
                "RV seven three seven juliet alpha, Salinas Tower, enter right base runway three one, report two mile right base.",
            ]
        ),
        Drill(
            id: "t-lvk-taxi",
            scenario: .towered,
            title: "Request taxi — Livermore Ground",
            setup: "You're parked at the Livermore ramp with information Delta, ready for a VFR departure to the east. Call Livermore Ground.",
            situation: "Towered field, you are Livermore Ground (KLVK, parallel runways 25L/25R). Grade the REQUEST — who they're calling, aircraft, position (the ramp), the ATIS letter (current is information Delta; a different letter gets 'verify you have information Delta'), the direction of flight, and the request to taxi for departure. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request.",
            aircraft: rv12, airport: livermore, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Livermore Ground, runway two five right, taxi via alpha, cross runway two five left.",
                "RV seven three seven juliet alpha, Livermore Ground, runway two five right, taxi via alpha, hold short of runway two five left.",
                "RV seven three seven juliet alpha, Livermore Ground, runway two five left, taxi via alpha, bravo.",
            ]
        ),
        Drill(
            id: "t-rhv-taxi",
            scenario: .towered,
            title: "Request taxi — Reid-Hillview Ground",
            setup: "You're parked at the Reid-Hillview ramp with information Whiskey, ready for a VFR departure to the south. Call Reid-Hillview Ground.",
            situation: "Towered field, you are Reid-Hillview Ground (KRHV, parallel runways 31L/31R). Grade the REQUEST — who they're calling, aircraft, position (the ramp), the ATIS letter (current is information Whiskey; a different letter gets 'verify you have information Whiskey'), the direction of flight, and the request to taxi for departure. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request.",
            aircraft: rv12, airport: reidHillview, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Reid-Hillview Ground, runway three one right, taxi via alpha, cross runway three one left.",
                "RV seven three seven juliet alpha, Reid-Hillview Ground, runway three one right, taxi via alpha, hold short of runway three one left.",
                "RV seven three seven juliet alpha, Reid-Hillview Ground, runway three one left, taxi via alpha.",
            ]
        ),
        Drill(
            id: "t-sql-taxi",
            scenario: .towered,
            title: "Request taxi — San Carlos Ground",
            setup: "You're parked at the San Carlos ramp with information Romeo, ready for a VFR departure to the north — it's a busy little Delta tucked under the San Francisco Bravo shelf. Call San Carlos Ground.",
            situation: "Towered field, you are San Carlos Ground (KSQL, single runway 12/30, and the pattern is busy). Grade the REQUEST — who they're calling, aircraft, position (the ramp), the ATIS letter (current is information Romeo; a different letter gets 'verify you have information Romeo'), the direction of flight, and the request to taxi for departure. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request. Keep your transmissions brisk — it's a busy frequency.",
            aircraft: rv12, airport: sanCarlos, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, San Carlos Ground, runway three zero, taxi via alpha.",
                "RV seven three seven juliet alpha, San Carlos Ground, runway three zero, taxi via alpha, give way to a Cherokee taxiing opposite.",
            ]
        ),
        Drill(
            id: "t-luaw",
            scenario: .towered,
            title: "Line up and wait",
            setup: "You're holding short of runway three one at Palo Alto. Tower says: RV seven three seven juliet alpha, runway three one, line up and wait. Read it back.",
            situation: "Towered field, you are Palo Alto Tower. You just issued 'runway three one, line up and wait'. This readback is REQUIRED and must include 'line up and wait' (not 'position and hold', not 'cleared for takeoff') plus the runway and callsign. If the pilot says anything implying they think they're cleared for takeoff, mark it wrong and correct it firmly — moving without takeoff clearance is a runway incursion. After a correct readback, a short beat later clear them for takeoff.",
            aircraft: rv12, airport: paloAlto, callType: .readback
        ),
        Drill(
            id: "t-holdshort-cross",
            scenario: .towered,
            title: "Hold short of a crossing runway",
            setup: "You're taxiing at Monterey. Ground says: RV seven three seven juliet alpha, taxi to runway two eight right via Alpha, hold short of runway one zero left. Read it back.",
            situation: "Towered field, you are Monterey Ground. You issued a taxi clearance with a hold-short: 'runway two eight right via Alpha, hold short of runway one zero left'. Hold-short instructions require a VERBATIM readback including the words 'hold short of runway one zero left' and the callsign — 'roger' or 'wilco' is NOT acceptable and you must ask for a full readback if you don't get one. This is the classic runway-incursion trap; grade it strictly at every difficulty.",
            aircraft: rv12, airport: monterey, callType: .readback
        ),
        Drill(
            id: "t-goaround",
            scenario: .towered,
            title: "Go around",
            setup: "You're on short final for runway three one at Palo Alto and tower calls: RV seven three seven juliet alpha, go around, traffic on the runway. Respond while you fly the go-around.",
            situation: "Towered field, you are Palo Alto Tower. You just sent the pilot around for traffic on the runway. Expect a brief acknowledgment — 'going around' plus callsign. Brevity is correct here; they're busy flying. After they acknowledge, give a pattern instruction like 'fly runway heading, I'll call your crosswind'.",
            aircraft: rv12, airport: paloAlto, callType: .pattern
        ),
        Drill(
            id: "t-extend-downwind",
            scenario: .towered,
            title: "Extend downwind / spacing",
            setup: "You're on left downwind for runway three one at Palo Alto. Tower says: RV seven juliet alpha, extend your downwind, I'll call your base. Respond.",
            situation: "Towered field, you are Palo Alto Tower sequencing traffic. You told the pilot to extend downwind and that you'll call the base turn. Expect a concise acknowledgment: 'extending downwind' (or 'wilco') plus callsign. After a correct response, call their base: 'seven juliet alpha, turn base now'.",
            aircraft: rv12, airport: paloAlto, callType: .pattern
        ),
        Drill(
            id: "t-wake-turbulence",
            scenario: .towered,
            title: "Wake turbulence on landing",
            setup: "You're on final at Monterey behind an airliner. Tower says: RV seven three seven juliet alpha, runway two eight right, cleared to land, caution wake turbulence, departing Boeing seven three seven. Read it back.",
            situation: "Towered field, you are Monterey Tower. You issued a landing clearance with a wake turbulence caution for a departing Boeing 737. Expect a readback of the landing clearance with runway and callsign; acknowledging the wake caution is good form (e.g. 'cleared to land two eight right, caution the wake, seven juliet alpha'). Bonus points in coaching if they state a plan (land beyond the jet's rotation point), but don't fail the call for omitting it.",
            aircraft: rv12, airport: monterey, callType: .arrival
        ),
        Drill(
            id: "t-complex-taxi",
            scenario: .towered,
            title: "Complex taxi route readback",
            setup: "You're parked at the Monterey ramp with information Zulu, ready to taxi for a VFR departure to the south. Call Monterey Ground — the route back to the runway is a long one, so be ready to read it all back.",
            situation: "Towered field, you are Monterey Ground. Grade the request — who they're calling, aircraft, position (the ramp), the ATIS letter (current is information Zulu; a different letter gets 'verify you have information Zulu'), request, and direction of flight.",
            aircraft: rv12, airport: monterey, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Monterey Ground, runway two eight right, taxi via Alpha, Charlie, cross runway one zero left, hold short of runway two eight left.",
                "RV seven three seven juliet alpha, Monterey Ground, runway two eight right, taxi via Alpha, cross runway one zero left, cross runway one zero right.",
                "RV seven three seven juliet alpha, Monterey Ground, runway two eight left, taxi via Charlie, Alpha, hold short of runway two eight right.",
            ]
        ),
        Drill(
            id: "t-ccr-parallel-taxi",
            scenario: .towered,
            title: "Taxi back for the parallel — cross the one niner",
            setup: "You've landed on runway three two left at Concord, rolled to the end, and exited at hotel. You want another lap — call Ground to taxi back for departure, staying in the pattern.",
            situation: "Towered field, you are Concord Ground (Buchanan Field: parallel 32L/32R crossed by 19L/19R; the route back crosses 19L at charted hot spot two). Grade the REQUEST — who they're calling, aircraft, position (clear of three two left at hotel), and the request to taxi back for departure (closed traffic / another departure). The pilot has been in the pattern, so no ATIS code is needed. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request. (You'll assign three two left across one niner left; the readback is graded next.)",
            aircraft: rv12, airport: concord, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via juliet, papa, cross runway one niner left.",
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via juliet, hold short of runway one niner left.",
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via juliet, papa, cross runway one niner left, give way to a Cessna taxiing on papa.",
            ]
        ),
        Drill(
            id: "t-ccr-runway-switch",
            scenario: .towered,
            title: "Landed the right, departing the left",
            setup: "You landed on runway three two right at Concord and exited onto alpha. You want another departure — call Ground to taxi back, staying in the pattern.",
            situation: "Towered field, you are Concord Ground. The pilot just landed 32R; you'll send them back out on the parallel 32L — and muscle memory will want them to read back 'three two right'. Grade the REQUEST — who they're calling, aircraft, position (clear of three two right at alpha), and the request to taxi back for departure. The pilot has been in the pattern, so no ATIS code is needed. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request. (You'll assign three two left; the wrong-parallel trap is graded on their readback, next.)",
            aircraft: rv12, airport: concord, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via alpha, juliet, papa, cross runway one niner left.",
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via alpha, juliet, hold short of runway one niner left.",
            ]
        ),
        Drill(
            id: "t-ccr-holdshort-request",
            scenario: .towered,
            title: "Hold short of the crossing runway — then ask",
            setup: "You call Concord Ground to taxi for departure on three two left, and they come back with: RV seven three seven juliet alpha, runway three two left, taxi via juliet, hold short of runway one niner left. Read it back. Then, when you've taxied up juliet and are holding short of one niner left — hot spot two, right by the tower — with nothing further said to you, make your next call.",
            situation: "Towered field, you are Concord Ground. Step 1: you issued 'runway three two left, taxi via juliet, hold short of runway one niner left'. Grade the readback: the hold short VERBATIM with its runway, the assigned runway three two left, and the callsign — strict at every difficulty. Step 2: the pilot is now holding short of one niner left and has NOT been cleared to cross — crossing without explicit clearance is a runway incursion. The right call: 'Concord Ground, RV seven juliet alpha, holding short runway one niner left' (explicitly requesting crossing is fine too). Reply: 'RV seven juliet alpha, cross runway one niner left, continue via papa to runway three two left', then grade the crossing readback ('cross runway one niner left' plus callsign). Set phaseAdvance true only after the crossing clearance has been read back.",
            aircraft: rv12, airport: concord, callType: .taxi
        ),
        Drill(
            id: "t-ccr-taxiback",
            scenario: .towered,
            title: "Taxi in from three two left",
            setup: "You've landed on runway three two left at Concord and exited at hotel. Call ground for taxi to transient parking on the south side, then read back the instructions before you move.",
            situation: "Towered field, you are Concord Ground (transient parking is on the south side; the route from hotel goes down juliet and crosses runway 19L at charted hot spot two). Grade the request — Ground, aircraft, position (clear of three two left at hotel), request taxi to transient parking.",
            aircraft: rv12, airport: concord, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Concord Ground, transient parking, taxi via juliet, cross runway one niner left.",
                "RV seven three seven juliet alpha, Concord Ground, transient parking, taxi via juliet, hold short of runway one niner left.",
            ]
        ),
        Drill(
            id: "t-ccr-runway-change",
            scenario: .towered,
            title: "Runway change mid-taxi",
            setup: "You've landed on runway three two left at Concord and exited at hotel. You want another lap — call Ground to taxi back for departure, staying in the pattern.",
            situation: "Towered field, you are Concord Ground (Buchanan Field: parallel 32L/32R crossed by 19L/19R). Grade the REQUEST — who they're calling, aircraft, position (clear of three two left at hotel), and the request to taxi back for departure. The pilot has been in the pattern, so no ATIS code is needed. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request. (You'll clear them to 32L across one niner left; after they read it back, you AMEND to 32R mid-taxi — the readbacks are graded next.)",
            aircraft: rv12, airport: concord, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via juliet, papa, cross runway one niner left.",
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via alpha, juliet, papa, cross runway one niner left.",
            ],
            amendmentVariants: [
                "RV seven three seven juliet alpha, change, runway three two right, continue via juliet — your new route stays south of one niner left, disregard the crossing.",
                "RV seven three seven juliet alpha, correction, runway three two right, continue via juliet, hold short of runway one niner left.",
            ]
        ),
        Drill(
            id: "t-ccr-long-route",
            scenario: .towered,
            title: "Four-segment taxi route",
            setup: "You're at transient parking on the south side at Concord with information Sierra, ready to depart VFR to the south. Call Ground for taxi — you'll be sent to the far north end of the field, so be ready to write the route down.",
            situation: "Towered field, you are Concord Ground. Grade the REQUEST — who they're calling, aircraft, position (transient parking, south side), the ATIS letter (current is information Sierra; a different letter gets 'verify you have information Sierra'), the direction of flight (VFR to the south), and the request to taxi for departure. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request. (You'll assign one niner right at the north end with a long four-segment route; the readback is graded next.)",
            aircraft: rv12, airport: concord, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Concord Ground, runway one niner right, taxi via golf, foxtrot, kilo, echo, cross runway three two left.",
                "RV seven three seven juliet alpha, Concord Ground, runway one niner right, taxi via golf, foxtrot, kilo, echo, hold short of runway three two left.",
            ]
        ),
        Drill(
            id: "t-ccr-crossing-revoked",
            scenario: .towered,
            title: "Crossing clearance revoked",
            setup: "You've landed on runway three two left at Concord and exited at hotel. You want another lap — call Ground to taxi back for departure, staying in the pattern.",
            situation: "Towered field, you are Concord Ground (the juliet / one niner left intersection is charted hot spot two). Grade the REQUEST — who they're calling, aircraft, position (clear of three two left at hotel), and the request to taxi back for departure. The pilot does NOT pick their runway — YOU assign it; don't require a runway in their request. (You'll clear them to cross one niner left; after they read it back, you REVOKE the crossing at the last second — hold short — the readbacks are graded next.)",
            aircraft: rv12, airport: concord, callType: .taxi, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, Concord Ground, runway three two left, taxi via juliet, papa, cross runway one niner left.",
            ],
            amendmentVariants: [
                "RV seven three seven juliet alpha, hold short of runway one niner left, hold short, traffic departing.",
                "RV seven three seven juliet alpha, cancel crossing clearance, hold short of runway one niner left, traffic departing.",
            ]
        ),
        Drill(
            id: "t-ccr-clearance-traffic-tail",
            scenario: .towered,
            title: "Takeoff clearance with a traffic tail",
            setup: "You're holding short of runway three two left at Concord, ready to go — there's a Cessna on final for the parallel and a helicopter working midfield. Call the tower.",
            situation: "Towered field, you are Concord Tower. Grade the REQUEST — who they're calling, aircraft, position (holding short three two left), and that they're ready for departure. The traffic-tail readback discipline (read back the clearance, not the traffic) is graded on their readback of your clearance, next.",
            aircraft: rv12, airport: concord, callType: .departure, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, runway three two left, cleared for takeoff, left crosswind departure approved, traffic is a Cessna on a two-mile final for the parallel and a helicopter transitioning midfield at five hundred feet.",
                "RV seven three seven juliet alpha, runway three two left, cleared for takeoff, traffic is a Cessna on a two-mile final for the parallel.",
                "RV seven three seven juliet alpha, runway three two left, line up and wait, traffic landing the parallel.",
            ]
        ),
        Drill(
            id: "t-rhv-departure-traffic-tail",
            scenario: .towered,
            title: "Cleared for takeoff, traffic both sides",
            setup: "You're number one, holding short of runway three one right at Reid-Hillview, ready to depart, with traffic working both parallels. Call the tower.",
            situation: "Towered field, you are Reid-Hillview Tower (parallel 31L/31R). Grade the REQUEST — who they're calling, aircraft, position (holding short three one right, number one), and that they're ready for departure. The readback discipline (clearance not traffic, and the full 'three one right' — never a bare 'three one') is graded on their readback of your clearance, next.",
            aircraft: rv12, airport: reidHillview, callType: .departure, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, runway three one right, cleared for takeoff, right turn on course approved, traffic departing the parallel is a Cherokee staying in the pattern and additional traffic is a Skyhawk on a four-mile final for your runway.",
                "RV seven three seven juliet alpha, runway three one right, cleared for takeoff, traffic is a Skyhawk on a four-mile final for your runway.",
                "RV seven three seven juliet alpha, runway three one right, line up and wait, traffic landing the parallel.",
            ]
        ),
        Drill(
            id: "t-request-option",
            scenario: .towered,
            title: "Request the option",
            setup: "You're holding short of runway three one at Palo Alto and want to stay in the pattern doing touch-and-goes. Call tower and request the option.",
            situation: "Towered field, you are Palo Alto Tower. Pilot wants pattern work. Expect: who they're calling, callsign, position (holding short three one), and a request for closed traffic / the option.",
            aircraft: rv12, airport: paloAlto, callType: .pattern, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, runway three one, cleared for the option, make left closed traffic.",
                "RV seven three seven juliet alpha, make left closed traffic, runway three one, cleared for takeoff.",
                "RV seven three seven juliet alpha, runway three one, line up and wait, traffic departing ahead.",
            ]
        ),
        Drill(
            id: "t-class-d-transition",
            scenario: .towered,
            title: "Class D transition",
            setup: "You're 10 miles south of Palo Alto at two thousand five hundred, not landing — you want to transition through their Class Delta surface area northbound. Call the tower.",
            situation: "Towered field, you are Palo Alto Tower. Pilot wants to transit the Class D, not land. Expect: who they're calling, aircraft, position and altitude, and the request ('request transition through your Delta northbound' or similar).",
            aircraft: rv12, airport: paloAlto, callType: .bravo, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, transition approved, maintain at or above one thousand five hundred, report clear of the Delta to the north.",
                "RV seven three seven juliet alpha, transition approved, maintain two thousand five hundred, report clear to the north.",
            ]
        ),
        Drill(
            id: "t-sayagain",
            scenario: .towered,
            title: "Missed a rapid instruction — say again",
            setup: "You're inbound to Monterey and tower fires off a long, fast instruction — you only caught part of it. You are NOT sure what they said. Make your call.",
            situation: "Towered field, you are Monterey Tower. You just issued a fast, complex pattern-entry instruction and the pilot missed it. The RIGHT answer is to ask rather than guess: callsign plus 'say again' (adding 'say again slower' or identifying as a student pilot is even better — controllers slow down for students). Grade whether they asked for a repeat instead of read back something they didn't hear; guessing or a vague 'roger' is WRONG and dangerous. When they ask, repeat the instruction slowly: 'enter left downwind runway two eight right, report midfield'.",
            aircraft: rv12, airport: monterey, callType: .emergency
        ),
        Drill(
            id: "t-phone-number",
            scenario: .towered,
            title: "Possible pilot deviation — copy a number",
            setup: "After landing at Monterey, tower says: RV seven three seven juliet alpha, possible pilot deviation, advise you have a phone number ready to copy. Respond.",
            situation: "Towered field, you are Monterey Tower issuing a Brasher warning. The pilot should stay calm and professional: acknowledge with callsign and 'ready to copy'. When they say ready, read the number 'six five zero, five five five, one two zero zero' and expect a readback of the digits with callsign. Coach that the right move is fly the airplane first, be polite, copy the number, and talk to a CFI or AOPA legal before calling — do not argue on frequency.",
            aircraft: rv12, airport: monterey, callType: .emergency
        ),
        Drill(
            id: "t-rhv-parallel",
            scenario: .towered,
            title: "Parallel runways — Reid-Hillview",
            setup: "You're 10 miles south of Reid-Hillview at two thousand five hundred, inbound to land with information Whiskey. Reid-Hillview has parallel runways three one left and three one right. Call the tower.",
            situation: "Towered field, you are Reid-Hillview Tower (KRHV, parallel runways 31L/31R; current ATIS is information Whiskey). After the pilot's inbound call, clear them: 'make right traffic runway three one right, report midfield'. The readback MUST name the correct parallel — 'three one right', not just 'three one'. If they read back the wrong parallel or drop the left/right, correct them immediately ('negative, runway three one RIGHT') and don't advance. Mention traffic landing the parallel ('traffic is a Cessna on final for the left') to exercise parallel awareness. Advance once they've read back the correct full runway.",
            aircraft: rv12, airport: reidHillview, callType: .arrival
        ),
        Drill(
            id: "t-sql-spacing",
            scenario: .towered,
            title: "Busy Delta — San Carlos spacing",
            setup: "You're inbound to San Carlos from the south at one thousand five hundred with information Oscar — a busy Class Delta tucked under the San Francisco Bravo shelf. Call the tower, and be ready: they're going to need spacing.",
            situation: "Towered field, you are San Carlos Tower (KSQL; current ATIS is information Oscar) and the pattern is FULL. Step 1: after the pilot's inbound call, issue a rapid spacing instruction: 'right three sixty for spacing, report re-entering the forty-five'. Grade the readback: the 360 direction plus callsign; a bare 'roger' gets 'read back the three sixty'. Step 2: after a correct readback, clear them: 'runway three zero, cleared to land, number three following a Cirrus on base'. Grade that readback: runway, clearance, and sequence acknowledgment. Keep your transmissions fast and clipped — this is a busy frequency. Advance only after both readbacks.",
            aircraft: rv12, airport: sanCarlos, callType: .pattern
        ),
        Drill(
            id: "t-svfr",
            scenario: .towered,
            title: "Special VFR — Monterey marine layer",
            setup: "The marine layer has Monterey reporting a niner hundred overcast — the field is IFR, but visibility underneath is good. You want to depart VFR to the east where it's clear. Call Monterey Ground and request a Special VFR departure.",
            situation: "Towered field, you are Monterey Ground (Class C surface area, field IFR: ceiling 900 overcast, visibility 5). The pilot must REQUEST Special VFR — it is never offered by ATC. Grade the request: who they're calling, callsign, position, and an explicit 'request Special VFR departure to the east'. Coach the rules if asked: SVFR needs 1 mile visibility and clear of clouds, pilot must request it, and it only applies within the surface area.",
            aircraft: rv12, airport: monterey, callType: .bravo, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, cleared out of the Monterey Class Charlie surface area to the east, maintain Special VFR conditions at or below one thousand five hundred, report leaving the surface area, squawk four five two one.",
                "RV seven three seven juliet alpha, cleared out of the Monterey Class Charlie surface area to the east, maintain Special VFR conditions at or below one thousand five hundred, squawk four five two one, and advise when clear of the surface area.",
            ]
        ),
        Drill(
            id: "t-lahso",
            scenario: .towered,
            title: "LAHSO — accept or decline",
            setup: "You're on final for runway three one at Salinas. Tower says: RV seven three seven juliet alpha, runway three one, cleared to land, hold short of runway two six, traffic departing runway two six. You may accept with a full readback — or decline. Your call.",
            situation: "Towered field, you are Salinas Tower (KSNS, intersecting runways 31 and 26) issuing a land-and-hold-short clearance. TWO correct answers, grade whichever the pilot chooses. ACCEPT: the readback must be verbatim and complete — 'cleared to land runway three one, hold short of runway two six' plus callsign; a partial readback ('cleared to land, 737JA') is NOT acceptable for LAHSO, demand the full hold-short readback. DECLINE: 'unable hold short, RV seven three seven juliet alpha' is completely legitimate — reply 'roger, runway three one, cleared to land, no restriction' and expect a normal readback. Either path advances once done correctly. In coaching, note the teaching point: pilots may ALWAYS decline LAHSO, and students generally should unless they know their landing distance cold.",
            aircraft: rv12, airport: salinas, callType: .readback
        ),
        Drill(
            id: "t-radio-failure",
            scenario: .towered,
            title: "Radio failure — transmit in the blind",
            setup: "Inbound to Palo Alto, your radio receives nothing — you suspect transmit may still work. You've squawked seven six zero zero. Transmit in the blind with your position and intentions.",
            situation: "You are simulating a NORDO (radio failure) arrival at a towered field. The pilot believes receive has failed and should transmit in the blind: identify the station and callsign, state 'transmitting in the blind', position, altitude, and intentions (e.g. 'will enter left downwind runway three one and look for light gun signals'), and mention squawking seven six zero zero. There is no controller reply — set speaker to 'none'. Grade completeness: blind-transmission format, position/intentions, 7600, and watching for light gun signals. In coaching, remind them: steady green means cleared to land.",
            aircraft: rv12, airport: paloAlto, callType: .emergency
        )
    ]

    // MARK: - Flight Following (radar advisories)

    public static let flightFollowing: [Drill] = [
        Drill(
            id: "ff-initial",
            scenario: .flightFollowing,
            title: "Initial callup (NorCal Approach)",
            setup: "You've departed Watsonville and want to check in with NorCal Approach for flight following, but haven't given details yet. Make just your brief initial callup.",
            situation: "You are NorCal Approach, and you are busy. Best practice on a busy frequency is a brief initial callup: facility, aircraft, and 'request VFR flight following' or 'with a request'. Reply with 'say request' or 'go ahead'. Grade whether the pilot kept the initial callup brief and did not dump all details at once.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "ff-request",
            scenario: .flightFollowing,
            title: "Request flight following (NorCal Approach)",
            setup: "NorCal Approach answers 'go ahead'. You're northbound out of Watsonville, climbing through two thousand five hundred, and you want VFR flight following to Sacramento at four thousand five hundred. Make your request.",
            situation: "You are NorCal Approach. The pilot is following up their initial callup with the details. Expect: aircraft type/callsign, position and altitude, request (VFR flight following), destination, and requested altitude. If something is missing, ask for just that item.",
            aircraft: rv12, airport: watsonville, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, squawk four five two one.",
                "RV seven three seven juliet alpha, squawk four five two one and ident.",
                "RV seven three seven juliet alpha, squawk four five two one, maintain VFR.",
            ]
        ),
        Drill(
            id: "ff-traffic",
            scenario: .flightFollowing,
            title: "Traffic advisory response",
            setup: "You're receiving flight following from NorCal Approach. NorCal calls: traffic, two o'clock, three miles, opposite direction, a Cirrus, altitude indicates three thousand five hundred. Respond appropriately.",
            situation: "You are NorCal Approach. You just issued a traffic advisory (2 o'clock, 3 miles, opposite direction, a Cirrus at 3,500). Grade the pilot's response: they should reply with their callsign plus 'looking', 'traffic in sight', or 'negative contact'. Reply only if a follow-up is warranted (e.g. confirming, or a safety alert).",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "ff-negative-contact",
            scenario: .flightFollowing,
            title: "Can't find the traffic — ask for help",
            setup: "You're on flight following at four thousand five hundred. NorCal calls: RV seven three seven juliet alpha, traffic one o'clock, five miles, converging, a Bonanza, altitude indicates four thousand five hundred. You scan hard and see nothing. Respond.",
            situation: "You are NorCal Approach. Step 1: you issued a traffic advisory — 1 o'clock, 5 miles, converging, a Bonanza at 4,500, the pilot's own altitude. Expect 'negative contact' or 'looking' plus callsign. Step 2: update the traffic — 'seven juliet alpha, traffic now one o'clock, two miles, converging, same altitude' — and grade the response: still not seeing converging same-altitude traffic inside two miles, the right answer is 'negative contact, request vectors' (asking for a turn away is equally good); a bare 'still looking' earns coaching. If they request vectors, reply 'turn left heading three one zero' and expect a readback of the heading with callsign. Set phaseAdvance true after the step-2 response, plus the readback if you issued a vector. Coach: converging, same altitude, can't see it — maneuver or ask, never just hope it misses.",
            aircraft: rv12, airport: watsonville, callType: .advisory
        ),
        Drill(
            id: "ff-traffic-alert",
            scenario: .flightFollowing,
            title: "Traffic alert — act now",
            setup: "You're on flight following at three thousand five hundred when NorCal calls, urgent: traffic alert, RV seven three seven juliet alpha, twelve o'clock, one mile, opposite direction, same altitude — advise you turn right immediately. Act.",
            situation: "You are NorCal Approach and you just issued a SAFETY ALERT — urgent, not a routine advisory. The right response is immediate action plus a short acknowledgment: 'turning right, seven three seven juliet alpha' ('traffic in sight' also works if they pick it up in the turn). Grade for brevity and an action word — a long careful readback wastes the second that matters, and a bare 'roger' with no stated action is not enough. Advance on a correct urgent response and reply 'traffic no longer a factor, resume own navigation'. Coach: a traffic alert means maneuver FIRST — the controller is telling you a collision is possible right now.",
            aircraft: rv12, airport: watsonville, callType: .advisory
        ),
        Drill(
            id: "ff-traffic-insight",
            scenario: .flightFollowing,
            title: "Traffic in sight — close the loop",
            setup: "A minute ago NorCal called traffic for you — a Skylane, ten o'clock, five miles, opposite direction, five hundred below — and you answered 'looking'. You've just picked it up, left and low, passing well clear. Let NorCal know.",
            situation: "You are NorCal Approach. Earlier you issued a traffic advisory (a Skylane, 10 o'clock, 5 miles, opposite direction, 500 below) and the pilot replied 'looking'. Now they should close the loop unprompted: 'traffic in sight' plus callsign. Reply 'roger'. Grade for the standard phrase — 'I see him' or 'got the traffic' earns coaching toward 'traffic in sight'. Coach why the report matters: once you say the traffic is in sight, the controller can quit babysitting that pair, and it sets up 'maintain visual separation' if they need it.",
            aircraft: rv12, airport: watsonville, callType: .advisory
        ),
        Drill(
            id: "ff-from-towered",
            scenario: .flightFollowing,
            title: "Flight following out of a towered field",
            setup: "You just departed Palo Alto to the south and the tower said 'frequency change approved.' You're climbing through two thousand five hundred and want VFR flight following to Watsonville. Contact NorCal Approach.",
            situation: "You are NorCal Approach. The pilot just departed a towered field and is now calling you for flight following. Expect facility, aircraft, position and altitude, request (VFR flight following), destination, and requested altitude. If anything is missing, ask for just that item.",
            aircraft: skyhawk, airport: paloAlto, followUpReadback: true,
            instructionVariants: [
                "Skyhawk one seven two sierra papa, squawk four five two one.",
                "Skyhawk one seven two sierra papa, squawk four five two one and ident.",
            ]
        ),
        Drill(
            id: "ff-handoff",
            scenario: .flightFollowing,
            title: "Frequency handoff (new sector)",
            setup: "You're on flight following with NorCal Approach. NorCal calls: seven three seven juliet alpha, contact NorCal Approach now on one three four point five. Read back the handoff, then check in on the new frequency.",
            situation: "You are NorCal Approach handing the pilot to the next sector. Step 1: the pilot should read back the new frequency and their callsign ('one three four point five, seven three seven juliet alpha'). Step 2, on the new frequency, they check in briefly: facility, callsign, and current altitude (e.g. 'NorCal Approach, seven three seven juliet alpha, level four thousand five hundred') — they do NOT re-request flight following. Only set phaseAdvance true once they've both read back the handoff and checked in on the new frequency; if they only did one, ask for the other.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "ff-altitude-change",
            scenario: .flightFollowing,
            title: "Request an altitude change",
            setup: "You're on flight following with NorCal Approach, level at four thousand five hundred, and you'd like to climb to six thousand five hundred for smoother air. Make your request.",
            situation: "You are NorCal Approach. The pilot on flight following requests a VFR altitude change from 4,500 to 6,500. Expect callsign plus the request. Reply with approval (e.g. 'altitude your discretion' or 'maintain VFR').",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "ff-terminate",
            scenario: .flightFollowing,
            title: "Terminate flight following",
            setup: "You're on flight following with NorCal Approach and you have Watsonville airport in sight, ready to cancel. Make your call.",
            situation: "You are NorCal Approach. The pilot has their destination in sight and wants to terminate flight following. Expect callsign, 'airport in sight', and 'cancel flight following' or 'request frequency change'. Reply with 'radar service terminated, squawk VFR, frequency change approved'.",
            aircraft: rv12, airport: watsonville
        ),
        Drill(
            id: "ff-bravo-request",
            scenario: .flightFollowing,
            title: "Request a Class Bravo clearance (SFO)",
            setup: "You're northbound near San Bruno at three thousand five hundred and you'd like a clearance to transit San Francisco's Class Bravo airspace. Call NorCal Approach.",
            situation: "You are NorCal Approach, working the San Francisco Bravo, and you are busy — you are NOT going to clear this aircraft into the Bravo. Grade the pilot's request: facility, aircraft, position and altitude, and an explicit request for a Class Bravo clearance (or to transit the Bravo). Then reply denying it: 'remain clear of the Class Bravo' (optionally with a reason or an instruction like 'maintain VFR at or below two thousand five hundred'). The key teaching point: you must be EXPLICITLY cleared into Class B — 'remain clear' means stay out.",
            aircraft: rv12, airport: sfoBravo
        ),
        Drill(
            id: "ff-bravo-denied",
            scenario: .flightFollowing,
            title: "Denied Bravo entry — acknowledge",
            setup: "NorCal Approach tells you: remain clear of the Class Bravo. Acknowledge and state how you'll avoid it.",
            situation: "You are NorCal Approach. You just told the pilot to remain clear of the Class Bravo. Grade their response: they must read back / acknowledge 'remain clear of the Bravo' with their callsign, and it's good practice to state their plan (e.g. 'will stay south' or 'descending to remain clear / staying below'). Confirm only if needed. The teaching point is that the pilot understands they may NOT enter without an explicit clearance.",
            aircraft: rv12, airport: sfoBravo
        ),
        Drill(
            id: "ff-bravo-granted",
            scenario: .flightFollowing,
            title: "Cleared through the Bravo — read it back",
            setup: "You're northbound near San Bruno at three thousand five hundred and you'd like a clearance to transit San Francisco's Class Bravo. Call NorCal Approach and request it.",
            situation: "You are NorCal Approach, working the San Francisco Bravo, and today you can approve it. Grade the REQUEST — who they're calling, aircraft, position and altitude, and an explicit request for a Bravo clearance (or to transit the Bravo). The magic-words readback ('cleared through the Bravo' + the altitude, no vague 'roger') is graded on their readback of your clearance, next.",
            aircraft: rv12, airport: sfoBravo, callType: .bravo, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, cleared through the San Francisco Class Bravo, maintain three thousand five hundred.",
                "RV seven three seven juliet alpha, cleared into the San Francisco Class Bravo, maintain at or below four thousand five hundred.",
                "RV seven three seven juliet alpha, cleared through the San Francisco Class Bravo, maintain three thousand five hundred, expect higher in five miles.",
            ]
        ),
        Drill(
            id: "ff-classc-entry",
            scenario: .flightFollowing,
            title: "Class Charlie entry — two-way contact",
            setup: "You're 15 miles northeast of Monterey at three thousand five hundred, inbound to land, with information Romeo. Monterey is Class Charlie — call NorCal Approach to establish two-way communication before entering.",
            situation: "You are NorCal Approach working the Monterey Class C. The pilot must establish two-way radio communication before entering: expect facility, aircraft type and callsign, position and altitude, the ATIS letter (current is information Romeo), and intentions (landing Monterey). KEY TEACHING POINT — the two-way rule: if you reply WITH their callsign (even 'RV seven three seven juliet alpha, standby'), communication is established and they may enter the Charlie; if you say 'aircraft calling, standby' WITHOUT the callsign, they may NOT enter. If their callup is incomplete, reply without using their callsign so they learn the difference, and say what you need.",
            aircraft: rv12, airport: monterey, callType: .bravo, followUpReadback: true,
            instructionVariants: [
                "RV seven three seven juliet alpha, squawk four five two one and ident.",
                "RV seven three seven juliet alpha, Monterey altimeter three zero zero one, squawk four five two one.",
            ]
        ),
        Drill(
            id: "ff-squawk-verify",
            scenario: .flightFollowing,
            title: "Squawk assignment readback",
            setup: "NorCal Approach assigns: RV seven three seven juliet alpha, squawk four five two one and ident. Read it back.",
            situation: "You are NorCal Approach. You assigned 'squawk four five two one and ident'. Grade the readback: the four digits plus callsign ('four five two one and ident, seven three seven juliet alpha'). If they read back wrong digits, correct them immediately — a wrong squawk is how you become somebody else on the scope. Advance on a correct readback; after it, reply 'radar contact'.",
            aircraft: rv12, airport: watsonville, callType: .flightFollowing
        ),
        Drill(
            id: "ff-vector",
            scenario: .flightFollowing,
            title: "Traffic vector — turn, then resume own nav",
            setup: "You're on flight following at four thousand five hundred. NorCal calls: RV seven three seven juliet alpha, traffic twelve o'clock, five miles, opposite direction — turn right heading zero four zero. Read back the vector; NorCal will put you back on course once the traffic is clear.",
            situation: "You are NorCal Approach. Step 1: you issued 'turn right heading zero four zero' for traffic. Grade the readback: the heading plus callsign ('right heading zero four zero, seven three seven juliet alpha'). A bare 'roger' is NOT acceptable for a heading — ask for the readback. Step 2: after a correct readback, call 'traffic no longer a factor, resume own navigation' and grade the acknowledgment ('resume own navigation' or 'own nav' plus callsign). Set phaseAdvance true only after both the vector readback and the resume acknowledgment.",
            aircraft: rv12, airport: watsonville, callType: .flightFollowing
        ),
        Drill(
            id: "ff-restriction-handoff",
            scenario: .flightFollowing,
            title: "Altitude restriction + handoff — announce it",
            setup: "On flight following, NorCal assigns: RV seven three seven juliet alpha, maintain at or below two thousand five hundred for crossing traffic; contact NorCal Approach on one two seven point one five. Read it back, then check in on the new frequency.",
            situation: "You are NorCal Approach. Step 1: you issued an altitude restriction ('maintain at or below two thousand five hundred') plus a frequency change ('contact NorCal Approach on one two seven point one five'). Grade the readback: the restriction, the frequency, and the callsign. Step 2: on the new frequency the pilot checks in and MUST announce the restriction so the new controller knows — e.g. 'NorCal Approach, RV seven three seven juliet alpha, two thousand three hundred, assigned at or below two thousand five hundred'. If they check in without stating the assigned restriction, reply 'say assigned altitude' and do not advance. Set phaseAdvance true only after both the readback and the restricted check-in.",
            aircraft: rv12, airport: watsonville, callType: .flightFollowing
        ),
        Drill(
            id: "ff-service-denied",
            scenario: .flightFollowing,
            title: "Flight following unavailable",
            setup: "You call NorCal Approach for flight following and they answer: RV seven three seven juliet alpha, unable flight following at this time, radar services not available, squawk VFR. Respond, and know what you'll do next.",
            situation: "You are NorCal Approach and you just DENIED flight following due to workload ('unable, squawk VFR'). Grade the pilot's response: acknowledge with callsign and 'squawk VFR' (returning to one two zero zero), no argument, and good form is stating they'll continue VFR on their own navigation. In coaching, remind them: denial isn't personal — it's workload; they can try again with the next sector in ten minutes, and they should tighten up their own traffic scan since nobody is calling traffic for them now.",
            aircraft: rv12, airport: watsonville, callType: .flightFollowing
        ),
        Drill(
            id: "ff-moa-check",
            scenario: .flightFollowing,
            title: "Is the MOA hot?",
            setup: "You're on flight following, southbound toward a Military Operations Area on your route. Ask NorCal whether it's active before you fly into it.",
            situation: "You are NorCal Approach. The pilot on flight following wants the status of the MOA ahead (call it the Hunter MOA). Expect: callsign plus a clear question — 'request status of the Hunter MOA' or 'is the Hunter MOA active'. Reply realistically: 'Hunter MOA is active from three thousand to one one thousand; suggest routing west of the boundary' (or cold, your choice — pick active so they practice the follow-up). If active, expect them to state a plan: deviate around it or stay below/above the active altitudes. VFR flight through an active MOA is legal but unwise; coach that asking is exactly what flight following is for.",
            aircraft: rv12, airport: salinas, callType: .flightFollowing
        ),
        Drill(
            id: "ff-diversion",
            scenario: .flightFollowing,
            title: "Weather diversion on flight following",
            setup: "You're on flight following to Livermore at four thousand five hundred, but a wall of low clouds is filling the valley ahead. You've decided to divert to Salinas. Tell NorCal what you're doing.",
            situation: "You are NorCal Approach. The pilot on flight following (destination Livermore) is diverting for weather. Expect: callsign, the request ('request direct Salinas, diverting for weather' or similar), and ideally a new altitude if they need one. A good diversion call is decisive — they tell you the new plan, they don't ask permission to stay safe. Reply: 'RV seven juliet alpha, roger, proceed direct Salinas, maintain VFR, Salinas altimeter three zero zero one' and update their destination. If they don't state a reason, ask 'say reason for the diversion' — weather info helps the next pilot. Advance once the diversion request and any readback are complete. Coach the big lesson: divert EARLY, tell ATC immediately, and never let a destination fixation argue with a cloud deck.",
            aircraft: rv12, airport: salinas, callType: .flightFollowing
        ),
        Drill(
            id: "ff-min-fuel",
            scenario: .flightFollowing,
            title: "Minimum fuel vs emergency fuel",
            setup: "Headwinds ate your reserve: you'll land at Salinas with about thirty minutes of fuel — legal, but with no margin for delays. You're on flight following with NorCal. Make the call that tells them.",
            situation: "You are NorCal Approach. The pilot should declare MINIMUM FUEL: callsign plus 'minimum fuel' (e.g. 'RV seven three seven juliet alpha, minimum fuel'). Reply: 'RV seven juliet alpha, roger, no delay expected, Salinas is twelve o'clock, one five miles'. KEY TEACHING POINT — grade their understanding of the distinction: 'minimum fuel' is an ADVISORY that they can accept no undue delay; it grants NO priority. If they need priority handling, they must declare 'emergency fuel' (or mayday), which does. If the pilot declares an emergency here, that's acceptable too if they characterize it correctly — grade the phraseology either way. If they just tell you their fuel state without the words 'minimum fuel', ask 'say intentions' and coach the standard phrase. Advance after a correct declaration.",
            aircraft: rv12, airport: salinas, callType: .emergency
        ),
        Drill(
            id: "ff-emergency-declare",
            scenario: .flightFollowing,
            title: "Declare an emergency",
            setup: "You're on flight following with NorCal at four thousand five hundred near Salinas when your engine starts running very rough — losing power. Declare an emergency. Say what you need.",
            situation: "You are NorCal Approach and the pilot is declaring an emergency (rough-running engine, partial power). Grade the declaration: 'mayday' (or at minimum 'declaring an emergency' — pan-pan acceptable for urgency), callsign, nature of the emergency, intentions (e.g. diverting direct Salinas), and position/altitude if not already known. Then play it real: reply calmly with 'radar contact… Salinas is eleven o'clock, six miles, cleared direct, descend at your discretion' and ASK for what's missing — 'say souls on board and fuel remaining'. Grade their answer to that too. Coach hard on the big lesson: aviate first, declare early, ATC works for you now — never be shy about the M-word.",
            aircraft: rv12, airport: salinas, callType: .emergency
        ),
        Drill(
            id: "ff-lost-vectors",
            scenario: .flightFollowing,
            title: "Lost — ask for help",
            setup: "You got turned around in haze over unfamiliar terrain and you are genuinely unsure of your position. You have NorCal's frequency. Swallow your pride and make the call.",
            situation: "You are NorCal Approach. A VFR pilot is disoriented/lost and calling for help. Grade the call: facility, callsign, admitting they're unsure of position ('student pilot' if they choose — encourage it in coaching, controllers give students extra care), last known position or landmarks in sight, altitude, and fuel state if offered. Reply like a pro: 'squawk four five two one and ident', then after the ident, 'radar contact two zero miles southeast of Hollister; fly heading three one zero, Hollister is twelve o'clock and one five miles'. Expect a readback of the heading with callsign. Coach the big lesson: confess early — lost pilots who ask for help are a non-event; lost pilots who don't become NTSB reports. The four Cs: climb, communicate, confess, comply.",
            aircraft: rv12, airport: hollister, callType: .emergency
        )
    ]
}
