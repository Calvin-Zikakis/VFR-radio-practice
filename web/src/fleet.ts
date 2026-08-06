// The planes you can fly, and editing them. Mirrors the iOS fleet editor.
//
// The built-in fleet ships in the generated drill data. A user's custom fleet
// lives in settings and starts empty, meaning "just use the built-ins" — the
// first edit materializes the full list so a built-in plane can be renamed or
// removed like any other.

import { fleet as builtInFleet, defaultAircraft } from "./core/drills";
import type { Aircraft } from "./core/types";
import type { Settings } from "./settings";

/** The planes available to fly. Never empty. */
export function activeFleet(s: Settings): Aircraft[] {
  return s.fleet.length ? s.fleet : builtInFleet;
}

/** The airplane for this session: the pinned one, a random one ("all"), or the
 *  default. Falls back through the active fleet so a stale `aircraft` setting —
 *  a plane since renamed or deleted — can't strand the session on a plane that
 *  no longer exists. */
export function chosenAircraft(s: Settings): Aircraft {
  const planes = activeFleet(s);
  if (s.aircraft === "all") return planes[Math.floor(Math.random() * planes.length)];
  return (
    planes.find((a) => a.callsign === s.aircraft) ??
    planes.find((a) => a.callsign === defaultAircraft.callsign) ??
    planes[0]
  );
}

/** Add a plane, or replace `replacing` when editing an existing one. Returns the
 *  new fleet; the caller stores it and persists. */
export function upsertAircraft(
  s: Settings,
  plane: Aircraft,
  replacing?: string
): Aircraft[] {
  const planes = [...activeFleet(s)];
  const at = replacing
    ? planes.findIndex((a) => a.callsign === replacing)
    : planes.findIndex((a) => a.callsign === plane.callsign);
  if (at >= 0) planes[at] = plane;
  else planes.push(plane);
  return planes;
}

/** Drop a plane. Deleting the last one restores the built-ins rather than
 *  leaving you with nothing to fly. */
export function removeAircraft(s: Settings, callsign: string): Aircraft[] {
  const planes = activeFleet(s).filter((a) => a.callsign !== callsign);
  return planes.length ? planes : [...builtInFleet];
}

const DIGITS: Record<string, string> = {
  "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
  "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "niner",
};
const NATO: Record<string, string> = {
  A: "alpha", B: "bravo", C: "charlie", D: "delta", E: "echo", F: "foxtrot",
  G: "golf", H: "hotel", I: "india", J: "juliet", K: "kilo", L: "lima",
  M: "mike", N: "november", O: "oscar", P: "papa", Q: "quebec", R: "romeo",
  S: "sierra", T: "tango", U: "uniform", V: "victor", W: "whiskey",
  X: "x-ray", Y: "yankee", Z: "zulu",
};

/** A starting point for the spoken callsign, from the tail number. A leading
 *  "N" becomes "November" — the pilot then edits the prefix to whatever they
 *  actually say ("RV", "Skyhawk", "Cirrus"). */
export function suggestPhonetic(callsign: string): string {
  const words: string[] = [];
  const chars = [...callsign.trim().toUpperCase()];
  chars.forEach((ch, i) => {
    if (i === 0 && ch === "N") words.push("November");
    else if (DIGITS[ch]) words.push(DIGITS[ch]);
    else if (NATO[ch]) words.push(NATO[ch]);
  });
  return words.join(" ");
}
