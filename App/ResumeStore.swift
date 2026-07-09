import Foundation
import VFRCore

/// A resumable picture of an in-flight practice session. Saved after every
/// turn, so quitting the app mid-session loses nothing; the home screen offers
/// to pick up where you left off.
struct SessionSnapshot: Codable {
    struct LineRecord: Codable {
        var role: String   // HandsFreeController.Line.Role, stringly for Codable
        var text: String
    }

    var label: String                  // e.g. "Untowered (CTAF)" or "Trip: WVI → PAO"
    var mode: GradingMode
    var drills: [Drill]                // exact drills incl. randomized details
    var drillIndex: Int
    var aircraft: Aircraft
    var debrief: [PracticeSession.DebriefEntry]
    var transcript: [LineRecord]
    var savedAt: Date

    var progressText: String { "Drill \(min(drillIndex + 1, drills.count)) of \(drills.count)" }
}

/// UserDefaults-backed persistence for the single in-flight session.
enum ResumeStore {
    private static let key = "sessionSnapshot"

    static func save(_ snapshot: SessionSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              snap.drillIndex < snap.drills.count   // finished sessions aren't resumable
        else { return nil }
        return snap
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
