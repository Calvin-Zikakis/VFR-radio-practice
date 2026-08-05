import "./styles.css";
import { CATEGORIES, categoryCount, drillsMatching, generatedAt } from "./core/drills";
import { PracticeSession } from "./core/session";
import type { CallType, Verdict } from "./core/types";
import { MODELS, workerVoiceConfigured, transcribe, synthesize } from "./core/client";
import type { GraderConfig, KeyMode } from "./core/client";
import { loadSettings, saveSettings, type Settings } from "./settings";
import {
  recognitionSupported,
  startListening,
  speak,
  stopSpeaking,
  startRecording,
  playClip,
  setSpeechRate,
  type Recorder,
  type Voice,
} from "./speech";

const app = document.getElementById("app")!;
let settings = loadSettings();
let session: PracticeSession | null = null;
let listening: { stop: () => void } | null = null;
// Worker/Whisper capture state (used when the shared Worker is configured).
let recorder: Recorder | null = null;
let startingRecorder = false;
let stopRequested = false;
// Recomputed per session: true if the mic works via the browser OR the Worker.
let voiceInputAvailable = false;

function graderConfig(): GraderConfig {
  const key: KeyMode =
    settings.keyMode === "byo"
      ? { kind: "byo", apiKey: settings.apiKey }
      : { kind: "shared", workerUrl: settings.workerUrl, passcode: settings.passcode };
  return { key, model: settings.model, difficulty: settings.difficulty };
}

function keyReady(): boolean {
  return settings.keyMode === "byo"
    ? settings.apiKey.trim().length > 0
    : settings.workerUrl.trim().length > 0 && settings.passcode.trim().length > 0;
}

function el(tag: string, cls?: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  // Buttons default to type="submit". With a password field on the page,
  // Chrome's password manager then reads a button press as a login-form submit
  // — popping "save password" and stealing the press from push-to-talk. We
  // never submit a form, so force type="button".
  if (tag === "button") (e as HTMLButtonElement).type = "button";
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

// ---------------------------------------------------------------- Home

function renderHome() {
  stopSpeaking();
  session = null;
  app.innerHTML = "";

  const header = el("header", "topbar");
  header.append(el("div", "brand", "VFR Radio — Practice"));
  const gear = el("button", "ghost", "⚙ Settings");
  gear.onclick = renderSettings;
  header.append(gear);
  app.append(header);

  const intro = el(
    "p",
    "muted",
    "Practice VFR radio calls out loud. Pick a category, make the call, get graded."
  );
  app.append(intro);

  if (!keyReady()) {
    const warn = el(
      "div",
      "notice",
      settings.keyMode === "byo"
        ? "Add your Anthropic API key in Settings to start."
        : "Enter the class passcode in Settings to start."
    );
    app.append(warn);
  }

  const grid = el("div", "grid");
  for (const cat of CATEGORIES) {
    const n = categoryCount(cat.type);
    if (n === 0) continue;
    const tile = el("button", "tile") as HTMLButtonElement;
    tile.append(el("div", "tile-title", cat.label));
    tile.append(el("div", "tile-count", `${n} drill${n === 1 ? "" : "s"}`));
    tile.disabled = !keyReady();
    tile.onclick = () => startSession(new Set([cat.type]));
    grid.append(tile);
  }
  app.append(grid);

  const mixBtn = el("button", "ghost mixlink", "＋  Build a mix of several types →") as HTMLButtonElement;
  mixBtn.disabled = !keyReady();
  mixBtn.onclick = renderMix;
  app.append(mixBtn);

  const foot = el("footer", "foot");
  const built = new Date(generatedAt);
  foot.append(
    el(
      "span",
      "muted",
      `Open source · drills generated ${isNaN(built.getTime()) ? "" : built.toLocaleDateString()}`
    )
  );
  app.append(foot);
}

// ------------------------------------------------------------- Mix builder

function renderMix() {
  stopSpeaking();
  app.innerHTML = "";
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Back");
  back.onclick = renderHome;
  header.append(back);
  header.append(el("div", "brand", "Build a mix"));
  app.append(header);

  app.append(
    el(
      "p",
      "muted",
      "Pick the call types to practice. Drills from every selected type are shuffled into one session."
    )
  );

  const selected = new Set<CallType>();
  const summary = el("div", "notice");
  const startBtn = el("button", "primary", "Start mix") as HTMLButtonElement;

  const refresh = () => {
    let total = 0;
    selected.forEach((t) => (total += categoryCount(t)));
    summary.textContent = selected.size
      ? `${total} drill${total === 1 ? "" : "s"} from ${selected.size} type${selected.size === 1 ? "" : "s"}`
      : "Select at least one type.";
    startBtn.disabled = selected.size === 0;
  };

  const grid = el("div", "grid");
  for (const cat of CATEGORIES) {
    const n = categoryCount(cat.type);
    if (n === 0) continue;
    const tile = el("button", "tile") as HTMLButtonElement;
    tile.append(el("div", "tile-title", cat.label));
    tile.append(el("div", "tile-count", `${n} drill${n === 1 ? "" : "s"}`));
    tile.onclick = () => {
      if (selected.has(cat.type)) {
        selected.delete(cat.type);
        tile.classList.remove("sel");
      } else {
        selected.add(cat.type);
        tile.classList.add("sel");
      }
      refresh();
    };
    grid.append(tile);
  }
  app.append(grid);
  app.append(summary);

  startBtn.onclick = () => {
    if (selected.size) startSession(new Set(selected));
  };
  app.append(startBtn);
  refresh();
}

// ---------------------------------------------------------------- Session

function startSession(types: Set<CallType>) {
  const drills = drillsMatching(types);
  if (drills.length === 0) {
    renderHome();
    return;
  }
  session = new PracticeSession(drills, graderConfig());
  renderSession();
  briefCurrent();
}

let transcriptEl: HTMLElement;
let sceneEl: HTMLElement;
let statusEl: HTMLElement;
let talkBtn: HTMLButtonElement;
let textInput: HTMLTextAreaElement;

function renderSession() {
  app.innerHTML = "";
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Exit");
  back.onclick = renderHome;
  header.append(back);
  const prog = session!.progress;
  header.append(el("div", "brand", `Drill ${prog.index + 1} of ${prog.total}`));
  const skip = el("button", "ghost", "Skip ›");
  skip.onclick = skipCurrent;
  header.append(skip);
  app.append(header);

  sceneEl = el("div", "scene");
  app.append(sceneEl);

  transcriptEl = el("div", "transcript");
  app.append(transcriptEl);

  statusEl = el("div", "status muted");
  app.append(statusEl);

  // Voice input works via the browser (Chrome/Android) OR the Worker (Whisper,
  // which also covers Firefox/Safari). Enable the button if either is available.
  voiceInputAvailable = recognitionSupported || workerVoiceConfigured(graderConfig());
  const controls = el("div", "controls");
  talkBtn = el("button", "talk") as HTMLButtonElement;
  talkBtn.textContent = voiceInputAvailable
    ? "🎙 Hold to talk"
    : "🎙 Voice unavailable — type below";
  talkBtn.disabled = !voiceInputAvailable;
  if (voiceInputAvailable) {
    // Pointer events (mouse + touch + pen, unified) with capture so the release
    // always fires even if the cursor/finger drifts off the button mid-hold.
    // preventDefault keeps the press from focusing the button (which could
    // summon autofill) or starting a text selection / scroll.
    talkBtn.style.touchAction = "none";
    talkBtn.onpointerdown = (e) => {
      e.preventDefault();
      try {
        talkBtn.setPointerCapture(e.pointerId);
      } catch {
        /* ignore */
      }
      beginTalk();
    };
    const release = (e: PointerEvent) => {
      e.preventDefault();
      try {
        talkBtn.releasePointerCapture(e.pointerId);
      } catch {
        /* ignore */
      }
      endTalk();
    };
    talkBtn.onpointerup = release;
    talkBtn.onpointercancel = release;
  }
  controls.append(talkBtn);

  const typed = el("div", "typed");
  textInput = el("textarea", "text") as HTMLTextAreaElement;
  textInput.placeholder = "…or type your radio call and press Send";
  textInput.rows = 2;
  const send = el("button", "primary", "Send");
  send.onclick = () => {
    const t = textInput.value.trim();
    if (t) {
      addLine("you", t);
      textInput.value = "";
      submit(t);
    }
  };
  textInput.onkeydown = (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) send.click();
  };
  typed.append(textInput, send);
  controls.append(typed);
  app.append(controls);
}

type Role = "scene" | "instructor" | "you" | "radio" | "note";
function addLine(role: Role, text: string) {
  const line = el("div", `line ${role}`);
  const labels: Record<Role, string> = {
    scene: "Scene",
    instructor: settings.instructorName.trim() || "Instructor",
    you: "You",
    radio: "Radio",
    note: "Note",
  };
  line.append(el("div", "line-role", labels[role]));
  line.append(el("div", "line-text", text));
  transcriptEl.append(line);
  transcriptEl.scrollTop = transcriptEl.scrollHeight;
}

async function briefCurrent() {
  const drill = session!.currentDrill;
  if (!drill) {
    finish();
    return;
  }
  sceneEl.textContent = drill.setup;
  if (drill.injectedReadback === true) {
    addLine("instructor", drill.setup);
  } else {
    addLine("scene", drill.setup);
    await say(drill.setup, "scene");
  }
  status("Make your call.");
}

function status(s: string) {
  statusEl.textContent = s;
}

/** Speak text aloud, honoring the Speak setting. Uses the Worker's TTS when
 *  configured (good voice in every browser), else browser speechSynthesis. */
async function say(text: string, role: Voice) {
  if (!settings.speakReplies) return;
  const cfg = graderConfig();
  if (workerVoiceConfigured(cfg)) {
    try {
      const clip = await synthesize(cfg, text);
      if (clip) {
        await playClip(clip);
        return;
      }
    } catch {
      /* fall back to the browser voice below */
    }
  }
  await speak(text, role);
}

async function beginTalk() {
  if (listening || recorder || startingRecorder) return;
  const cfg = graderConfig();
  if (workerVoiceConfigured(cfg)) {
    // Worker/Whisper path: record now, transcribe on release.
    startingRecorder = true;
    stopRequested = false;
    status("Listening…");
    talkBtn.classList.add("live");
    try {
      const r = await startRecording();
      if (stopRequested) {
        // Released before the recorder was ready — capture what we have.
        await finishWorkerCapture(await r.stop());
      } else {
        recorder = r;
      }
    } catch (e: any) {
      talkBtn.classList.remove("live");
      status(`Mic error: ${e.message}. Type your call instead.`);
    } finally {
      startingRecorder = false;
    }
    return;
  }
  beginBrowserListen();
}

/** Browser SpeechRecognition path (Chrome/Android): streams partials. */
function beginBrowserListen() {
  status("Listening…");
  talkBtn.classList.add("live");
  let partial = "";
  const handle = startListening((t) => {
    partial = t;
    status(t || "Listening…");
  });
  listening = { stop: () => handle.stop() };
  handle.result
    .then((finalText) => {
      const said = (finalText || partial).trim();
      talkBtn.classList.remove("live");
      listening = null;
      if (said) {
        addLine("you", said);
        submit(said);
      } else {
        status("Didn't catch that — hold the button and try again, or type it.");
      }
    })
    .catch((e) => {
      talkBtn.classList.remove("live");
      listening = null;
      status(`Mic error: ${e.message}. Type your call instead.`);
    });
}

async function finishWorkerCapture(blob: Blob) {
  talkBtn.classList.remove("live");
  status("Transcribing…");
  try {
    const said = await transcribe(graderConfig(), blob);
    if (said) {
      addLine("you", said);
      submit(said);
    } else {
      status("Didn't catch that — hold the button and try again, or type it.");
    }
  } catch (e: any) {
    status(`Voice error: ${e.message}. Type your call instead.`);
  }
}

async function endTalk() {
  if (startingRecorder) {
    stopRequested = true;
    return;
  }
  if (recorder) {
    const r = recorder;
    recorder = null;
    await finishWorkerCapture(await r.stop());
    return;
  }
  if (listening) listening.stop();
}

async function submit(text: string) {
  if (!session) return;
  status("Grading…");
  talkBtn.disabled = true;
  try {
    const result = await session.submit(text);
    if (!result) {
      finish();
      return;
    }
    showVerdict(result.verdict);
    if (result.spokenInstruction) {
      addLine("radio", result.spokenInstruction);
      await say(result.spokenInstruction, "controller");
    } else if (result.verdict.radioReplyText) {
      addLine("radio", `${result.verdict.speaker}: ${result.verdict.radioReplyText}`);
      await say(result.verdict.radioReplyText, "controller");
    }
    if (result.verdict.phaseAdvance) {
      if (result.finished) {
        finish();
      } else {
        renderSessionHeaderProgress();
        briefCurrent();
      }
    } else {
      status("Try that again.");
    }
  } catch (e: any) {
    status("");
    addLine("note", `⚠️ ${e.message}`);
  } finally {
    if (voiceInputAvailable) talkBtn.disabled = false;
  }
}

function renderSessionHeaderProgress() {
  const brand = app.querySelector(".topbar .brand");
  if (brand && session) {
    const p = session.progress;
    brand.textContent = `Drill ${p.index + 1} of ${p.total}`;
  }
}

function showVerdict(v: Verdict) {
  if (v.heard) addLine("note", `Heard: ${v.heard}`);
  if (v.correct || v.phaseAdvance) {
    if (v.coaching) addLine("note", `✓ ${v.coaching}`);
  } else {
    if (v.coaching) addLine("instructor", v.coaching);
    for (const c of v.corrections) addLine("note", `• ${c}`);
    if (v.expectedExample) addLine("note", `Model call: ${v.expectedExample}`);
  }
}

function skipCurrent() {
  if (listening) listening.stop();
  stopSpeaking();
  if (!session) return;
  session.skip();
  if (session.isFinished) {
    finish();
    return;
  }
  renderSessionHeaderProgress();
  briefCurrent();
}

function finish() {
  stopSpeaking();
  app.innerHTML = "";
  const header = el("header", "topbar");
  header.append(el("div", "brand", "Session complete"));
  app.append(header);
  app.append(el("p", "muted", "Nice work. Ready for another round?"));
  const home = el("button", "primary", "Back to categories");
  home.onclick = renderHome;
  app.append(home);
}

// ---------------------------------------------------------------- Settings

function renderSettings() {
  stopSpeaking();
  app.innerHTML = "";
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Back");
  back.onclick = renderHome;
  header.append(back);
  header.append(el("div", "brand", "Settings"));
  app.append(header);

  const form = el("div", "form");

  // Key mode
  form.append(el("label", "field-label", "How you're grading"));
  const modeRow = el("div", "seg");
  const sharedBtn = el("button", settings.keyMode === "shared" ? "seg-on" : "seg-off", "Class passcode");
  const byoBtn = el("button", settings.keyMode === "byo" ? "seg-on" : "seg-off", "My own key");
  sharedBtn.onclick = () => {
    settings.keyMode = "shared";
    persist();
    renderSettings();
  };
  byoBtn.onclick = () => {
    settings.keyMode = "byo";
    persist();
    renderSettings();
  };
  modeRow.append(sharedBtn, byoBtn);
  form.append(modeRow);

  if (settings.keyMode === "shared") {
    form.append(
      el(
        "p",
        "muted small",
        "Uses the class's shared account for grading and voice. Ask your CFI for the passcode; the server URL is usually preset."
      )
    );
    form.append(
      textField("Class server URL (Worker)", settings.workerUrl, (v) => (settings.workerUrl = v.trim()))
    );
    form.append(textField("Class passcode", settings.passcode, (v) => (settings.passcode = v), "password"));
    form.append(
      el(
        "p",
        "muted small",
        "With the Worker set, voice (mic + spoken replies) works in every browser — including Firefox and Safari."
      )
    );
  } else {
    form.append(
      el(
        "p",
        "muted small",
        "Your key stays in this browser and calls Claude directly. Get one at console.anthropic.com (Billing → add ~$5 credit → API Keys)."
      )
    );
    form.append(textField("Anthropic API key", settings.apiKey, (v) => (settings.apiKey = v), "password"));
  }

  // Model
  form.append(el("label", "field-label", "Grader model"));
  const modelSel = el("select", "select") as HTMLSelectElement;
  for (const m of MODELS) {
    const o = el("option", undefined, m) as HTMLOptionElement;
    o.value = m;
    if (m === settings.model) o.selected = true;
    modelSel.append(o);
  }
  modelSel.onchange = () => {
    settings.model = modelSel.value;
    persist();
  };
  form.append(modelSel);
  form.append(el("p", "muted small", "Sonnet 5 is the default (best balance). Haiku is cheaper/faster; Opus is strictest."));

  // Difficulty
  form.append(el("label", "field-label", "Difficulty"));
  const diffSel = el("select", "select") as HTMLSelectElement;
  for (const [v, label] of [
    ["student", "Student — patient, lenient"],
    ["checkride", "Checkride — FAA standard"],
    ["rapidFire", "Rapid-fire — busy & strict"],
  ] as const) {
    const o = el("option", undefined, label) as HTMLOptionElement;
    o.value = v;
    if (v === settings.difficulty) o.selected = true;
    diffSel.append(o);
  }
  diffSel.onchange = () => {
    settings.difficulty = diffSel.value as Settings["difficulty"];
    persist();
  };
  form.append(diffSel);

  // Speak toggle
  const speakRow = el("label", "checkrow");
  const cb = el("input") as HTMLInputElement;
  cb.type = "checkbox";
  cb.checked = settings.speakReplies;
  cb.onchange = () => {
    settings.speakReplies = cb.checked;
    persist();
  };
  speakRow.append(cb, el("span", undefined, "Speak the scene and controller replies aloud"));
  form.append(speakRow);

  // Speech speed
  form.append(el("label", "field-label", "Speech speed"));
  const speedRow = el("div", "sliderrow");
  const speed = el("input") as HTMLInputElement;
  speed.type = "range";
  speed.min = "0.7";
  speed.max = "1.4";
  speed.step = "0.05";
  speed.value = String(settings.speechRate);
  const speedVal = el("span", "muted small", `${settings.speechRate.toFixed(2)}×`);
  speed.oninput = () => {
    settings.speechRate = parseFloat(speed.value);
    speedVal.textContent = `${settings.speechRate.toFixed(2)}×`;
    persist();
  };
  speedRow.append(speed, speedVal);
  form.append(speedRow);

  // Instructor name (shown as the coaching voice's label in the transcript)
  form.append(
    textField("Instructor name", settings.instructorName, (v) => (settings.instructorName = v))
  );

  // Appearance
  form.append(el("label", "field-label", "Appearance"));
  const themeRow = el("div", "seg");
  for (const [val, label] of [
    ["system", "System"],
    ["light", "Light"],
    ["dark", "Dark"],
  ] as const) {
    const b = el("button", settings.theme === val ? "seg-on" : "seg-off", label);
    b.onclick = () => {
      settings.theme = val;
      persist();
      renderSettings();
    };
    themeRow.append(b);
  }
  form.append(themeRow);

  const done = el("button", "primary", "Done");
  done.onclick = renderHome;
  form.append(done);

  app.append(form);
}

function textField(
  label: string,
  value: string,
  onChange: (v: string) => void,
  type = "text"
): HTMLElement {
  const wrap = el("div", "field");
  wrap.append(el("label", "field-label", label));
  const input = el("input", "input") as HTMLInputElement;
  // Secrets (API key / passcode) are masked WITHOUT type="password": that type
  // is exactly what makes Chrome offer to "save the login" and hijack focus. A
  // text field masked via -webkit-text-security stays hidden but is invisible to
  // the password manager. (Firefox lacks that CSS, so it shows plaintext — fine
  // for a locally-stored key on your own machine.)
  const secret = type === "password";
  input.type = "text";
  if (secret) {
    input.style.setProperty("-webkit-text-security", "disc");
    input.autocomplete = "off";
    input.setAttribute("autocapitalize", "none");
    input.setAttribute("autocorrect", "off");
    input.spellcheck = false;
    input.name = label.toLowerCase().replace(/[^a-z0-9]+/g, "-");
  }
  input.value = value;
  input.oninput = () => {
    onChange(input.value);
    persist();
  };
  wrap.append(input);
  return wrap;
}

function persist() {
  saveSettings(settings);
  applyPrefs();
}

/** Apply display/voice preferences that live outside a session. */
function applyPrefs() {
  setSpeechRate(settings.speechRate);
  if (settings.theme === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = settings.theme;
}

applyPrefs();
renderHome();
