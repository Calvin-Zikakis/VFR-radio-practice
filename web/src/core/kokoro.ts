// Optional in-browser neural TTS (Kokoro-82M via kokoro-js / transformers.js).
// Opt-in from the home screen: downloads the model once (~80 MB, cached by the
// browser) so the voice is high-quality and reliable in every browser with no
// server. Loaded lazily via dynamic import, so it never touches — or bloats the
// bundle for — users who don't enable it. Every entry point is failure-safe: on
// any error the caller falls back to the Worker voice, then the browser voice.

let ttsPromise: Promise<any> | null = null;
let ready = false;
let loading = false;

export function kokoroReady(): boolean {
  return ready;
}
export function kokoroLoading(): boolean {
  return loading;
}

/** Download + initialize the model (idempotent). onProgress reports 0–1. */
export async function loadKokoro(onProgress?: (fraction: number) => void): Promise<void> {
  if (ready) return;
  if (!ttsPromise) {
    loading = true;
    ttsPromise = (async () => {
      const mod: any = await import("kokoro-js");
      const files: Record<string, { loaded: number; total: number }> = {};
      const tts = await mod.KokoroTTS.from_pretrained("onnx-community/Kokoro-82M-v1.0-ONNX", {
        dtype: "q8",
        device: "wasm",
        progress_callback: (info: any) => {
          if (info?.status === "progress" && info.file && info.total) {
            files[info.file] = { loaded: info.loaded ?? 0, total: info.total };
            let loaded = 0;
            let total = 0;
            for (const f of Object.values(files)) {
              loaded += f.loaded;
              total += f.total;
            }
            if (total && onProgress) onProgress(Math.min(1, loaded / total));
          }
        },
      });
      ready = true;
      loading = false;
      return tts;
    })();
    ttsPromise.catch(() => {
      loading = false;
      ttsPromise = null; // allow a retry on the next enable
    });
  }
  await ttsPromise;
}

const VOICE = "af_heart"; // a clear, natural default

/** Synthesize text to a WAV Blob, or null if the model isn't loaded. */
export async function kokoroSpeak(text: string): Promise<Blob | null> {
  if (!ready || !ttsPromise) return null;
  const tts = await ttsPromise;
  const audio = await tts.generate(text, { voice: VOICE });
  return audio.toBlob() as Blob;
}
