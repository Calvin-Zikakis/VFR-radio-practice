import Foundation

/// A user-built cross-country: an ordered list of airports to fly, plus whether
/// to work flight following enroute and do pattern work / touch-and-goes at the
/// stops. `TripBuilder` turns it into an ordered sequence of `Drill`s — taxi,
/// departure, flight following, arrival, pattern — adapted to whether each field
/// is towered or untowered.
public struct TripPlan: Sendable, Equatable {
    public var stops: [Airport]
    public var flightFollowing: Bool
    public var patternWork: Bool

    public init(stops: [Airport], flightFollowing: Bool = true, patternWork: Bool = true) {
        self.stops = stops
        self.flightFollowing = flightFollowing
        self.patternWork = patternWork
    }

    /// A trip needs at least an origin and a destination.
    public var isValid: Bool { stops.count >= 2 }
}

public enum TripBuilder {

    /// Generate the ordered call sequence for a trip, all flown in `aircraft`.
    ///
    /// Shape of a flight: depart the origin, (request flight following), fly the
    /// legs doing a touch-and-go at each intermediate stop, (terminate flight
    /// following), then a full-stop arrival at the destination. Class D handoffs
    /// enroute are simplified away — flight following is treated as one through
    /// line for practice purposes.
    public static func drills(for plan: TripPlan, aircraft: Aircraft) -> [Drill] {
        guard plan.isValid else { return [] }

        var out: [Drill] = []
        var n = 0
        func add(_ scenario: ScenarioType, _ title: String,
                 _ setup: String, _ situation: String, at ap: Airport) {
            n += 1
            out.append(Drill(id: "trip-\(n)", scenario: scenario, title: title,
                             setup: setup, situation: situation,
                             aircraft: aircraft, airport: ap,
                             callType: callType(fromTitle: title, scenario: scenario)))
        }

        let origin = plan.stops.first!
        let destination = plan.stops.last!

        departure(from: origin, toward: plan.stops[1].name, add: add)

        if plan.flightFollowing {
            flightFollowingRequest(from: origin, destination: destination.name, add: add)
            trafficAdvisory(near: origin, add: add)
            trafficVector(near: origin, plane: aircraft, add: add)
            frequencyHandoff(near: origin, plane: aircraft, add: add)
        }

        // Intermediate stops are full-stop visits — land, clear the runway,
        // taxi in, taxi back out, depart — the whole real-flight ground game,
        // not a touch-and-go flyby.
        for stop in plan.stops.dropFirst().dropLast() {
            arrival(at: stop, touchAndGo: false, detailed: plan.patternWork, add: add)
            departure(from: stop, toward: destination.name, add: add)
        }

        if plan.flightFollowing {
            flightFollowingTerminate(near: destination, add: add)
        }

        arrival(at: destination, touchAndGo: false, detailed: plan.patternWork, add: add)

        // Request-style phases chain: passing the request injects a readback
        // drill built from whatever instruction the grader improvised —
        // taxi-in routes, takeoff clearances, pattern entries, FF squawks.
        for i in out.indices {
            let t = out[i].title
            if t.hasPrefix("Ready for departure —")
                || t.hasPrefix("Request flight following —")
                || (t.hasPrefix("Taxi —") && t.hasSuffix("Ground"))
                || (t.hasPrefix("Clear of the runway —") && t.hasSuffix("Ground"))
                || (t.hasPrefix("Inbound —") && t.hasSuffix("Tower")) {
                out[i].followUpReadback = true
            }
        }
        return out
    }

    /// Tag generated phases with a call type (the titles are authored below,
    /// so keying on them is stable). Used for per-call-type stats.
    private static func callType(fromTitle title: String, scenario: ScenarioType) -> CallType {
        if title.contains("Taxi") && !title.contains("self-announce") { return .taxi }
        if title.contains("Taxi self-announce") { return .taxi }
        if title.contains("departure") || title.contains("Departing") { return .departure }
        if title.contains("Traffic advisory") { return .advisory }
        if title.contains("pattern") || title.contains("Downwind") || title.contains("Base") { return .pattern }
        if title.contains("Clear of the runway") { return .afterLanding }
        if title.contains("Inbound") { return .arrival }
        if scenario == .flightFollowing { return .flightFollowing }
        return .arrival
    }

    // MARK: - Phase builders

    private typealias Add = (ScenarioType, String, String, String, Airport) -> Void

    private static func departure(from ap: Airport, toward dest: String,
                                  add: Add, skipTaxi: Bool = false) {
        let rwy = spokenRunway(firstRunway(ap))
        if ap.isTowered {
            if !skipTaxi {
                let atis = atisLetter()
                add(.towered, "Taxi — \(ap.name) Ground",
                    "You're at \(ap.name) with information \(atis), parked at the ramp, ready to taxi for a VFR departure toward \(dest). Call \(ap.name) Ground.",
                    "Towered field, you are \(ap.name) Ground. Runway \(firstRunway(ap)) in use. Grade the request: who they're calling, aircraft, position, the ATIS letter (current is information \(atis); a different letter gets 'verify you have information \(atis)'), request, and direction of flight. Once the request is complete, reply with a taxi clearance to runway \(firstRunway(ap)) with a route (vary the taxiways) AND set phaseAdvance true: the pilot's readback of your clearance is graded as the next exercise, not by you.",
                    ap)
            }
            add(.towered, "Ready for departure — \(ap.name) Tower",
                "You're holding short of runway \(rwy) at \(ap.name), ready for a VFR departure toward \(dest). Call the tower.",
                "Towered field, you are \(ap.name) Tower. Pilot is holding short runway \(firstRunway(ap)) requesting a VFR departure. Expect who they're calling, aircraft, position (holding short), and request/intentions. Reply with a takeoff clearance.",
                ap)
        } else {
            if !skipTaxi {
                add(.untowered, "Taxi self-announce — \(ap.name)",
                    "You're at \(ap.name), about to taxi from the ramp for departure on runway \(rwy). Make your taxi call.",
                    "Uncontrolled field (\(ap.name)). Pilot is taxiing to runway \(firstRunway(ap)). Expect a CTAF self-announce: airport, aircraft, where they're taxiing (to runway \(firstRunway(ap))), airport again. A taxi call does NOT require departure intentions or direction of flight — never ask for those here; they belong in the departure call.",
                    ap)
            }
            add(.untowered, "Departing — \(ap.name)",
                "You're holding short of runway \(rwy) at \(ap.name), ready to depart toward \(dest). Make your departure call.",
                "Uncontrolled field (\(ap.name)). Pilot is departing runway \(firstRunway(ap)) on course toward \(dest). Expect airport, aircraft, departing runway \(firstRunway(ap)), direction/intentions, airport again. No controller reply; other traffic may respond.",
                ap)
        }
    }

    private static func arrival(at ap: Airport, touchAndGo: Bool, detailed: Bool, add: Add) {
        let rwy = spokenRunway(firstRunway(ap))
        let intent = touchAndGo ? "for the option" : "to land, full stop"
        let atis = atisLetter()
        if ap.isTowered {
            // When a "report the pattern" phase follows, the tower's improvised
            // pattern entry must match it — a "report right base" here would
            // contradict the scripted left-downwind report one step later.
            let entry = detailed
                ? "Reply with runway \(firstRunway(ap)) and this exact pattern entry: report left downwind."
                : "Reply with pattern entry and runway \(firstRunway(ap))."
            add(.towered, "Inbound — \(ap.name) Tower",
                "You're 10 miles from \(ap.name) at two thousand five hundred, inbound \(intent), with information \(atis). Call \(ap.name) Tower.",
                "Towered field, you are \(ap.name) Tower. Pilot is 10 miles out at 2,500 inbound \(intent) with ATIS \(atis). Expect who they're calling, aircraft, position and altitude, the ATIS letter, and request. \(entry)",
                ap)
            if detailed {
                add(.towered, "Report the pattern — \(ap.name) Tower",
                    "\(ap.name) Tower told you to report a left downwind for runway \(rwy). Make that report.",
                    "Towered field, you are \(ap.name) Tower. Pilot was told to report left downwind. Expect callsign plus position ('left downwind runway \(firstRunway(ap))'). Reply with the landing clearance or the option — or sequence them with traffic ('number two, report base'). If you sequence them, the exchange is NOT over: expect the readback, then their base report, then issue the landing clearance. Set phaseAdvance only once the landing (or option) clearance has been issued and read back — never right after asking for a report you haven't received.",
                    ap)
            }
            if !touchAndGo {
                add(.towered, "Clear of the runway — \(ap.name) Ground",
                    "You've landed at \(ap.name) and are clear of runway \(rwy). The tower said contact ground. Call \(ap.name) Ground to taxi to parking.",
                    "Towered field, you are \(ap.name) Ground. Pilot just cleared the runway. Expect who they're calling, aircraft, position, and a request to taxi to parking. Once the request is complete, reply with a taxi clearance with a route (vary the taxiways) AND set phaseAdvance true: the pilot's readback of your clearance is graded as the next exercise, not by you.",
                    ap)
            }
        } else {
            add(.untowered, "Inbound — \(ap.name)",
                "You're 10 miles from \(ap.name), inbound \(intent). Make your inbound call.",
                "Uncontrolled field (\(ap.name)). Pilot is 10 miles out inbound \(intent). Expect airport, aircraft, position and altitude, intentions, a request for airport advisories, airport again.",
                ap)
            if detailed {
                add(.untowered, "Downwind — \(ap.name)",
                    "You're entering a left downwind for runway \(rwy) at \(ap.name), \(intent). Make your downwind call.",
                    "Uncontrolled field (\(ap.name)). Pilot is on left downwind for runway \(firstRunway(ap)). Expect airport, aircraft, position in the pattern, intentions (\(intent)), airport again.",
                    ap)
                add(.untowered, "Base and final — \(ap.name)",
                    "You're turning left base for runway \(rwy) at \(ap.name), \(intent). Make your base call.",
                    "Uncontrolled field (\(ap.name)). Pilot is turning base to final for runway \(firstRunway(ap)). Expect airport, aircraft, position, intentions, airport again.",
                    ap)
            }
            if !touchAndGo {
                add(.untowered, "Clear of the runway — \(ap.name)",
                    "You've landed and taxied clear of runway \(rwy) at \(ap.name). Make your call.",
                    "Uncontrolled field (\(ap.name)). Pilot has exited the runway. Expect a brief self-announce that they are clear of runway \(firstRunway(ap)), airport name. Keep it short.",
                    ap)
            }
        }
    }

    private static func flightFollowingRequest(from ap: Airport, destination: String, add: Add) {
        add(.flightFollowing, "Initial callup — NorCal Approach",
            "You've departed \(ap.name) and want to check in with NorCal Approach for flight following, but haven't given details yet. Make just your brief initial callup.",
            "You are NorCal Approach, and you are busy. Best practice on a busy frequency is a brief initial callup: facility, aircraft, and 'request VFR flight following' or 'with a request'. Reply with 'go ahead' or 'say request'. Grade whether the pilot kept it brief and did not dump all the details at once.",
            ap)
        add(.flightFollowing, "Request flight following — NorCal Approach",
            "NorCal Approach answers 'go ahead'. You're climbing through two thousand five hundred, en route to \(destination) at four thousand five hundred. Make your request.",
            "You are NorCal Approach. The pilot is following up their initial callup. Expect: aircraft type/callsign, position and altitude, request (VFR flight following), destination (\(destination)), and requested altitude. While anything is missing, ask ONLY for the missing item — never assign the squawk yet. Once the request is complete, your final reply assigns the squawk with 'radar contact' AND you set phaseAdvance true: the squawk readback is graded as the next exercise, not by you.",
            ap)
    }

    private static func trafficAdvisory(near ap: Airport, add: Add) {
        add(.flightFollowing, "Traffic advisory",
            "You're on flight following with NorCal Approach. NorCal calls: traffic, two o'clock, three miles, opposite direction, a Cirrus, altitude indicates three thousand five hundred. Respond appropriately.",
            "You are NorCal Approach. You just issued a traffic advisory (2 o'clock, 3 miles, opposite direction, a Cirrus at 3,500). Grade the pilot's response: callsign plus 'looking', 'traffic in sight', or 'negative contact'. Reply only if a follow-up is warranted.",
            ap)
    }

    private static func trafficVector(near ap: Airport, plane: Aircraft, add: Add) {
        let cs = DrillLibrary.bareCallsign(plane)
        add(.flightFollowing, "Traffic vector",
            "NorCal calls: \(cs), traffic twelve o'clock, five miles, opposite direction — turn right heading zero four zero. Read back the vector; you'll be put back on course once clear.",
            "You are NorCal Approach. Step 1: you issued 'turn right heading zero four zero' for traffic — grade the readback (heading plus callsign; a bare 'roger' is not acceptable for a heading). Step 2: after a correct readback, call 'traffic no longer a factor, resume own navigation' and grade the acknowledgment (own nav plus callsign). Set phaseAdvance true only after both steps.",
            ap)
    }

    private static func frequencyHandoff(near ap: Airport, plane: Aircraft, add: Add) {
        let cs = DrillLibrary.bareCallsign(plane)
        add(.flightFollowing, "Frequency handoff",
            "NorCal Approach calls: \(cs), contact NorCal Approach now on one three four point five. Read back the handoff, then check in on the new frequency.",
            "You are NorCal Approach handing the pilot to the next sector as they progress. Step 1: read back the new frequency and callsign ('one three four point five, \(cs)'). Step 2, on the new frequency, a brief check-in: facility, callsign, and current altitude — no re-request of flight following. Set phaseAdvance true only once they've read back the handoff AND checked in; otherwise ask for the missing part.",
            ap)
    }

    private static func flightFollowingTerminate(near ap: Airport, add: Add) {
        add(.flightFollowing, "Terminate flight following",
            "You're on flight following with NorCal Approach and you have \(ap.name) in sight, ready to cancel. Make your call.",
            "You are NorCal Approach. The pilot has their destination in sight and wants to terminate flight following. Expect callsign, 'airport in sight', and 'cancel flight following' or 'request frequency change'. Reply with 'radar service terminated, squawk VFR, frequency change approved'.",
            ap)
    }

    // MARK: - Spoken-form helpers

    private static func firstRunway(_ ap: Airport) -> String {
        ap.runwaysInUse.first ?? "the active"
    }

    /// "31" → "three one", "28R" → "two eight right", "20" → "two zero".
    public static func spokenRunway(_ r: String) -> String {
        let map: [Character: String] = [
            "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
            "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "niner",
            "L": "left", "R": "right", "C": "center"]
        let words = r.uppercased().compactMap { map[$0] }
        return words.isEmpty ? r : words.joined(separator: " ")
    }

    private static func atisLetter() -> String {
        ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot",
         "Golf", "Quebec", "Zulu"].randomElement() ?? "Bravo"
    }
}
