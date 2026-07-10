import Foundation

/// Timestamped console logging — millisecond wall-clock stamps so device logs
/// can prove ordering and gaps (e.g. how long the recognizer sat silent while
/// the pilot was still talking).
public func vfrLog(_ message: String) {
    print("VFR \(VFRLogClock.stamp()): \(message)")
}

enum VFRLogClock {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func stamp() -> String { formatter.string(from: Date()) }
}
