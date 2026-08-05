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
  aircraft: Aircraft;
  airport: Airport;
  callType?: CallType | null;
  followUpReadback?: boolean | null;
  instructionVariants?: string[] | null;
  instruction?: string | null;
  injectedReadback?: boolean | null;
  amendmentVariants?: string[] | null;
  amendment?: string | null;
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
