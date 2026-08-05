// Local, in-browser settings. The BYO key never leaves the browser; shared mode
// stores only the class passcode (the key lives in the Worker).

import type { Difficulty } from "./core/types";
import { DEFAULT_MODEL } from "./core/client";

export interface Settings {
  keyMode: "shared" | "byo";
  apiKey: string; // BYO only
  passcode: string; // shared only
  workerUrl: string; // shared only
  model: string;
  difficulty: Difficulty;
  speakReplies: boolean;
  speechRate: number; // 0.7–1.4, applies to controller/scene voices
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
  speakReplies: true,
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
