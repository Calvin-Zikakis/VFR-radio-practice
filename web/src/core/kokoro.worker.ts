// Kokoro TTS runs here, OFF the main thread — the ONNX/WASM inference is heavy
// enough that on the main thread it triggers the browser's "page is slowing
// things down" warning. The main thread talks to this worker via postMessage.

/// <reference lib="webworker" />
import { KokoroTTS } from "kokoro-js";

const ctx: DedicatedWorkerGlobalScope = self as unknown as DedicatedWorkerGlobalScope;

let ttsPromise: Promise<any> | null = null;

ctx.onmessage = async (e: MessageEvent) => {
  const { type, id, text } = e.data ?? {};
  try {
    if (type === "load") {
      if (!ttsPromise) {
        ttsPromise = KokoroTTS.from_pretrained("onnx-community/Kokoro-82M-v1.0-ONNX", {
          dtype: "q8",
          device: "wasm",
          progress_callback: (info: any) => {
            if (info?.status === "progress" && info.file && info.total) {
              ctx.postMessage({
                type: "progress",
                file: info.file,
                loaded: info.loaded ?? 0,
                total: info.total,
              });
            }
          },
        });
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
