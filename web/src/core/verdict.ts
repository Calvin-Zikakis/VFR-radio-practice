// Port of the verdict-cleaning logic in ATCBrain.parseVerdict — scrubbing,
// sentinel collapse, leaked-JSON stripping, stub/contradiction handling.

import type { Verdict } from "./types";

const SENTINELS = new Set([
  "n/a",
  "na",
  "n.a.",
  "placeholder",
  "null",
  "-",
  "--",
  "unknown",
  "tbd",
]);

/** Strip invisible padding (zero-width spaces) and outer whitespace. */
export function scrub(s: string): string {
  let t = s;
  for (const ghost of ["​", "‌", "‍", "﻿", "⁠"]) {
    t = t.split(ghost).join("");
  }
  return t.trim();
}

/** Collapse sentinel filler ("n/a", "placeholder") to empty. */
export function meaningful(s: string): string {
  return SENTINELS.has(s.toLowerCase()) ? "" : s;
}

/** Cut leaked structured-output syntax at the earliest marker. */
export function stripLeaked(s: string): string {
  let cut = s.length;
  for (const marker of ["```", "','", "->", "{", "}", "[", "]"]) {
    const i = s.indexOf(marker);
    if (i !== -1 && i < cut) cut = i;
  }
  let t = s.slice(0, cut);
  while (t.length && ":.,;-'`\" ".includes(t[t.length - 1])) t = t.slice(0, -1);
  return t.trim();
}

export class DegenerateVerdictError extends Error {}

/** Clean + validate a raw decoded verdict. Throws DegenerateVerdictError on a
 *  stub the caller should retry. Contradiction clamps are applied here; the
 *  crossing/hold-short pending-readback clamp lives in the session (it needs the
 *  drill). */
export function cleanVerdict(raw: Verdict): Verdict {
  const v: Verdict = { ...raw };
  v.heard = stripLeaked(meaningful(scrub(v.heard)));
  v.speaker = scrub(v.speaker);
  v.radioReplyText = stripLeaked(meaningful(scrub(v.radioReplyText)));
  v.expectedExample = stripLeaked(meaningful(scrub(v.expectedExample)));
  v.coaching = stripLeaked(meaningful(scrub(v.coaching)));
  v.corrections = (v.corrections ?? [])
    .map((c) => stripLeaked(meaningful(scrub(c))))
    .filter((c) => c.length > 0);

  const stub =
    v.heard.length === 0 ||
    (!v.correct &&
      v.coaching.length === 0 &&
      v.corrections.length === 0 &&
      v.expectedExample.length === 0 &&
      v.radioReplyText.length === 0);
  if (stub) throw new DegenerateVerdictError("stub verdict");

  // Advancing on an incorrect call is never right — hold the step.
  if (v.phaseAdvance && !v.correct) v.phaseAdvance = false;

  return v;
}
