// Wire-format mirror of Packages/VFRCore/Sources/VFRCore/Models.swift.
// The drill DATA is generated from Swift (drills.generated.json); these types
// describe its shape. Keep them in sync with the Swift structs — the generator
// dump is the contract.

export type ScenarioType = "untowered" | "towered" | "flightFollowing";

export type CallType =
  | "taxi"
  | "departure"
  | "arrival"
  | "pattern"
  | "readback"
  | "flightFollowing"
  | "advisory"
  | "bravo"
  | "afterLanding"
  | "emergency";

export interface Aircraft {
  callsign: string;
  phoneticCallsign: string;
  type: string;
}

export interface Airport {
  icao: string;
  name: string;
  ctafOrTower: string;
  elevationFt: number;
  runwaysInUse: string[];
  isTowered: boolean;
}

export interface Drill {
  id: string;
  scenario: ScenarioType;
  title: string;
  setup: string;
  situation: string;
  /** ATC-initiated drills: the controller's opening call, shown as its own radio
   *  line after the scene. Null when the pilot speaks first. */
  radioOpener?: string | null;
  aircraft: Aircraft;
  airport: Airport;
  callType?: CallType | null;
  followUpReadback?: boolean | null;
  instructionVariants?: string[] | null;
  instruction?: string | null;
  injectedReadback?: boolean | null;
  amendmentVariants?: string[] | null;
  amendment?: string | null;
  /** A second exchange chained after the readback chain completes, starting
   *  from a NEW scene (time passed, position changed) rather than a
   *  same-frequency continuation. See `FollowUpScene`. */
  followUpScene?: FollowUpScene | null;
}

/** A scene-and-exchange chained after a drill's initial readback chain
 *  completes — see `Drill.followUpScene`. */
export interface FollowUpScene {
  setup: string;
  situation: string;
  title: string;
  callType?: CallType | null;
  instructionVariants?: string[] | null;
  instruction?: string | null;
}

export interface Verdict {
  heard: string;
  speaker: string;
  radioReplyText: string;
  correct: boolean;
  corrections: string[];
  expectedExample: string;
  phaseAdvance: boolean;
  coaching: string;
}

export type GradingMode = "live" | "debrief";
export type Difficulty = "student" | "checkride" | "rapidFire";

/** One completed exchange, for multi-step drill context. */
export interface Turn {
  pilot: string;
  reply: string;
}

export interface DrillBundle {
  generatedAt: string;
  drills: Drill[];
  fleet: Aircraft[];
  defaultAircraft: Aircraft;
  routableAirports: Airport[];
  defaultTripStops: Airport[];
}
