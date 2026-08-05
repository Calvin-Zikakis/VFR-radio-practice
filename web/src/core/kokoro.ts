// Optional in-browser neural TTS (Kokoro-82M). Opt-in from the home screen:
// downloads the model once (~80 MB, cached) so the voice is high-quality and
// reliable in every browser with no server. The heavy inference runs in a Web
// Worker (see kokoro.worker.ts) so it never freezes the UI. The worker chunk —
// which carries kokoro-js / transformers.js — is only created on opt-in, so it
// never touches or bloats the experience for users who don't enable it. Every
// entry point is failure-safe: on any error the caller falls back to the Worker
// voice, then the browser voice.

let worker: Worker | null = null;
let ready = false;
let loading = false;
let seq = 0;
const pending = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();
let statusCb: ((text: string) => void) | null = null;
let lastStatus = "";
const files: Record<string, { loaded: number; total: number }> = {};

function emit(text: string) {
  lastStatus = text;
  statusCb?.(text);
}

export function kokoroReady(): boolean {
  return ready;
}
export function kokoroLoading(): boolean {
  return loading;
}
/** The current load phase text (e.g. "Downloading… 42%"), for a re-rendered UI. */
export function kokoroStatus(): string {
  return lastStatus;
}

function ensureWorker(): Worker {
  if (!worker) {
    worker = new Worker(new URL("./kokoro.worker.ts", import.meta.url), { type: "module" });
    worker.onmessage = (e: MessageEvent) => {
      const m = e.data;
      if (m.type === "progress") {
        files[m.file] = { loaded: m.loaded, total: m.total };
        let loaded = 0;
        let total = 0;
        for (const f of Object.values(files)) {
          loaded += f.loaded;
          total += f.total;
        }
        if (total) emit(`Downloading… ${Math.round((loaded / total) * 100)}%`);
      } else if (m.type === "warming") {
        emit("Preparing voice…");
      } else if (m.type === "ready") {
        ready = true;
        loading = false;
        lastStatus = "";
        pending.get(m.id)?.resolve(undefined);
        pending.delete(m.id);
      } else if (m.type === "audio") {
        pending.get(m.id)?.resolve(m.buf);
        pending.delete(m.id);
      } else if (m.type === "error") {
        pending.get(m.id)?.reject(new Error(m.message));
        pending.delete(m.id);
      }
    };
  }
  return worker;
}

/** Download + initialize + warm the model in the worker (idempotent). onStatus
 *  reports human-readable phases ("Downloading… 42%", "Preparing voice…"). */
export async function loadKokoro(onStatus?: (text: string) => void): Promise<void> {
  if (ready) return;
  loading = true;
  statusCb = onStatus ?? null;
  const w = ensureWorker();
  const id = ++seq;
  try {
    await new Promise<void>((resolve, reject) => {
      pending.set(id, { resolve, reject });
      w.postMessage({ type: "load", id });
    });
  } catch (e) {
    loading = false;
    throw e;
  }
}

// The generate request currently in flight, if any — a new call supersedes it
// (see kokoroSpeak). Skipping several drills in a row should speak only the
// last one, not queue all of them up back to back.
let currentGenerateId: number | null = null;

/** Synthesize text to a WAV Blob in the worker, or null if not loaded / if
 *  superseded by a newer call before the worker got to it. */
export async function kokoroSpeak(text: string): Promise<Blob | null> {
  if (!ready || !worker) return null;
  // Abandon whatever was still in flight — resolve it as "no audio" right
  // away so its caller doesn't sit waiting on a stale drill, and the worker
  // drops it too if it hadn't started running yet.
  if (currentGenerateId !== null) {
    pending.get(currentGenerateId)?.resolve(null);
    pending.delete(currentGenerateId);
  }
  const id = ++seq;
  currentGenerateId = id;
  const buf: ArrayBuffer | null = await new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    worker!.postMessage({ type: "generate", id, text });
  });
  if (currentGenerateId === id) currentGenerateId = null;
  return buf ? new Blob([buf], { type: "audio/wav" }) : null;
}
