import Foundation
import VFRCore

/// Per-call-type pass/fail tallies across all sessions, persisted in
/// UserDefaults. Drives the "weak spots" mix and lightweight progress display.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    struct Tally: Codable {
        var passed = 0
        var failed = 0
        var attempts: Int { passed + failed }
        var failRate: Double { attempts == 0 ? 0 : Double(failed) / Double(attempts) }
    }

    @Published private(set) var tallies: [String: Tally]

    private let defaults = UserDefaults.standard
    private static let key = "callTypeStats"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: Tally].self, from: data) {
            tallies = saved
        } else {
            tallies = [:]
        }
    }

    func record(callType: CallType, passed: Bool) {
        var t = tallies[callType.rawValue] ?? Tally()
        if passed { t.passed += 1 } else { t.failed += 1 }
        tallies[callType.rawValue] = t
        if let data = try? JSONEncoder().encode(tallies) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func tally(for callType: CallType) -> Tally? { tallies[callType.rawValue] }

    /// The call types you miss most, worst first. Only types you've actually
    /// attempted and missed at least once qualify.
    func weakestCallTypes(limit: Int = 3) -> [CallType] {
        CallType.allCases
            .compactMap { type -> (CallType, Tally)? in
                guard let t = tallies[type.rawValue], t.failed > 0 else { return nil }
                return (type, t)
            }
            .sorted { $0.1.failRate > $1.1.failRate }
            .prefix(limit)
            .map(\.0)
    }

    var hasWeakSpots: Bool { !weakestCallTypes(limit: 1).isEmpty }

    func reset() {
        tallies = [:]
        defaults.removeObject(forKey: Self.key)
    }
}
