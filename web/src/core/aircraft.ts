// Callsign helpers + drill retargeting (port of DrillLibrary.retarget). Lets a
// whole session fly one chosen airplane: swaps the aircraft and rewrites every
// quoted callsign form in the drill text (setup/situation/instruction/amendment)
// — many drills quote ATC addressing the pilot, which must match the plane flown.

import type { Aircraft, Drill } from "./types";

const digitWords = new Set([
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "niner", "nine",
]);

/** The phonetic without its type prefix ("RV …" → "…"). Unchanged if it starts
 *  straight into digits (no prefix). */
export function bareCallsign(a: Aircraft): string {
  const words = a.phoneticCallsign.split(" ");
  if (!words.length || digitWords.has(words[0].toLowerCase())) return a.phoneticCallsign;
  return words.slice(1).join(" ");
}

/** The last three spoken words — the abbreviated callsign ATC uses. */
export function shortCallsign(a: Aircraft): string {
  const words = a.phoneticCallsign.split(" ");
  return words.length < 3 ? a.phoneticCallsign : words.slice(-3).join(" ");
}

export function retarget(drill: Drill, plane: Aircraft): Drill {
  const old = drill.aircraft;
  const d: Drill = { ...drill, aircraft: plane };
  if (old.callsign === plane.callsign) return d;

  const subs: [string, string][] = [
    [old.phoneticCallsign, plane.phoneticCallsign],
    [bareCallsign(old), bareCallsign(plane)],
    [shortCallsign(old), shortCallsign(plane)],
    [old.callsign, plane.callsign],
  ];
  // Tail number without the leading N ("737JA") appears in a few texts.
  if (old.callsign.startsWith("N") && plane.callsign.startsWith("N")) {
    subs.push([old.callsign.slice(1), plane.callsign.slice(1)]);
  }
  const rewrite = (s: string): string => {
    let t = s;
    for (const [from, to] of subs) if (from && from !== to) t = t.split(from).join(to);
    return t;
  };

  d.setup = rewrite(d.setup);
  d.situation = rewrite(d.situation);
  if (d.radioOpener != null) d.radioOpener = rewrite(d.radioOpener);
  if (d.instruction != null) d.instruction = rewrite(d.instruction);
  if (d.instructionVariants) d.instructionVariants = d.instructionVariants.map(rewrite);
  if (d.amendment != null) d.amendment = rewrite(d.amendment);
  if (d.amendmentVariants) d.amendmentVariants = d.amendmentVariants.map(rewrite);
  d.followUpScenes = d.followUpScenes?.map((scene) => ({
    ...scene,
    setup: rewrite(scene.setup),
    situation: rewrite(scene.situation),
    instruction: scene.instruction != null ? rewrite(scene.instruction) : scene.instruction,
    instructionVariants: scene.instructionVariants?.map(rewrite),
  }));
  return d;
}
