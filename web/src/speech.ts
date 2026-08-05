// Thin wrappers over the browser's Web Speech APIs: SpeechRecognition for
// push-to-talk input and speechSynthesis for the controller/instructor voices.
// Best in Chrome/Firefox (desktop + Android); iOS Safari recognition is
// unreliable, so the UI always offers a typed fallback.

type SRCtor = { new (): SpeechRecognition };

function recognitionCtor(): SRCtor | null {
  return (window.SpeechRecognition ??
    (window as any).webkitSpeechRecognition ??
    null) as SRCtor | null;
}

export const recognitionSupported = recognitionCtor() !== null;

/** One-shot push-to-talk capture. `onPartial` streams interim text; the promise
 *  resolves with the final transcript when `stop()` is called or speech ends. */
export function startListening(
  onPartial: (text: string) => void
): { stop: () => void; result: Promise<string> } {
  const Ctor = recognitionCtor();
  if (!Ctor) {
    return {
      stop: () => {},
      result: Promise.reject(new Error("Speech recognition not supported here.")),
    };
  }
  const rec = new Ctor();
  rec.lang = "en-US";
  rec.interimResults = true;
  rec.continuous = true;

  let finalText = "";
  let settled = false;
  let resolve!: (s: string) => void;
  let reject!: (e: Error) => void;
  const result = new Promise<string>((res, rej) => {
    resolve = res;
    reject = rej;
  });

  rec.onresult = (ev: SpeechRecognitionEvent) => {
    let interim = "";
    finalText = "";
    for (let i = 0; i < ev.results.length; i++) {
      const r = ev.results[i];
      if (r.isFinal) finalText += r[0].transcript;
      else interim += r[0].transcript;
    }
    onPartial((finalText + " " + interim).trim());
  };
  rec.onerror = (ev: any) => {
    if (settled) return;
    if (ev.error === "no-speech" || ev.error === "aborted") {
      settled = true;
      resolve(finalText.trim());
    } else {
      settled = true;
      reject(new Error(ev.error || "recognition error"));
    }
  };
  rec.onend = () => {
    if (settled) return;
    settled = true;
    resolve(finalText.trim());
  };

  try {
    rec.start();
  } catch (e) {
    settled = true;
    reject(e as Error);
  }

  return {
    stop: () => {
      try {
        rec.stop();
      } catch {
        /* ignore */
      }
    },
    result,
  };
}

let cachedVoice: SpeechSynthesisVoice | null = null;
function bestVoice(): SpeechSynthesisVoice | null {
  if (cachedVoice) return cachedVoice;
  const voices = speechSynthesis.getVoices().filter((v) => v.lang.startsWith("en"));
  cachedVoice =
    voices.find((v) => /en-US/i.test(v.lang)) ?? voices[0] ?? null;
  return cachedVoice;
}

export type Voice = "controller" | "scene" | "instructor";

// Global speech rate multiplier (0.7–1.4), set from Settings. Applies to both
// the browser voice and the Worker's audio clips.
let speechRate = 1;
export function setSpeechRate(r: number) {
  speechRate = Math.max(0.5, Math.min(2, r || 1));
}

/** Speak text, resolving when the utterance finishes. A watchdog guarantees it
 *  always resolves even if the browser never fires `onend`. */
export function speak(text: string, voice: Voice = "controller", volume = 1): Promise<void> {
  const trimmed = text.replace(/[{}[\]]/g, "").trim();
  if (!trimmed || volume <= 0.001) return Promise.resolve();
  return new Promise((resolve) => {
    try {
      speechSynthesis.cancel();
      const u = new SpeechSynthesisUtterance(trimmed);
      const v = bestVoice();
      if (v) u.voice = v;
      u.volume = Math.max(0, Math.min(1, volume));
      u.rate = Math.min(2, (voice === "controller" ? 1.02 : 0.98) * speechRate);
      u.pitch = voice === "instructor" ? 1.05 : 1.0;
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        resolve();
      };
      u.onend = finish;
      u.onerror = finish;
      const words = Math.max(1, trimmed.split(/\s+/).length);
      setTimeout(finish, words * 450 + 4000);
      speechSynthesis.speak(u);
    } catch {
      resolve();
    }
  });
}

export function stopSpeaking() {
  try {
    speechSynthesis.cancel();
  } catch {
    /* ignore */
  }
  stopClip();
}

// -------------------------------------------------------- WAV mic capture
// For the Worker/Whisper path we capture 16-bit PCM WAV (16 kHz mono) — the
// format Whisper reliably decodes — via Web Audio, rather than MediaRecorder's
// webm/opus which Whisper may reject. Works in Chrome, Firefox, and Safari.

export interface Recorder {
  stop: () => Promise<Blob>;
  cancel: () => void;
}

export async function startRecording(): Promise<Recorder> {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const AC: typeof AudioContext =
    window.AudioContext ?? (window as any).webkitAudioContext;
  if (!AC) {
    stream.getTracks().forEach((t) => t.stop());
    throw new Error("Audio capture not supported here.");
  }
  const ctx = new AC();
  const source = ctx.createMediaStreamSource(stream);
  const processor = ctx.createScriptProcessor(4096, 1, 1);
  const mute = ctx.createGain();
  mute.gain.value = 0; // keep the graph running without echoing the mic
  const chunks: Float32Array[] = [];
  processor.onaudioprocess = (e) => {
    chunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
  };
  source.connect(processor);
  processor.connect(mute);
  mute.connect(ctx.destination);
  const inRate = ctx.sampleRate;

  const teardown = () => {
    processor.onaudioprocess = null;
    try {
      processor.disconnect();
      source.disconnect();
      mute.disconnect();
    } catch {
      /* ignore */
    }
    stream.getTracks().forEach((t) => t.stop());
    ctx.close().catch(() => {});
  };
  return {
    stop: async () => {
      teardown();
      return new Blob([encodeWav(chunks, inRate, 16000)], { type: "audio/wav" });
    },
    cancel: teardown,
  };
}

function flatten(chunks: Float32Array[]): Float32Array {
  let len = 0;
  for (const c of chunks) len += c.length;
  const out = new Float32Array(len);
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.length;
  }
  return out;
}

function downsample(buf: Float32Array, inRate: number, outRate: number): Float32Array {
  const ratio = inRate / outRate;
  const newLen = Math.max(1, Math.round(buf.length / ratio));
  const out = new Float32Array(newLen);
  let iOff = 0;
  for (let o = 0; o < newLen; o++) {
    const next = Math.round((o + 1) * ratio);
    let sum = 0;
    let count = 0;
    for (let i = iOff; i < next && i < buf.length; i++) {
      sum += buf[i];
      count++;
    }
    out[o] = count ? sum / count : 0;
    iOff = next;
  }
  return out;
}

function encodeWav(chunks: Float32Array[], inRate: number, outRate: number): ArrayBuffer {
  const flat = flatten(chunks);
  const samples = outRate < inRate ? downsample(flat, inRate, outRate) : flat;
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const writeStr = (off: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i));
  };
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true); // PCM chunk size
  view.setUint16(20, 1, true); // PCM format
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, outRate, true);
  view.setUint32(28, outRate * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  writeStr(36, "data");
  view.setUint32(40, samples.length * 2, true);
  let off = 44;
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    off += 2;
  }
  return buffer;
}

// -------------------------------------------------------- Clip playback (TTS)
let currentClip: HTMLAudioElement | null = null;

/** Play an audio Blob (the Worker's TTS mp3), resolving when it finishes. */
export function playClip(blob: Blob, rate = speechRate, volume = 1): Promise<void> {
  if (volume <= 0.001) return Promise.resolve();
  return new Promise((resolve) => {
    stopClip();
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    audio.playbackRate = rate;
    audio.volume = Math.max(0, Math.min(1, volume));
    currentClip = audio;
    const done = () => {
      URL.revokeObjectURL(url);
      if (currentClip === audio) currentClip = null;
      resolve();
    };
    audio.onended = done;
    audio.onerror = done;
    audio.play().catch(done);
  });
}

export function stopClip() {
  if (currentClip) {
    try {
      currentClip.pause();
    } catch {
      /* ignore */
    }
    currentClip = null;
  }
}
