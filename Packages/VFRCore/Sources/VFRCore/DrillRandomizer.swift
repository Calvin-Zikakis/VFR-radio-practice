import Foundation

/// Varies the incidental details of drills — ATIS letter, distances, squawk
/// codes — so repeated sessions can't be answered from memory. Substitutions
/// are applied consistently to both `setup` (spoken to the pilot) and
/// `situation` (handed to the grader), so the two never disagree.
///
/// Only details that appear in authored, predictable spoken forms are varied.
/// Runways and altitudes stay fixed for now: they're woven into pattern
/// directions and terrain context, so changing them blindly could make a
/// briefing internally inconsistent.
public enum DrillRandomizer {

    public static func vary(_ drills: [Drill]) -> [Drill] {
        drills.map(vary)
    }

    public static func vary(_ drill: Drill) -> Drill {
        var d = drill
        let subs = substitutions(for: drill)
        for (from, to) in subs {
            d.setup = d.setup.replacingOccurrences(of: from, with: to)
            d.situation = d.situation.replacingOccurrences(of: from, with: to)
        }
        return d
    }

    // MARK: - Substitution builders

    private static func substitutions(for drill: Drill) -> [(String, String)] {
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
