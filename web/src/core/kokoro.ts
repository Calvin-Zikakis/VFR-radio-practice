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
let progressCb: ((fraction: number) => void) | null = null;
const files: Record<string, { loaded: number; total: number }> = {};

export function kokoroReady(): boolean {
  return ready;
}
export function kokoroLoading(): boolean {
  return loading;
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
        if (total && progressCb) progressCb(Math.min(1, loaded / total));
      } else if (m.type === "ready") {
        ready = true;
        loading = false;
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

/** Download + initialize the model in the worker (idempotent). onProgress 0–1. */
export async function loadKokoro(onProgress?: (fraction: number) => void): Promise<void> {
  if (ready) return;
  loading = true;
  progressCb = onProgress ?? null;
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

/** Synthesize text to a WAV Blob in the worker, or null if not loaded. */
export async function kokoroSpeak(text: string): Promise<Blob | null> {
  if (!ready || !worker) return null;
  const id = ++seq;
  const buf: ArrayBuffer = await new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    worker!.postMessage({ type: "generate", id, text });
  });
  return new Blob([buf], { type: "audio/wav" });
}
