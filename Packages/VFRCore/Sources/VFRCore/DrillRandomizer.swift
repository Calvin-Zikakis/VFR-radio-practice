import Foundation

/// Varies the incidental details of drills — ATIS letter, distances, squawk
/// codes, runways, altitudes — so repeated sessions can't be answered from
/// memory. Substitutions are applied consistently to both `setup` (spoken to
/// the pilot) and `situation` (handed to the grader), so the two never
/// disagree.
///
/// Runways flip to the airport's real reciprocal (wind swapped: Watsonville 20
/// becomes 2, Palo Alto 31 becomes 13), decided once per airport per session so
/// a whole trip stays coherent. Altitudes shift by one consistent offset per
/// session so climb/cruise relationships are preserved.
public enum DrillRandomizer {

    public static func vary(_ drills: [Drill]) -> [Drill] {
        // One decision per airport per session: which runway is the wind
        // favoring today? And one altitude offset for the session.
        var runwayChoice: [String: String?] = [:]
        for d in drills where runwayChoice[d.airport.icao] == nil {
            runwayChoice[d.airport.icao] = pickRunway(for: d.airport)
        }
        let altitudeOffset = [0, 1000, 2000].randomElement() ?? 0

        return drills.map {
            vary($0, runway: runwayChoice[$0.airport.icao] ?? nil,
                 altitudeOffset: altitudeOffset)
        }
    }

    public static func vary(_ drill: Drill) -> Drill {
        vary(drill,
             runway: pickRunway(for: drill.airport),
             altitudeOffset: [0, 1000, 2000].randomElement() ?? 0)
    }

    /// Pick today's runway from the airport's real alternatives (or nil to
    /// keep the authored one).
    private static func pickRunway(for airport: Airport) -> String? {
        guard let primary = airport.runwaysInUse.first,
              let alternates = alternateRunways[airport.icao] else { return nil }
        let choice = ([primary] + alternates).randomElement() ?? primary
        return choice == primary ? nil : choice
    }

    static func vary(_ drill: Drill, runway: String?, altitudeOffset: Int) -> Drill {
        var d = drill
        var subs: [(String, String)] = []

        // Runway swap FIRST, against the authored text — later substitutions
        // (random squawk digits, distances) could otherwise collide with the
        // bare runway-number tokens.
        if let runway, let primary = drill.airport.runwaysInUse.first, runway != primary,
           !runwaySwapExempt.contains(drill.id) {
            subs.append((TripBuilder.spokenRunway(primary), TripBuilder.spokenRunway(runway)))
            subs.append((primary, runway))
            d.airport.runwaysInUse = drill.airport.runwaysInUse.map { $0 == primary ? runway : $0 }
        }

        if altitudeOffset != 0 {
            subs.append(contentsOf: altitudeSubstitutions(offset: altitudeOffset))
        }

        subs.append(contentsOf: incidentalSubstitutions(for: drill))

        d.setup = applying(subs, to: d.setup)
        d.situation = applying(subs, to: d.situation)
        return d
    }

    /// Apply all pairs simultaneously (two-pass through unique placeholders),
    /// so one substitution's output can never be re-matched by a later pair —
    /// e.g. shifting 2,500 → 3,500 must not chain into the 3,500 → 4,500 pair.
    static func applying(_ subs: [(String, String)], to text: String) -> String {
        var t = text
        for (i, pair) in subs.enumerated() {
            t = t.replacingOccurrences(of: pair.0, with: "\u{1}\(i)\u{2}")
        }
        for (i, pair) in subs.enumerated() {
            t = t.replacingOccurrences(of: "\u{1}\(i)\u{2}", with: pair.1)
        }
        return t
    }

    // MARK: - Runways

    /// The real alternate runways each airport can be "using" today, besides
    /// the authored primary. Only airports whose drill texts reference a single
    /// runway are listed — KMRY is excluded because its taxi drills name
    /// crossing runways (a blind swap would collide with them); KSFO is
    /// Bravo-context only.
    /// Drills whose text names more than one runway at the airport — swapping
    /// the primary would collide with the other (e.g. LAHSO's hold-short
    /// runway 26 at Salinas).
    static let runwaySwapExempt: Set<String> = ["t-lahso", "t-sns-taxi"]

    // Verified against AirNav (FAA data), 2026-07. KRHV is excluded like KMRY:
    // its parallel-runway drill names both 31L and 31R, so a blind swap would
    // corrupt the briefing.
    static let alternateRunways: [String: [String]] = [
        "KWVI": ["2", "9", "27"],       // 2/20 + 9/27 crosswind
        "KPAO": ["13"],                 // single runway 13/31
        "E16": ["14"],                  // single runway 14/32
        "KCVH": ["13", "6", "24"],      // 13/31 + 6/24
        "KSNS": ["13", "8", "26"],      // 13/31 + 8/26
        "KLVK": ["7L", "7R", "25L"],    // 7L/25R + 7R/25L
        "KHAF": ["12"],                 // single runway 12/30
        "KSQL": ["12"],                 // single runway 12/30
        "KOAR": ["11"],                 // single runway 11/29
    ]

    // MARK: - Altitudes

    /// The VFR cruise altitudes the drills are authored with, spoken + digit
    /// forms. 1,500 is deliberately excluded — it appears in Class D transition
    /// restrictions that must stay below the Delta ceiling.
    private static let altitudeFeet = [2500, 3500, 4500, 6500]

    private static func altitudeSubstitutions(offset: Int) -> [(String, String)] {
        altitudeFeet.flatMap { alt -> [(String, String)] in
            let to = alt + offset
            return [
                (spokenAltitude(alt), spokenAltitude(to)),
                (digitsAltitude(alt), digitsAltitude(to)),
            ]
        }
    }

    static func spokenAltitude(_ feet: Int) -> String {
        let thousands = ["one", "two", "three", "four", "five", "six", "seven", "eight", "niner"]
        let t = feet / 1000
        let word = (t >= 1 && t <= 9) ? thousands[t - 1] : "\(t)"
        return feet % 1000 == 500 ? "\(word) thousand five hundred" : "\(word) thousand"
    }

    static func digitsAltitude(_ feet: Int) -> String {
        "\(feet / 1000),\(String(format: "%03d", feet % 1000))"
    }

    // MARK: - Incidental details (ATIS, distances, squawks)

    private static func incidentalSubstitutions(for drill: Drill) -> [(String, String)] {
        var subs: [(String, String)] = []
        let text = drill.setup + " " + drill.situation

        // ATIS letter: replace "information X" / "ATIS X" pairs with one new
        // letter. Never touch bare letter words ("Class Bravo" must survive).
        if let current = atisLetters.first(where: {
            text.contains("information \($0)") || text.contains("ATIS \($0)")
        }) {
            let replacement = atisLetters.filter { $0 != current }.randomElement() ?? current
            subs.append(("information \(current)", "information \(replacement)"))
            subs.append(("ATIS \(current)", "ATIS \(replacement)"))
        }

        // Distance: one consistent value per drill for "10/ten miles" and the
        // compact "10 <direction>" forms used in situations.
        if text.contains("10 miles") || text.contains("ten miles")
            || directions.contains(where: { text.contains("10 \($0)") }) {
            let n = [7, 8, 9, 11, 12, 15].randomElement() ?? 10
            subs.append(("ten miles", "\(n) miles"))
            subs.append(("10 miles", "\(n) miles"))
            for dir in directions {
                subs.append(("10 \(dir)", "\(n) \(dir)"))
            }
        }

        // Squawk code: drills are authored with 4521; swap in a fresh valid
        // code (digits 0–7, avoiding the special-purpose codes).
        if text.contains("four five two one") || text.contains("4521") {
            let code = randomSquawk()
            subs.append(("four five two one", spoken(squawk: code)))
            subs.append(("4521", code))
        }

        return subs
    }

    private static let atisLetters = [
        "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf",
        "Hotel", "India", "Juliet", "Kilo", "Lima", "Mike", "November",
        "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform",
        "Victor", "Whiskey", "X-ray", "Yankee", "Zulu"
    ]

    private static let directions = ["north", "south", "east", "west"]

    /// Special-purpose codes a controller would never assign.
    private static let reservedSquawks: Set<String> = ["1200", "7500", "7600", "7700", "7777", "0000"]

    static func randomSquawk() -> String {
        var code: String
        repeat {
            code = String((0..<4).map { _ in "01234567".randomElement()! })
        } while reservedSquawks.contains(code)
        return code
    }

    static func spoken(squawk code: String) -> String {
        let words: [Character: String] = [
            "0": "zero", "1": "one", "2": "two", "3": "three",
            "4": "four", "5": "five", "6": "six", "7": "seven"]
        return code.compactMap { words[$0] }.joined(separator: " ")
    }
}
