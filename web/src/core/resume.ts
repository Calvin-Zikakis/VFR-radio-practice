// Persist an in-progress session so it can be resumed after exiting. The
// snapshot holds the resolved drills, position, and current-drill history — not
// the API key (that lives in settings and is re-attached on resume).

import type { GradingMode } from "./types";
import type { SessionSnapshot } from "./session";

export interface ResumeData {
  snap: SessionSnapshot;
  mode: GradingMode;
  log: { label: string; pass: boolean; coaching: string; corrections: string[] }[];
  savedAt: number;
  index: number;
  total: number;
  title: string;
}

const KEY = "vfr.web.resume.v1";

export function saveResume(d: ResumeData) {
  try {
    localStorage.setItem(KEY, JSON.stringify(d));
  } catch {
    /* ignore */
  }
}

export function loadResume(): ResumeData | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as ResumeData) : null;
  } catch {
    return null;
  }
}

export function clearResume() {
  try {
    localStorage.removeItem(KEY);
  } catch {
    /* ignore */
  }
}
