// Kokoro TTS runs here, OFF the main thread — the ONNX/WASM inference is heavy
// enough that on the main thread it triggers the browser's "page is slowing
// things down" warning. The main thread talks to this worker via postMessage.
//
// Two latency fixes: prefer WebGPU when the browser has it (far faster than the
// single-threaded WASM you get on a static host), and WARM UP the model right
// after load with a throwaway generation — the first inference pays a big
// one-time cost, so we spend it during setup, not on the first spoken line.

/// <reference lib="webworker" />
import { KokoroTTS } from "kokoro-js";
import { env } from "@huggingface/transformers";

const ctx: DedicatedWorkerGlobalScope = self as unknown as DedicatedWorkerGlobalScope;
const MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";

// Multi-threaded WASM: only possible when the page is crossOriginIsolated
// (COOP/COEP, set by coi-serviceworker.js). Each thread roughly halves inference
// time up to the core count, which is the big win on Firefox/Safari where there's
// no WebGPU. Set before any model session is created; harmless on the WebGPU path.
if ((ctx as any).crossOriginIsolated && env.backends.onnx.wasm) {
  const cores = ctx.navigator?.hardwareConcurrency ?? 4;
  env.backends.onnx.wasm.numThreads = Math.max(2, Math.min(cores, 8));
}

let ttsPromise: Promise<any> | null = null;

function progress_callback(info: any) {
  if (info?.status === "progress" && info.file && info.total) {
    ctx.postMessage({ type: "progress", file: info.file, loaded: info.loaded ?? 0, total: info.total });
  }
}

async function build(): Promise<any> {
  const hasGPU = "gpu" in (ctx.navigator ?? {});
  if (hasGPU) {
    try {
      return await KokoroTTS.from_pretrained(MODEL, {
        dtype: "fp32",
        device: "webgpu",
        progress_callback,
      });
    } catch {
      /* WebGPU unavailable/failed — fall back to WASM (files are cached). */
    }
  }
  return await KokoroTTS.from_pretrained(MODEL, { dtype: "q8", device: "wasm", progress_callback });
}

// Only ONE tts.generate() may run at a time: onnxruntime-web's threaded WASM
// backend spins up real worker threads per inference, so overlapping calls
// (e.g. the user spamming "skip") multiply that thread count and crash the
// tab. If a new request arrives while one is running, it REPLACES whatever
// was queued next — we only ever care about the latest request, never a
// backlog of stale ones from drills the pilot has already skipped past.
let busy = false;
let queued: { id: number; text: string } | null = null;

// TEMPORARY diagnostic logging (see also kokoro.ts and main.ts) — helps
// pin down where a skip-spam delay is actually coming from. Cheap to leave
// in; remove once the skip-lag report is resolved.
function log(msg: string) {
  console.log(`[kokoro-worker ${performance.now().toFixed(0)}ms] ${msg}`);
}

async function runGenerate(id: number, text: string) {
  busy = true;
  const t0 = performance.now();
  log(`generate START id=${id}`);
  try {
    const tts = await ttsPromise;
    const audio = await tts.generate(text, { voice: "af_heart" });
    const buf: ArrayBuffer = audio.toWav();
    log(`generate DONE id=${id} took ${(performance.now() - t0).toFixed(0)}ms`);
    ctx.postMessage({ type: "audio", id, buf }, [buf]); // transfer, zero-copy
  } catch (err: any) {
    log(`generate ERROR id=${id} took ${(performance.now() - t0).toFixed(0)}ms: ${err}`);
    ctx.postMessage({ type: "error", id, message: String(err?.message ?? err) });
  } finally {
    busy = false;
    if (queued) {
      const next = queued;
      queued = null;
      log(`starting queued id=${next.id}`);
      runGenerate(next.id, next.text);
    }
  }
}

ctx.onmessage = async (e: MessageEvent) => {
  const { type, id, text } = e.data ?? {};
  try {
    if (type === "load") {
      if (!ttsPromise) {
        ttsPromise = (async () => {
          const tts = await build();
          ctx.postMessage({ type: "warming" });
          try {
            await tts.generate("Radio check.", { voice: "af_heart" }); // warm the session
          } catch {
            /* warmup is best-effort */
          }
          return tts;
        })();
      }
      await ttsPromise;
      ctx.postMessage({ type: "ready", id });
    } else if (type === "generate") {
      if (busy) {
        if (queued) log(`DROPPING superseded queued id=${queued.id} (replaced by id=${id})`);
        else log(`QUEUING id=${id} — busy with another generate()`);
        queued = { id, text }; // supersedes anything previously queued
      } else {
        runGenerate(id, text);
      }
    }
  } catch (err: any) {
    ctx.postMessage({ type: "error", id, message: String(err?.message ?? err) });
  }
};
