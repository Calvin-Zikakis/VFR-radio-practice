// Local, in-browser settings. The BYO key never leaves the browser; shared mode
// stores only the class passcode (the key lives in the Worker).

import type { Difficulty, GradingMode } from "./core/types";
import { DEFAULT_MODEL } from "./core/client";

export interface Settings {
  keyMode: "shared" | "byo";
  apiKey: string; // BYO only
  passcode: string; // shared only
  workerUrl: string; // shared only
  model: string;
  difficulty: Difficulty;
  gradingMode: GradingMode; // live coaching vs debrief at end
  aircraft: string; // fleet callsign to fly, "all" for random, "" for default
  randomize: boolean; // vary ATIS/runway/altitude/squawk per session
  echoModelCall: boolean; // read the ideal call aloud after a miss (shadow)
  busyFrequency: boolean; // background chatter + occasional stepped-on call
  kokoroEnabled: boolean; // opt-in in-browser neural voice (downloads ~80 MB)
  // Per-role volumes (0–1); 0 mutes that role (on-screen only). The radio/
  // controller reply is always audible. Mirrors the iOS app.
  sceneVolume: number; // the scene/setup voice
  instructorVolume: number; // coaching + "read it back" prompt, after your call
  passNotesVolume: number; // polish notes on PASSED calls (default off)
  speechRate: number; // 0.7–1.4, applies to all spoken voices
  instructorName: string; // label shown for the coaching voice
  theme: "system" | "light" | "dark";
}

const KEY = "vfr.web.settings.v1";

const DEFAULTS: Settings = {
  keyMode: "byo",
  apiKey: "",
  passcode: "",
  // Set at build time via VITE_WORKER_URL for the deployed "try it" mode.
  workerUrl: (import.meta.env.VITE_WORKER_URL as string) ?? "",
  model: DEFAULT_MODEL,
  difficulty: "checkride",
  gradingMode: "live",
  aircraft: "",
  randomize: true,
  echoModelCall: false,
  busyFrequency: false,
  kokoroEnabled: false,
  sceneVolume: 1,
  instructorVolume: 0,
  passNotesVolume: 0,
  speechRate: 1,
  instructorName: "Instructor",
  theme: "system",
};

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return { ...DEFAULTS, ...JSON.parse(raw) };
  } catch {
    /* ignore */
  }
  // If a Worker URL is configured at build time, default new users to shared.
  return { ...DEFAULTS, keyMode: DEFAULTS.workerUrl ? "shared" : "byo" };
}

export function saveSettings(s: Settings) {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}
