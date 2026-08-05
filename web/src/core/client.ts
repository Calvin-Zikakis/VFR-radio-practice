// Talks to the Claude Messages API — either directly from the browser with the
// user's own key (bring-your-own), or through the shared Cloudflare Worker that
// holds the class key server-side. Mirrors the request shape of iOS ATCBrain.

import type { Drill, GradingMode, Difficulty, Turn, Verdict } from "./types";
import { systemPrompt, verdictSchema } from "./prompt";
import { cleanVerdict, DegenerateVerdictError } from "./verdict";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
/** Match the iOS app's model choice so grading behaves identically. */
export const DEFAULT_MODEL = "claude-sonnet-5";
export const MODELS = ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-8"];

/** Carries the HTTP status so grade() can decide whether to retry. */
class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "ApiError";
  }
}

export type KeyMode =
  | { kind: "byo"; apiKey: string }
  | { kind: "shared"; workerUrl: string; passcode: string };

export interface GraderConfig {
  key: KeyMode;
  model: string;
  difficulty: Difficulty;
}

function requestBody(
  drill: Drill,
  mode: GradingMode,
  difficulty: Difficulty,
  model: string,
  history: Turn[],
  transmission: string,
  nextSetup: string | null
): unknown {
  const messages: { role: string; content: string }[] = [];
  for (const turn of history) {
    messages.push({
      role: "user",
      content: `[earlier transmission, already graded] ${turn.pilot}`,
    });
    messages.push({
      role: "assistant",
      content: turn.reply.length ? turn.reply : "(no radio reply was due)",
    });
  }
  messages.push({
    role: "user",
    content: `[transmission to grade now] ${transmission}`,
  });

  return {
    model,
    max_tokens: 8000,
    thinking: { type: "disabled" },
    system: [
      {
        type: "text",
        text: systemPrompt(drill, mode, difficulty, nextSetup),
        cache_control: { type: "ephemeral" },
      },
    ],
    messages,
    output_config: { format: { type: "json_schema", schema: verdictSchema } },
  };
}

async function post(
  config: GraderConfig,
  body: unknown,
  signal: AbortSignal
): Promise<Response> {
  if (config.key.kind === "byo") {
    return fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": config.key.apiKey.trim(),
        "anthropic-version": "2023-06-01",
        // Required for direct browser calls; the key is the user's own.
        "anthropic-dangerous-direct-browser-access": "true",
      },
      body: JSON.stringify(body),
      signal,
    });
  }
  // Shared mode: the Worker injects the key; we send only the passcode.
  return fetch(config.key.workerUrl, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-class-passcode": config.key.passcode.trim(),
    },
    body: JSON.stringify(body),
    signal,
  });
}

function parseVerdict(root: any): Verdict {
  if (root?.stop_reason === "refusal")
    throw new Error("The grader declined the request.");
  if (root?.stop_reason === "max_tokens")
    throw new DegenerateVerdictError("truncated");
  const block = (root?.content ?? []).find((b: any) => b?.type === "text");
  if (!block?.text) throw new Error("Grader returned no text.");
  let text = String(block.text).trim();
  if (text.startsWith("```")) {
    text = text.replace(/```json/g, "").replace(/```/g, "").trim();
  }
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start !== -1 && end > start) text = text.slice(start, end + 1);
  let decoded: Verdict;
  try {
    decoded = JSON.parse(text) as Verdict;
  } catch {
    throw new Error("Grader reply wasn't valid JSON.");
  }
  return cleanVerdict(decoded);
}

async function sendOnce(config: GraderConfig, body: unknown): Promise<Verdict> {
  const controller = new AbortController();
  // Preempt Cloudflare's ~100s 524 while allowing a genuinely slow grade.
  const timer = setTimeout(() => controller.abort(), 45000);
  let res: Response;
  try {
    res = await post(config, body, controller.signal);
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    if (res.status === 429)
      throw new ApiError(
        429,
        "Rate limited — the shared key is busy. Try again in a moment, or add your own key in Settings."
      );
    throw new ApiError(res.status, `API error ${res.status}: ${errText.slice(0, 200)}`);
  }
  const json = await res.json();
  return parseVerdict(json);
}

/** Grade one transmission. Retries once on a degenerate sample or timeout. */
export async function grade(
  config: GraderConfig,
  drill: Drill,
  mode: GradingMode,
  history: Turn[],
  transmission: string,
  nextSetup: string | null
): Promise<Verdict> {
  const body = requestBody(
    drill,
    mode,
    config.difficulty,
    config.model,
    history,
    transmission,
    nextSetup
  );
  try {
    return await sendOnce(config, body);
  } catch (e) {
    const retryable =
      e instanceof DegenerateVerdictError ||
      (e instanceof DOMException && e.name === "AbortError") ||
      (e instanceof ApiError && (e.status >= 500 || e.status === 429));
    if (retryable) return await sendOnce(config, body);
    throw e;
  }
}

// ----------------------------------------------------- Voice (Worker-backed)
// STT/TTS run on the Cloudflare Worker (Workers AI). Available only in shared
// mode with a Worker URL + passcode; BYO mode falls back to browser speech.

function workerBase(config: GraderConfig): string {
  if (config.key.kind !== "shared") return "";
  return config.key.workerUrl.trim().replace(/\/+$/, "");
}

/** True when the shared Worker is configured for voice (URL + passcode set). */
export function workerVoiceConfigured(config: GraderConfig): boolean {
  return (
    config.key.kind === "shared" &&
    workerBase(config).length > 0 &&
    config.key.passcode.trim().length > 0
  );
}

async function voiceFetch(url: string, init: RequestInit): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30000);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/** POST to a Worker voice route, retrying transient 5xx/429/timeout up to 3x.
 *  Workers AI (esp. MeloTTS) intermittently fails a call on the free tier. */
async function voiceRequest(
  url: string,
  headers: Record<string, string>,
  body: BodyInit
): Promise<Response> {
  let last: Response | null = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await voiceFetch(url, { method: "POST", headers, body });
      if (res.ok || (res.status < 500 && res.status !== 429)) return res;
      last = res;
    } catch {
      /* timeout / network — retry */
    }
  }
  if (last) return last;
  throw new Error("Voice request failed (network or timeout).");
}

/** Transcribe recorded audio via the Worker's /stt (Whisper). */
export async function transcribe(config: GraderConfig, audio: Blob): Promise<string> {
  if (config.key.kind !== "shared") throw new Error("Voice needs the class Worker.");
  const res = await voiceRequest(
    `${workerBase(config)}/stt`,
    {
      "content-type": audio.type || "application/octet-stream",
      "x-class-passcode": config.key.passcode.trim(),
    },
    audio
  );
  if (!res.ok) {
    if (res.status === 429) throw new Error("Voice is busy — try again in a moment.");
    const detail = await res.text().catch(() => "");
    throw new Error(`Transcription failed (${res.status})${detail ? ": " + detail.slice(0, 300) : ""}`);
  }
  const json = await res.json();
  return String(json?.text ?? "").trim();
}

/** Synthesize speech via the Worker's /tts (MeloTTS). Returns an mp3 Blob. */
export async function synthesize(
  config: GraderConfig,
  text: string
): Promise<Blob | null> {
  if (config.key.kind !== "shared") return null;
  const res = await voiceRequest(
    `${workerBase(config)}/tts`,
    {
      "content-type": "application/json",
      "x-class-passcode": config.key.passcode.trim(),
    },
    JSON.stringify({ text })
  );
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`Speech failed (${res.status})${detail ? ": " + detail.slice(0, 300) : ""}`);
  }
  const json = await res.json();
  const b64 = String(json?.audio ?? "");
  if (!b64) return null;
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return new Blob([bytes], { type: "audio/mpeg" });
}
