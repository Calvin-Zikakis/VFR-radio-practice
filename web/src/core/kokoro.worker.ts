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

const ctx: DedicatedWorkerGlobalScope = self as unknown as DedicatedWorkerGlobalScope;
const MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";

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
      const tts = await ttsPromise;
      const audio = await tts.generate(text, { voice: "af_heart" });
      const buf: ArrayBuffer = audio.toWav();
      ctx.postMessage({ type: "audio", id, buf }, [buf]); // transfer, zero-copy
    }
  } catch (err: any) {
    ctx.postMessage({ type: "error", id, message: String(err?.message ?? err) });
  }
};
