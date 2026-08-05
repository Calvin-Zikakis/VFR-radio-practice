// Loads the generated drill bundle and provides selection by call type.

import bundle from "./drills.generated.json";
import type { Drill, DrillBundle, CallType } from "./types";
import { callType } from "./session";

const data = bundle as unknown as DrillBundle;

export const allDrills: Drill[] = data.drills;
export const generatedAt = data.generatedAt;
export const routableAirports = data.routableAirports;
export const defaultAircraft = data.defaultAircraft;
export const fleet = data.fleet;
export const defaultTripStops = data.defaultTripStops;

export interface Category {
  type: CallType;
  label: string;
}

export const CATEGORIES: Category[] = [
  { type: "taxi", label: "Ground / Taxi" },
  { type: "departure", label: "Departure" },
  { type: "arrival", label: "Arrival" },
  { type: "pattern", label: "Pattern work" },
  { type: "readback", label: "Readbacks" },
  { type: "flightFollowing", label: "Flight following" },
  { type: "advisory", label: "Traffic advisory" },
  { type: "bravo", label: "Airspace (B/C/D)" },
  { type: "afterLanding", label: "After landing" },
  { type: "emergency", label: "Emergencies" },
];

function shuffle<T>(xs: T[]): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Shuffled drills matching any of the given call types. */
export function drillsMatching(types: Set<CallType>): Drill[] {
  return shuffle(allDrills.filter((d) => types.has(callType(d))));
}

export function categoryCount(type: CallType): number {
  return allDrills.filter((d) => callType(d) === type).length;
}
