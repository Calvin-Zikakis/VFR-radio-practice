// Per-call-type pass/fail tally, persisted across sessions in localStorage.
// Feeds the Progress view and the "weak spots" mix builder.

import type { CallType } from "./types";

export type Stats = Partial<Record<CallType, { pass: number; fail: number }>>;

const KEY = "vfr.web.stats.v1";

export function loadStats(): Stats {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return JSON.parse(raw) as Stats;
  } catch {
    /* ignore */
  }
  return {};
}

function save(s: Stats) {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}

export function recordResult(type: CallType, pass: boolean) {
  const s = loadStats();
  const e = s[type] ?? { pass: 0, fail: 0 };
  if (pass) e.pass += 1;
  else e.fail += 1;
  s[type] = e;
  save(s);
}

export function resetStats() {
  save({});
}
