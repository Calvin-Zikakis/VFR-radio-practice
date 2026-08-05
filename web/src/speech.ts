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

/** Speak text, resolving when the utterance finishes. A watchdog guarantees it
 *  always resolves even if the browser never fires `onend`. */
export function speak(text: string, voice: Voice = "controller"): Promise<void> {
  const trimmed = text.replace(/[{}[\]]/g, "").trim();
  if (!trimmed) return Promise.resolve();
  return new Promise((resolve) => {
    try {
      speechSynthesis.cancel();
      const u = new SpeechSynthesisUtterance(trimmed);
      const v = bestVoice();
      if (v) u.voice = v;
      u.rate = voice === "controller" ? 1.02 : 0.98;
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
}
