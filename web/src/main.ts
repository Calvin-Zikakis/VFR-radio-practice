import "./styles.css";
import {
  CATEGORIES,
  categoryCount,
  drillsMatching,
  generatedAt,
  routableAirports,
  defaultAircraft,
} from "./core/drills";
import { tripDrills } from "./core/trip";
import { AIRPORT_COORDS } from "./core/geo";
import { PracticeSession } from "./core/session";
import type { CallType, Verdict, Airport, Drill } from "./core/types";
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

/** One graded transmission, for the end-of-session debrief scorecard. */
interface LogEntry {
  label: string;
  pass: boolean;
  coaching: string;
  corrections: string[];
}
let sessionLog: LogEntry[] = [];
// The current "You" transcript line, so grading can replace the raw STT text
// with Claude's cleaned interpretation (verdict.heard).
let lastYouText: HTMLElement | null = null;
// Show the "use Chrome" notice at most once per session.
let voiceNoticeShown = false;

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

  const mapBtn = el("button", "ghost mixlink", "🗺  Plan a route on the map →") as HTMLButtonElement;
  mapBtn.disabled = !keyReady();
  mapBtn.onclick = renderMap;
  app.append(mapBtn);

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

// ------------------------------------------------------------- Map route builder

function renderMap() {
  stopSpeaking();
  session = null;
  app.innerHTML = "";
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Back");
  back.onclick = renderHome;
  header.append(back);
  header.append(el("div", "brand", "Plan a route"));
  app.append(header);

  app.append(
    el(
      "p",
      "muted",
      "Tap airports in the order you'll fly them. Two or more builds a cross-country — taxi, departure, flight following, arrivals, the whole trip."
    )
  );

  const airports = routableAirports.filter((a) => AIRPORT_COORDS[a.icao]);

  // Equirectangular projection, longitude scaled by cos(lat) so the shape stays
  // true across this small region.
  const meanLat =
    airports.reduce((s, a) => s + AIRPORT_COORDS[a.icao].lat, 0) / airports.length;
  const k = Math.cos((meanLat * Math.PI) / 180);
  const px = (a: Airport) => AIRPORT_COORDS[a.icao].lon * k;
  const py = (a: Airport) => AIRPORT_COORDS[a.icao].lat;
  const minX = Math.min(...airports.map(px));
  const maxX = Math.max(...airports.map(px));
  const minY = Math.min(...airports.map(py));
  const maxY = Math.max(...airports.map(py));
  const pad = 0.12 * Math.max(maxX - minX, maxY - minY);
  const W = maxX - minX + 2 * pad;
  const H = maxY - minY + 2 * pad;
  const scale = 900 / Math.max(W, H);
  const VW = W * scale;
  const VH = H * scale;
  const project = (a: Airport): [number, number] => [
    (px(a) - minX + pad) * scale,
    (maxY - py(a) + pad) * scale, // invert Y: north is up
  ];

  const NS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("viewBox", `0 0 ${VW.toFixed(1)} ${VH.toFixed(1)}`);
  svg.setAttribute("class", "routemap");
  const routeLine = document.createElementNS(NS, "polyline");
  routeLine.setAttribute("class", "route-line");
  svg.appendChild(routeLine);

  const selected: string[] = [];
  const markers: Record<string, { group: SVGGElement; badge: SVGTextElement }> = {};
  const byIcao = (icao: string) => airports.find((a) => a.icao === icao)!;

  const summary = el("div", "notice");
  const startBtn = el("button", "primary", "Start route") as HTMLButtonElement;

  const redraw = () => {
    routeLine.setAttribute(
      "points",
      selected.map((i) => project(byIcao(i)).map((n) => n.toFixed(1)).join(",")).join(" ")
    );
    for (const a of airports) {
      const m = markers[a.icao];
      const idx = selected.indexOf(a.icao);
      m.group.classList.toggle("sel", idx >= 0);
      m.badge.textContent = idx >= 0 ? String(idx + 1) : "";
    }
    summary.textContent =
      selected.length === 0
        ? "Tap two or more airports to build a route."
        : selected.length === 1
          ? `${selected[0]} — tap another to make a route.`
          : `Route: ${selected.join(" → ")}`;
    startBtn.disabled = selected.length < 2;
  };
  const toggle = (icao: string) => {
    const i = selected.indexOf(icao);
    if (i >= 0) selected.splice(i, 1);
    else selected.push(icao);
    redraw();
  };

  for (const a of airports) {
    const [x, y] = project(a);
    const g = document.createElementNS(NS, "g");
    g.setAttribute("class", `apt ${a.isTowered ? "towered" : "untowered"}`);
    const c = document.createElementNS(NS, "circle");
    c.setAttribute("cx", x.toFixed(1));
    c.setAttribute("cy", y.toFixed(1));
    c.setAttribute("r", "12");
    g.appendChild(c);
    const label = document.createElementNS(NS, "text");
    label.setAttribute("x", x.toFixed(1));
    label.setAttribute("y", (y - 18).toFixed(1));
    label.setAttribute("class", "apt-label");
    label.textContent = a.icao;
    g.appendChild(label);
    const badge = document.createElementNS(NS, "text");
    badge.setAttribute("x", x.toFixed(1));
    badge.setAttribute("y", (y + 1).toFixed(1));
    badge.setAttribute("class", "apt-badge");
    g.appendChild(badge);
    g.addEventListener("click", () => toggle(a.icao));
    svg.appendChild(g);
    markers[a.icao] = { group: g, badge };
  }
  app.append(svg);
  app.append(summary);

  const ffCb = el("input") as HTMLInputElement;
  ffCb.type = "checkbox";
  ffCb.checked = true;
  const pwCb = el("input") as HTMLInputElement;
  pwCb.type = "checkbox";
  pwCb.checked = true;
  const ffRow = el("label", "checkrow");
  ffRow.append(ffCb, el("span", undefined, "Flight following enroute"));
  const pwRow = el("label", "checkrow");
  pwRow.append(pwCb, el("span", undefined, "Pattern work at stops"));

  startBtn.onclick = () => {
    if (selected.length >= 2) startTripSession(selected.map(byIcao), ffCb.checked, pwCb.checked);
  };

  const opts = el("div", "form");
  opts.append(ffRow, pwRow, startBtn);
  app.append(opts);
  redraw();
}

// ---------------------------------------------------------------- Session

function runDrills(drills: Drill[]) {
  if (drills.length === 0) {
    renderHome();
    return;
  }
  sessionLog = [];
  voiceNoticeShown = false;
  session = new PracticeSession(drills, graderConfig(), settings.gradingMode);
  renderSession();
  briefCurrent();
}

function startSession(types: Set<CallType>) {
  runDrills(drillsMatching(types));
}

function startTripSession(stops: Airport[], flightFollowing: boolean, patternWork: boolean) {
  runDrills(tripDrills(stops, flightFollowing, patternWork, defaultAircraft));
}

let transcriptEl: HTMLElement;
let statusEl: HTMLElement;
let bannerEl: HTMLElement;
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

  // Voice / text-only toggle (mutes spoken replies without leaving the session).
  const speaker = el("button", "ghost") as HTMLButtonElement;
  const paintSpeaker = () => {
    speaker.textContent = settings.speakReplies ? "🔊" : "🔇";
    speaker.title = settings.speakReplies
      ? "Voice on — tap for text only"
      : "Text only — tap to hear replies";
  };
  paintSpeaker();
  speaker.onclick = () => {
    settings.speakReplies = !settings.speakReplies;
    persist();
    if (!settings.speakReplies) stopSpeaking();
    paintSpeaker();
  };
  header.append(speaker);

  const skip = el("button", "ghost", "Skip ›");
  skip.onclick = skipCurrent;
  header.append(skip);
  app.append(header);

  bannerEl = el("div", "banner");
  app.append(bannerEl);

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
      lastYouText = addLine("you", t);
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
function addLine(role: Role, text: string): HTMLElement {
  const line = el("div", `line ${role}`);
  const labels: Record<Role, string> = {
    scene: "Scene",
    instructor: settings.instructorName.trim() || "Instructor",
    you: "You",
    radio: "Radio",
    note: "Note",
  };
  line.append(el("div", "line-role", labels[role]));
  const textEl = el("div", "line-text", text);
  line.append(textEl);
  transcriptEl.append(line);
  transcriptEl.scrollTop = transcriptEl.scrollHeight;
  return textEl;
}

async function briefCurrent() {
  const drill = session!.currentDrill;
  if (!drill) {
    finish();
    return;
  }
  const a = drill.aircraft;
  bannerEl.textContent = `${a.callsign}  ·  ${a.type}  ·  “${a.phoneticCallsign}”`;
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

/** Normalize text for TTS pronunciation. Voice engines read "RV" as a word
 *  ("rerv"); the spaced form makes them say the letters. The transcript keeps
 *  the original spelling — this only affects what's spoken. */
function forSpeech(text: string): string {
  return text.replace(/\bRV\b/g, "R V");
}

function isChromeLike(): boolean {
  const ua = navigator.userAgent;
  return /Chrome|Chromium|CriOS|Edg/i.test(ua) && !/Firefox|FxiOS/i.test(ua);
}

/** Once per session on a non-Chrome browser, note that Chrome's built-in voice
 *  is much better — shown when the class voice server falls back. */
function noteVoiceFallback() {
  if (voiceNoticeShown || isChromeLike()) return;
  voiceNoticeShown = true;
  const banner = el(
    "div",
    "notice",
    "The class voice server is having trouble, so we've switched to your browser's built-in voice. Chrome's is much better — open this page in Chrome for the best experience."
  );
  if (bannerEl?.parentElement) bannerEl.after(banner);
}

/** Speak text aloud, honoring the Speak setting. Uses the Worker's TTS when
 *  configured (good voice in every browser), else browser speechSynthesis. */
async function say(text: string, role: Voice) {
  if (!settings.speakReplies) return;
  const spoken = forSpeech(text);
  const cfg = graderConfig();
  if (workerVoiceConfigured(cfg)) {
    try {
      const clip = await synthesize(cfg, spoken);
      if (clip) {
        await playClip(clip);
        return;
      }
      addLine("note", "Voice: Worker returned no audio — using browser voice.");
      noteVoiceFallback();
    } catch (e: any) {
      addLine("note", `Voice fell back to browser: ${e.message}`);
      noteVoiceFallback();
    }
  }
  await speak(spoken, role);
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
        lastYouText = addLine("you", said);
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
      lastYouText = addLine("you", said);
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
  const label = session.currentDrill?.title ?? "";
  try {
    const result = await session.submit(text);
    if (!result) {
      finish();
      return;
    }
    const v0 = result.verdict;
    sessionLog.push({
      label,
      pass: v0.correct || v0.phaseAdvance,
      coaching: v0.coaching,
      corrections: v0.corrections,
    });
    // Replace the raw STT "You" line with Claude's cleaned interpretation, which
    // corrects mis-heard callsigns/numbers. (Typed input reads back near-identical.)
    if (lastYouText && v0.heard) lastYouText.textContent = v0.heard;
    lastYouText = null;
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
  // (The "You" line already shows v.heard — no separate "Heard" note needed.)
  if (v.correct || v.phaseAdvance) {
    // In debrief mode, hold the positive coaching until the end scorecard.
    if (settings.gradingMode === "live" && v.coaching) addLine("note", `✓ ${v.coaching}`);
  } else {
    // A miss always shows what to fix — you need it to retry, in either mode.
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

  // Debrief scorecard: everything worth a second look — misses, calls with
  // corrections, and (in debrief mode) the coaching held back from each pass.
  const review = sessionLog.filter(
    (e) =>
      !e.pass ||
      e.corrections.length > 0 ||
      (settings.gradingMode === "debrief" && !!e.coaching)
  );
  const n = sessionLog.length;
  if (n === 0) {
    app.append(el("p", "muted", "Nice work. Ready for another round?"));
  } else if (review.length === 0) {
    app.append(
      el("p", "muted", `Clean run — ${n} call${n === 1 ? "" : "s"}, nothing to review.`)
    );
  } else {
    app.append(
      el("p", "muted", `${n} call${n === 1 ? "" : "s"} — ${review.length} to review:`)
    );
    const list = el("div", "debrief");
    for (const e of review) {
      const item = el("div", "line");
      item.append(el("div", "line-role", `${e.pass ? "✓" : "✗"} ${e.label}`));
      if (e.coaching) item.append(el("div", "line-text", e.coaching));
      for (const c of e.corrections) item.append(el("div", "line-text", `• ${c}`));
      list.append(item);
    }
    app.append(list);
  }

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

  // Coaching timing (live vs debrief-at-end)
  form.append(el("label", "field-label", "Coaching"));
  const gmRow = el("div", "seg");
  for (const [val, label] of [
    ["live", "After each call"],
    ["debrief", "At the end"],
  ] as const) {
    const b = el("button", settings.gradingMode === val ? "seg-on" : "seg-off", label);
    b.onclick = () => {
      settings.gradingMode = val;
      persist();
      renderSettings();
    };
    gmRow.append(b);
  }
  form.append(gmRow);

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
