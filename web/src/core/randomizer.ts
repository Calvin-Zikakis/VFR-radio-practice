// Port of DrillRandomizer.swift — varies incidental details (ATIS letter,
// distances, squawk codes, runways, altitudes, taxiway letters) so repeated
// sessions can't be answered from memory. Substitutions are applied identically
// to setup (spoken) and situation (grader) so they never disagree. Runway and
// altitude are decided once per session so a whole trip stays coherent.

import type { Airport, Drill } from "./types";
import { spokenRunway } from "./trip";
import { bareCallsign, shortCallsign } from "./aircraft";

type Sub = [string, string];

function pick<T>(xs: T[]): T {
  return xs[Math.floor(Math.random() * xs.length)];
}
function shuffle<T>(xs: T[]): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Vary a whole session: one runway decision per airport, one altitude offset. */
export function vary(drills: Drill[]): Drill[] {
  const runwayChoice: Record<string, string | null> = {};
  for (const d of drills) {
    if (!(d.airport.icao in runwayChoice)) runwayChoice[d.airport.icao] = pickRunway(d.airport);
  }
  const altitudeOffset = pick([0, 1000, 2000]);
  return drills.map((d) => varyOne(d, runwayChoice[d.airport.icao] ?? null, altitudeOffset));
}

function pickRunway(airport: Airport): string | null {
  const primary = airport.runwaysInUse[0];
  const alternates = alternateRunways[airport.icao];
  if (!primary || !alternates) return null;
  const choice = pick([primary, ...alternates]);
  return choice === primary ? null : choice;
}

function varyOne(drill: Drill, runway: string | null, altitudeOffset: number): Drill {
  const d: Drill = {
    ...drill,
    airport: { ...drill.airport, runwaysInUse: [...drill.airport.runwaysInUse] },
  };
  // Resolve this session's authored instruction/amendment BEFORE substituting,
  // so one pass rewrites setup, situation, instruction, and amendment together.
  if (d.instruction == null && d.instructionVariants?.length) d.instruction = pick(d.instructionVariants);
  if (d.amendment == null && d.amendmentVariants?.length) d.amendment = pick(d.amendmentVariants);

  // Identity mappings FIRST: shield every form of the flown callsign from all
  // later substitutions (taxiway letters and runway/number words live inside it).
  const cs = drill.aircraft.phoneticCallsign;
  const subs: Sub[] = [[cs, cs]];
  const bare = bareCallsign(drill.aircraft);
  if (bare !== cs) subs.push([bare, bare]);
  const short = shortCallsign(drill.aircraft);
  if (short !== cs && short !== bare) subs.push([short, short]);

  const primary = drill.airport.runwaysInUse[0];
  if (runway && primary && runway !== primary && !runwaySwapExempt.has(drill.id)) {
    subs.push([spokenRunway(primary), spokenRunway(runway)]);
    subs.push([primary, runway]);
    d.airport.runwaysInUse = drill.airport.runwaysInUse.map((r) => (r === primary ? runway : r));
  }

  if (altitudeOffset !== 0) subs.push(...altitudeSubstitutions(altitudeOffset));
  subs.push(...incidentalSubstitutions(d));
  subs.push(...taxiwaySubstitutions(d));

  d.setup = applying(subs, d.setup);
  d.situation = applying(subs, d.situation);
  if (d.radioOpener != null) d.radioOpener = applying(subs, d.radioOpener);
  if (d.instruction != null) d.instruction = applying(subs, d.instruction);
  if (d.amendment != null) d.amendment = applying(subs, d.amendment);
  return d;
}

/** Apply all pairs simultaneously via unique placeholders, so one pair's output
 *  can't be re-matched by a later pair (e.g. 2,500→3,500 then 3,500→4,500). */
function applying(subs: Sub[], text: string): string {
  let t = text;
  subs.forEach((pair, i) => {
    if (pair[0]) t = t.split(pair[0]).join(`${i}`);
  });
  subs.forEach((pair, i) => {
    t = t.split(`${i}`).join(pair[1]);
  });
  return t;
}

// ---- Runways ------------------------------------------------------------

const runwaySwapExempt = new Set(["t-lahso", "t-sns-taxi", "t-lvk-taxi"]);

// Verified against AirNav (FAA), 2026-07. KMRY/KRHV excluded: their drills name
// more than one runway, so a blind swap would corrupt them.
const alternateRunways: Record<string, string[]> = {
  KWVI: ["2", "9", "27"],
  KPAO: ["13"],
  E16: ["14"],
  KCVH: ["13", "6", "24"],
  KSNS: ["13", "8", "26"],
  KLVK: ["7L", "7R", "25L"],
  KHAF: ["12"],
  KSQL: ["12"],
  KOAR: ["11"],
};

// ---- Altitudes ----------------------------------------------------------

const altitudeFeet = [2500, 3500, 4500, 6500];

function altitudeSubstitutions(offset: number): Sub[] {
  const out: Sub[] = [];
  for (const alt of altitudeFeet) {
    const to = alt + offset;
    out.push([spokenAltitude(alt), spokenAltitude(to)]);
    out.push([digitsAltitude(alt), digitsAltitude(to)]);
  }
  return out;
}

function spokenAltitude(feet: number): string {
  const thousands = ["one", "two", "three", "four", "five", "six", "seven", "eight", "niner"];
  const t = Math.floor(feet / 1000);
  const word = t >= 1 && t <= 9 ? thousands[t - 1] : String(t);
  return feet % 1000 === 500 ? `${word} thousand five hundred` : `${word} thousand`;
}

function digitsAltitude(feet: number): string {
  return `${Math.floor(feet / 1000)},${String(feet % 1000).padStart(3, "0")}`;
}

// ---- Incidental (ATIS, distance, squawk) --------------------------------

function scannableText(d: Drill): string {
  return `${d.setup} ${d.situation} ${d.radioOpener ?? ""} ${d.instruction ?? ""} ${d.amendment ?? ""}`;
}

function incidentalSubstitutions(d: Drill): Sub[] {
  const subs: Sub[] = [];
  const text = scannableText(d);

  const current = atisLetters.find(
    (l) => text.includes(`information ${l}`) || text.includes(`ATIS ${l}`)
  );
  if (current) {
    const replacement = pick(atisLetters.filter((l) => l !== current)) ?? current;
    subs.push([`information ${current}`, `information ${replacement}`]);
    subs.push([`ATIS ${current}`, `ATIS ${replacement}`]);
  }

  if (
    text.includes("10 miles") ||
    text.includes("ten miles") ||
    directions.some((dir) => text.includes(`10 ${dir}`))
  ) {
    const n = pick([7, 8, 9, 11, 12, 15]);
    subs.push(["ten miles", `${n} miles`]);
    subs.push(["10 miles", `${n} miles`]);
    for (const dir of directions) subs.push([`10 ${dir}`, `${n} ${dir}`]);
  }

  if (text.includes("four five two one") || text.includes("4521")) {
    const code = randomSquawk();
    subs.push(["four five two one", spokenSquawk(code)]);
    subs.push(["4521", code]);
  }
  return subs;
}

// ---- Taxiways -----------------------------------------------------------

const taxiwayVaried = new Set([
  "t-ccr-parallel-taxi", "t-ccr-runway-switch", "t-ccr-holdshort-request",
  "t-ccr-taxiback", "t-ccr-runway-change", "t-ccr-long-route", "t-ccr-crossing-revoked",
]);
const taxiwaySources = ["juliet", "papa", "alpha", "echo", "hotel", "golf", "foxtrot", "kilo"];
const taxiwayPalette = [
  "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "kilo", "mike",
  "november", "papa", "romeo", "sierra", "tango", "victor", "whiskey", "yankee", "zulu",
];

function taxiwaySubstitutions(d: Drill): Sub[] {
  if (!taxiwayVaried.has(d.id)) return [];
  const text = scannableText(d);
  const callsignWords = new Set(d.aircraft.phoneticCallsign.toLowerCase().split(" "));
  const present = taxiwaySources.filter((s) => text.includes(s) && !callsignWords.has(s));
  if (!present.length) return [];
  const pool = shuffle(taxiwayPalette.filter((w) => !callsignWords.has(w)));
  const out: Sub[] = [];
  for (const source of present) {
    const repl = pool.pop();
    if (repl) out.push([source, repl]);
  }
  return out;
}

// ---- Pools --------------------------------------------------------------

const atisLetters = [
  "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India",
  "Juliet", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo",
  "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "X-ray", "Yankee", "Zulu",
];
const directions = ["north", "south", "east", "west"];
const reservedSquawks = new Set(["1200", "7500", "7600", "7700", "7777", "0000"]);

function randomSquawk(): string {
  let code: string;
  do {
    code = Array.from({ length: 4 }, () => "01234567"[Math.floor(Math.random() * 8)]).join("");
  } while (reservedSquawks.has(code));
  return code;
}
function spokenSquawk(code: string): string {
  const w: Record<string, string> = {
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven",
  };
  return code.split("").map((c) => w[c]).filter(Boolean).join(" ");
}
