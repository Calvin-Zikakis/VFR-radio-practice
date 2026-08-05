import Foundation
import VFRCore

// Dumps the drill library + fleet + routable airports to JSON on stdout, so the
// web client reads exactly what the iOS app compiles. Regenerate after editing
// any drill: `web/scripts/generate-drills.sh` (runs this and writes the file).
//
// The `Drill`/`Aircraft`/`Airport` Codable conformances are the wire format;
// the TypeScript engine mirrors these shapes in web/src/core/types.ts.
struct DrillBundle: Codable {
    let generatedAt: String
    let drills: [Drill]
    let fleet: [Aircraft]
    let defaultAircraft: Aircraft
    let routableAirports: [Airport]
    let defaultTripStops: [Airport]
}

let bundle = DrillBundle(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    drills: DrillLibrary.all,
    fleet: DrillLibrary.fleet,
    defaultAircraft: DrillLibrary.defaultAircraft,
    routableAirports: DrillLibrary.routableAirports,
    defaultTripStops: DrillLibrary.defaultTripStops
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(bundle))
FileHandle.standardOutput.write(Data("\n".utf8))
