import "./styles.css";
import "leaflet/dist/leaflet.css";
import L from "leaflet";
import {
  CATEGORIES,
  categoryCount,
  drillsMatching,
  generatedAt,
  routableAirports,
  defaultAircraft,
  fleet,
  allDrills,
} from "./core/drills";
import { tripDrills } from "./core/trip";
import { vary } from "./core/randomizer";
import { retarget } from "./core/aircraft";
import { AIRPORT_COORDS } from "./core/geo";
import { PracticeSession, callType } from "./core/session";
import { loadStats, recordResult, resetStats } from "./core/stats";
import { saveResume, loadResume, clearResume } from "./core/resume";
import type { CallType, Verdict, Airport, Aircraft, Drill } from "./core/types";
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
  app.classList.remove("session-view");

  const header = el("header", "topbar");
  header.append(el("div", "brand", "VFR Radio — Practice"));
  const gear = el("button", "ghost gearbtn") as HTMLButtonElement;
  setBtn(gear, ICON_GEAR, "Settings");
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

  const saved = loadResume();
  if (saved) {
    const card = el("button", "resume-card") as HTMLButtonElement;
    card.innerHTML =
      `<span class="resume-body"><span class="resume-title">Resume session</span>` +
      `<span class="resume-sub">Drill ${saved.index + 1} of ${saved.total}${saved.title ? " · " + saved.title : ""}</span></span>` +
      `<span class="action-arrow">→</span>`;
    card.disabled = !keyReady();
    card.onclick = resumeSession;
    app.append(card);
    const discard = el("button", "ghost small discardbtn", "Discard") as HTMLButtonElement;
    discard.onclick = () => {
      clearResume();
      renderHome();
    };
    app.append(discard);
  }

  app.append(sectionLabel("Practice by category"));
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

  app.append(sectionLabel("More ways to practice"));
  const actions = el("div", "actions");
  actions.append(
    actionCard(ICON_MIX, "Build a mix", "Several call types, shuffled", renderMix, !keyReady()),
    actionCard(ICON_MAP, "Plan a route", "Fly a cross-country on the map", renderMap, !keyReady()),
    actionCard(ICON_CHART, "Progress", "Stats & weak spots", renderStats, false),
    actionCard(ICON_LIST, "Browse drills", "Start from any single call", renderBrowse, !keyReady())
  );
  app.append(actions);

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

function isDarkTheme(): boolean {
  if (settings.theme === "dark") return true;
  if (settings.theme === "light") return false;
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
}

function renderMap() {
  stopSpeaking();
  session = null;
  app.innerHTML = "";
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Back");
  header.append(back);
  header.append(el("div", "brand", "Plan a route"));
  app.append(header);

  app.append(
    el(
      "p",
      "muted small",
      "Tap airports in the order you'll fly them — tap a field again for a repeat stop (round trips welcome). Two or more stops builds the trip."
    )
  );

  const airports = routableAirports.filter((a) => AIRPORT_COORDS[a.icao]);
  const mapDiv = el("div", "routemap");
  app.append(mapDiv);
  const routeBar = el("div", "routebar");
  app.append(routeBar);

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
  const startBtn = el("button", "primary", "Start route") as HTMLButtonElement;
  const opts = el("div", "form");
  opts.append(ffRow, pwRow, startBtn);
  app.append(opts);

  const route: string[] = []; // ordered, repeats allowed (round trips)
  const byIcao = (icao: string) => airports.find((a) => a.icao === icao)!;
  const ll = (icao: string): [number, number] => [
    AIRPORT_COORDS[icao].lat,
    AIRPORT_COORDS[icao].lon,
  ];

  const map = L.map(mapDiv, { attributionControl: true });
  L.tileLayer(
    isDarkTheme()
      ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
      : "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png",
    { attribution: "© OpenStreetMap, © CARTO", subdomains: "abcd", maxZoom: 18 }
  ).addTo(map);

  const routeLine = L.polyline([], { color: "#d29922", weight: 4, opacity: 0.9 }).addTo(map);
  const markerByIcao: Record<string, L.CircleMarker> = {};

  const redraw = () => {
    routeLine.setLatLngs(route.map(ll));
    for (const a of airports) {
      const positions = route.map((r, i) => (r === a.icao ? i + 1 : 0)).filter(Boolean);
      const inRoute = positions.length > 0;
      markerByIcao[a.icao].setStyle({
        fillColor: inRoute ? "#d29922" : a.isTowered ? "#2f81f7" : "#2ea043",
        color: inRoute ? "#ffffff" : "rgba(0,0,0,0.45)",
      });
      markerByIcao[a.icao].setTooltipContent(inRoute ? `${a.icao} · ${positions.join("/")}` : a.icao);
    }
    routeBar.innerHTML = "";
    if (route.length === 0) {
      routeBar.append(el("span", "muted small", "Tap airports to add stops."));
    } else {
      route.forEach((icao, idx) => {
        if (idx > 0) routeBar.append(el("span", "chip-arrow", "→"));
        const chip = el("span", "chip", `${idx + 1}. ${icao}`);
        const x = el("button", "chip-x", "×") as HTMLButtonElement;
        x.title = "Remove stop";
        x.onclick = () => {
          route.splice(idx, 1);
          // Removing a middle stop can leave the same field back-to-back; drop one.
          for (let i = route.length - 1; i > 0; i--) {
            if (route[i] === route[i - 1]) route.splice(i, 1);
          }
          redraw();
        };
        chip.append(x);
        routeBar.append(chip);
      });
      const clear = el("button", "ghost small", "Clear") as HTMLButtonElement;
      clear.onclick = () => {
        route.length = 0;
        redraw();
      };
      routeBar.append(clear);
    }
    startBtn.disabled = route.length < 2;
  };

  for (const a of airports) {
    const m = L.circleMarker(ll(a.icao), {
      radius: 9,
      weight: 2,
      fillOpacity: 1,
      color: "rgba(0,0,0,0.45)",
      fillColor: a.isTowered ? "#2f81f7" : "#2ea043",
    });
    m.bindTooltip(a.icao, { permanent: true, direction: "top", offset: [0, -9], className: "apt-tt" });
    m.on("click", () => {
      if (route[route.length - 1] === a.icao) return; // no back-to-back same field
      route.push(a.icao);
      redraw();
    });
    m.addTo(map);
    markerByIcao[a.icao] = m;
  }

  map.fitBounds(L.latLngBounds(airports.map((a) => ll(a.icao))), { padding: [40, 40] });
  setTimeout(() => map.invalidateSize(), 60);

  back.onclick = () => {
    map.remove();
    renderHome();
  };
  startBtn.onclick = () => {
    if (route.length < 2) return;
    const stops = route.map(byIcao);
    map.remove();
    startTripSession(stops, ffCb.checked, pwCb.checked);
  };
  redraw();
}

// ------------------------------------------------------------- Progress / stats

function renderStats() {
  stopSpeaking();
  session = null;
  app.innerHTML = "";
  app.classList.remove("session-view");
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Back");
  back.onclick = renderHome;
  header.append(back);
  header.append(el("div", "brand", "Progress"));
  app.append(header);

  const stats = loadStats();
  const rows = CATEGORIES.map((c) => {
    const e = stats[c.type];
    const total = e ? e.pass + e.fail : 0;
    return { cat: c, total, rate: total ? (e as { pass: number }).pass / total : 0 };
  }).filter((r) => r.total > 0);

  if (rows.length === 0) {
    app.append(
      el(
        "p",
        "muted",
        "No calls graded yet. Fly a session and your per-call-type results show up here."
      )
    );
  } else {
    rows.sort((a, b) => a.rate - b.rate);
    const list = el("div", "statlist");
    for (const r of rows) {
      const row = el("div", "statrow");
      row.append(el("div", "statname", r.cat.label));
      const bar = el("div", "statbar");
      const fill = el("div", "statfill");
      const pct = Math.round(r.rate * 100);
      fill.style.width = `${pct}%`;
      fill.classList.add(r.rate < 0.7 ? "low" : r.rate < 0.85 ? "mid" : "high");
      bar.append(fill);
      row.append(bar);
      row.append(el("div", "statpct", `${pct}% · ${r.total}`));
      list.append(row);
    }
    app.append(list);

    const weak = rows.filter((r) => r.rate < 0.85).map((r) => r.cat.type);
    const weakBtn = el(
      "button",
      "primary",
      weak.length
        ? `Practice weak spots (${weak.length} type${weak.length === 1 ? "" : "s"})`
        : "Solid across the board — practice everything"
    ) as HTMLButtonElement;
    weakBtn.disabled = !keyReady();
    weakBtn.onclick = () =>
      startSession(new Set(weak.length ? weak : CATEGORIES.map((c) => c.type)));
    app.append(weakBtn);
  }

  const reset = el("button", "ghost small resetbtn", "Reset progress") as HTMLButtonElement;
  reset.onclick = () => {
    resetStats();
    renderStats();
  };
  app.append(reset);
}

// ------------------------------------------------------------- Drill browser

function renderBrowse() {
  stopSpeaking();
  session = null;
  app.innerHTML = "";
  app.classList.remove("session-view");
  const header = el("header", "topbar");
  const back = el("button", "ghost", "← Back");
  back.onclick = renderHome;
  header.append(back);
  header.append(el("div", "brand", "Browse drills"));
  app.append(header);
  app.append(
    el("p", "muted small", "Tap any call to practice just that one — its readbacks chain automatically.")
  );
  if (!keyReady()) app.append(el("div", "notice", "Add your key in Settings to start a drill."));

  for (const cat of CATEGORIES) {
    const drills = allDrills.filter((d) => callType(d) === cat.type);
    if (!drills.length) continue;
    app.append(el("div", "field-label browsecat", cat.label));
    const list = el("div", "browselist");
    for (const d of drills) {
      const row = el("button", "browserow") as HTMLButtonElement;
      row.append(el("span", "browsetitle", d.title));
      row.append(el("span", "browsemeta", d.airport.icao));
      row.disabled = !keyReady();
      row.onclick = () => runDrills([d]);
      list.append(row);
    }
    app.append(list);
  }
}

// ---------------------------------------------------------------- Session

/** The airplane to fly this session: a pinned fleet plane, a random one ("all"),
 *  or the default. */
function chosenAircraft(): Aircraft {
  if (settings.aircraft === "all") return fleet[Math.floor(Math.random() * fleet.length)];
  return fleet.find((a) => a.callsign === settings.aircraft) ?? defaultAircraft;
}

function runDrills(drills: Drill[]) {
  if (drills.length === 0) {
    renderHome();
    return;
  }
  sessionLog = [];
  voiceNoticeShown = false;
  clearResume(); // a new session invalidates any prior resume point
  // Fly one consistent airplane (retarget FIRST so the randomizer shields the
  // chosen callsign), then vary incidental details.
  const plane = chosenAircraft();
  let prepared = drills.map((d) => retarget(d, plane));
  if (settings.randomize) prepared = vary(prepared);
  session = new PracticeSession(prepared, graderConfig(), settings.gradingMode);
  renderSession();
  briefCurrent();
  saveSnapshot();
}

/** Persist the current session so it can be resumed after exiting. */
function saveSnapshot() {
  if (!session || session.isFinished) return;
  const d = session.currentDrill;
  const p = session.progress;
  saveResume({
    snap: session.snapshot(),
    mode: settings.gradingMode,
    log: sessionLog,
    savedAt: Date.now(),
    index: p.index,
    total: p.total,
    title: d?.title ?? "",
  });
}

function resumeSession() {
  const saved = loadResume();
  if (!saved) {
    renderHome();
    return;
  }
  sessionLog = saved.log ?? [];
  voiceNoticeShown = false;
  session = PracticeSession.from(saved.snap, graderConfig(), saved.mode);
  renderSession();
  // On a chained readback, remind the pilot what the controller last issued.
  const d = session.currentDrill;
  if (d?.injectedReadback && d.instruction) addLine("radio", `(earlier) ${d.instruction}`);
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
let abandonBtn: HTMLButtonElement;
let textInput: HTMLTextAreaElement;
let gradeAbort: AbortController | null = null;

// Inline SVG icons (emoji render inconsistently across platforms).
const ICON_MIC = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2"/><line x1="12" y1="19" x2="12" y2="22"/></svg>`;
const ICON_VOL_ON = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H2v6h4l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M19 5a9 9 0 0 1 0 14"/></svg>`;
const ICON_VOL_OFF = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H2v6h4l5 4z"/><line x1="22" y1="9" x2="16" y2="15"/><line x1="16" y1="9" x2="22" y2="15"/></svg>`;
const ICON_MIX = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 3 21 3 21 8"/><line x1="4" y1="20" x2="21" y2="3"/><polyline points="21 16 21 21 16 21"/><line x1="15" y1="15" x2="21" y2="21"/><line x1="4" y1="4" x2="9" y2="9"/></svg>`;
const ICON_MAP = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="1 6 1 22 8 18 16 22 23 18 23 2 16 6 8 2 1 6"/><line x1="8" y1="2" x2="8" y2="18"/><line x1="16" y1="6" x2="16" y2="22"/></svg>`;
const ICON_CHART = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>`;
const ICON_LIST = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>`;
const ICON_GEAR = `<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>`;

/** Set a button's contents to an inline icon plus a text label. */
function setBtn(btn: HTMLElement, icon: string, label: string) {
  btn.innerHTML = `${icon}<span>${label}</span>`;
}

// Other aircraft on frequency, for the "busy frequency" realism option.
const CHATTER = [
  "Watsonville traffic, Cessna five one two, left downwind runway two zero, Watsonville.",
  "NorCal Approach, Skyhawk eight three x-ray, request flight following.",
  "Reid-Hillview Tower, Cherokee four papa, holding short runway three one right.",
  "Palo Alto traffic, Cirrus niner delta, departing runway three one, northbound.",
  "NorCal, Bonanza seven quebec, level four thousand five hundred.",
  "Watsonville traffic, experimental six two mike, ten miles south, inbound full stop.",
  "Livermore Tower, Diamond two romeo, ready for departure runway two five right.",
];
const randomChatter = () => CHATTER[Math.floor(Math.random() * CHATTER.length)];

/** A small uppercase section heading (Apple grouped-list style). */
function sectionLabel(text: string): HTMLElement {
  return el("div", "section-label", text);
}

/** A secondary action card: icon, title, and a one-line subtitle. */
function actionCard(
  icon: string,
  title: string,
  sub: string,
  onClick: () => void,
  disabled: boolean
): HTMLButtonElement {
  const b = el("button", "action") as HTMLButtonElement;
  b.innerHTML =
    `<span class="action-ic">${icon}</span>` +
    `<span class="action-body"><span class="action-title">${title}</span>` +
    `<span class="action-sub">${sub}</span></span>` +
    `<span class="action-arrow">→</span>`;
  b.disabled = disabled;
  b.onclick = onClick;
  return b;
}

function renderSession() {
  app.innerHTML = "";
  app.classList.add("session-view");
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

  bannerEl = el("div", "banner");
  app.append(bannerEl);

  transcriptEl = el("div", "transcript");
  app.append(transcriptEl);

  // ---- Controls (pinned to the bottom) ----
  const controls = el("div", "controls");

  statusEl = el("div", "status muted");
  controls.append(statusEl);

  abandonBtn = el("button", "abandon", "Abandon grading") as HTMLButtonElement;
  abandonBtn.style.display = "none";
  abandonBtn.onclick = () => gradeAbort?.abort();
  controls.append(abandonBtn);

  // Voice input works via the browser (Chrome/Android) OR the Worker (Whisper,
  // which also covers Firefox/Safari). Enable the button if either is available.
  voiceInputAvailable = recognitionSupported || workerVoiceConfigured(graderConfig());

  const talkRow = el("div", "talkrow");
  talkBtn = el("button", "talk") as HTMLButtonElement;
  setBtn(talkBtn, ICON_MIC, voiceInputAvailable ? "Hold to talk" : "Voice unavailable — type below");
  talkBtn.disabled = !voiceInputAvailable;
  if (voiceInputAvailable) {
    // Pointer events (mouse + touch + pen) with capture so the release always
    // fires even if the cursor/finger drifts off the button mid-hold.
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
  talkRow.append(talkBtn);

  // Voice / text-only toggle (mutes spoken replies without leaving the session).
  const voiceBtn = el("button", "voicetoggle ghost") as HTMLButtonElement;
  const paintVoice = () =>
    setBtn(voiceBtn, masterMuted ? ICON_VOL_OFF : ICON_VOL_ON, masterMuted ? "Muted" : "Voice");
  paintVoice();
  voiceBtn.title = "Mute all voices (this session)";
  voiceBtn.onclick = () => {
    masterMuted = !masterMuted;
    if (masterMuted) stopSpeaking();
    paintVoice();
  };
  talkRow.append(voiceBtn);
  controls.append(talkRow);

  const typed = el("div", "typed");
  textInput = el("textarea", "text") as HTMLTextAreaElement;
  textInput.placeholder = "…or type your radio call and press Send";
  textInput.rows = 1;
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
  // Busy frequency: occasional chatter from other aircraft before the scene.
  if (settings.busyFrequency && drill.injectedReadback !== true && Math.random() < 0.3) {
    const c = randomChatter();
    addLine("radio", c);
    await say(c, "controller");
  }
  if (drill.injectedReadback === true) {
    addLine("instructor", drill.setup);
    await say(drill.setup, "instructor");
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

type SayRole = "scene" | "controller" | "instructor" | "note";
// Transient per-session master mute (the in-session voice toggle). Per-role
// volumes live in Settings; the radio/controller reply is always audible.
let masterMuted = false;

function volumeFor(role: SayRole): number {
  if (masterMuted) return 0;
  switch (role) {
    case "scene":
      return settings.sceneVolume;
    case "instructor":
      return settings.instructorVolume;
    case "note":
      return settings.passNotesVolume;
    case "controller":
      return 1;
  }
}

/** Speak text aloud at the role's volume (0 = on-screen only). Uses the Worker's
 *  TTS when configured (good voice everywhere), else browser speechSynthesis. */
async function say(text: string, role: SayRole) {
  const vol = volumeFor(role);
  if (vol < 0.02) return; // muted role
  const spoken = forSpeech(text);
  const cfg = graderConfig();
  if (workerVoiceConfigured(cfg)) {
    try {
      const clip = await synthesize(cfg, spoken);
      if (clip) {
        await playClip(clip, undefined, vol);
        return;
      }
      addLine("note", "Voice: Worker returned no audio — using browser voice.");
      noteVoiceFallback();
    } catch (e: any) {
      addLine("note", `Voice fell back to browser: ${e.message}`);
      noteVoiceFallback();
    }
  }
  await speak(spoken, role === "note" ? "instructor" : role, vol);
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
  // Busy frequency: occasionally your call gets stepped on — say it again.
  if (settings.busyFrequency && Math.random() < 0.15) {
    addLine("radio", "Two aircraft calling at the same time — say again.");
    await say("Two aircraft calling at the same time, say again.", "controller");
    status("Stepped on — say it again.");
    return;
  }
  status("Grading…");
  talkBtn.disabled = true;
  gradeAbort = new AbortController();
  abandonBtn.style.display = "";
  const gradedDrill = session.currentDrill;
  const label = gradedDrill?.title ?? "";
  try {
    const result = await session.submit(text, gradeAbort.signal);
    if (!result) {
      finish();
      return;
    }
    const v0 = result.verdict;
    const passed = v0.correct || v0.phaseAdvance;
    if (gradedDrill) recordResult(callType(gradedDrill), passed);
    sessionLog.push({
      label,
      pass: passed,
      coaching: v0.coaching,
      corrections: v0.corrections,
    });
    showVerdict(result.verdict);
    if (result.spokenInstruction) {
      addLine("radio", result.spokenInstruction);
      await say(result.spokenInstruction, "controller");
    } else if (result.verdict.radioReplyText) {
      addLine("radio", `${result.verdict.speaker}: ${result.verdict.radioReplyText}`);
      await say(result.verdict.radioReplyText, "controller");
    }
    // Instructor coaching on a miss; polish notes on a pass — each at its volume.
    if (v0.coaching) await say(v0.coaching, passed ? "note" : "instructor");
    // Echo/shadow: read the ideal call aloud after a miss so you can shadow it.
    if (!passed && settings.echoModelCall && v0.expectedExample) {
      await say(`Here's the model call. ${v0.expectedExample}`, "instructor");
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
    saveSnapshot();
  } catch (e: any) {
    if (gradeAbort?.signal.aborted) {
      status("Grading abandoned — make your call again.");
    } else {
      status("");
      addLine("note", `⚠️ ${e.message}`);
    }
  } finally {
    gradeAbort = null;
    abandonBtn.style.display = "none";
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
  clearResume();
  app.innerHTML = "";
  app.classList.remove("session-view");
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

  if (n > 0) {
    const actions = el("div", "debrief-actions");
    const copyBtn = el("button", "ghost small", "Copy debrief") as HTMLButtonElement;
    copyBtn.onclick = async () => {
      try {
        await navigator.clipboard.writeText(debriefText());
        copyBtn.textContent = "Copied ✓";
        setTimeout(() => (copyBtn.textContent = "Copy debrief"), 1500);
      } catch {
        downloadDebrief();
      }
    };
    actions.append(copyBtn);
    const dlBtn = el("button", "ghost small", "Download") as HTMLButtonElement;
    dlBtn.onclick = downloadDebrief;
    actions.append(dlBtn);
    if ("share" in navigator) {
      const shareBtn = el("button", "ghost small", "Share") as HTMLButtonElement;
      shareBtn.onclick = () =>
        navigator.share({ title: "VFR Radio debrief", text: debriefText() }).catch(() => {});
      actions.append(shareBtn);
    }
    app.append(actions);
  }

  const home = el("button", "primary", "Back to categories");
  home.onclick = renderHome;
  app.append(home);
}

/** A plain-text summary of the session for copy / download / share. */
function debriefText(): string {
  const lines: string[] = ["VFR Radio — session debrief", new Date().toLocaleString()];
  const total = sessionLog.length;
  const clean = sessionLog.filter((e) => e.pass && e.corrections.length === 0).length;
  lines.push(`${total} call${total === 1 ? "" : "s"} · ${clean} clean`, "");
  sessionLog.forEach((e, i) => {
    lines.push(`${i + 1}. ${e.pass ? "PASS" : "MISS"} — ${e.label}`);
    if (e.coaching) lines.push(`   ${e.coaching}`);
    for (const c of e.corrections) lines.push(`   • ${c}`);
  });
  return lines.join("\n");
}

function downloadDebrief() {
  const blob = new Blob([debriefText()], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `vfr-debrief-${new Date().toISOString().slice(0, 10)}.txt`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
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

  // Aircraft
  form.append(el("label", "field-label", "Aircraft"));
  const acSel = el("select", "select") as HTMLSelectElement;
  const acOptions: [string, string][] = [
    ["", `${defaultAircraft.type} (${defaultAircraft.callsign}) — default`],
    ...fleet
      .filter((a) => a.callsign !== defaultAircraft.callsign)
      .map((a) => [a.callsign, `${a.type} (${a.callsign})`] as [string, string]),
    ["all", "All — a random plane each session"],
  ];
  for (const [val, label] of acOptions) {
    const o = el("option", undefined, label) as HTMLOptionElement;
    o.value = val;
    if (val === settings.aircraft) o.selected = true;
    acSel.append(o);
  }
  acSel.onchange = () => {
    settings.aircraft = acSel.value;
    persist();
  };
  form.append(acSel);

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

  // Per-role volumes (the radio / controller reply is always audible)
  form.append(
    volumeField(
      "Scene voice",
      settings.sceneVolume,
      (v) => {
        settings.sceneVolume = v;
        persist();
      },
      "The instructor setting up each drill. Keep this up so you always hear the scene."
    )
  );
  form.append(
    volumeField(
      "Instructor voice",
      settings.instructorVolume,
      (v) => {
        settings.instructorVolume = v;
        persist();
      },
      "Coaching and the ‘read it back’ prompt after your call. Zero lets you answer the controller yourself — the help stays on screen only."
    )
  );
  form.append(
    volumeField(
      "Notes on passed calls",
      settings.passNotesVolume,
      (v) => {
        settings.passNotesVolume = v;
        persist();
      },
      "Polish notes when a call passes. Zero (default) keeps passes snappy; the notes still show on screen and in the debrief."
    )
  );

  // Randomize details
  const randRow = el("label", "checkrow");
  const randCb = el("input") as HTMLInputElement;
  randCb.type = "checkbox";
  randCb.checked = settings.randomize;
  randCb.onchange = () => {
    settings.randomize = randCb.checked;
    persist();
  };
  randRow.append(
    randCb,
    el("span", undefined, "Vary details each session (ATIS, runway, altitude, squawk)")
  );
  form.append(randRow);

  const echoRow = el("label", "checkrow");
  const echoCb = el("input") as HTMLInputElement;
  echoCb.type = "checkbox";
  echoCb.checked = settings.echoModelCall;
  echoCb.onchange = () => {
    settings.echoModelCall = echoCb.checked;
    persist();
  };
  echoRow.append(
    echoCb,
    el("span", undefined, "Read the model call aloud after a miss (shadow practice)")
  );
  form.append(echoRow);

  const busyRow = el("label", "checkrow");
  const busyCb = el("input") as HTMLInputElement;
  busyCb.type = "checkbox";
  busyCb.checked = settings.busyFrequency;
  busyCb.onchange = () => {
    settings.busyFrequency = busyCb.checked;
    persist();
  };
  busyRow.append(
    busyCb,
    el("span", undefined, "Busy frequency — other aircraft, and your call sometimes gets stepped on")
  );
  form.append(busyRow);

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

/** A 0–100% volume slider with a caption. Persistence is handled by onChange. */
function volumeField(
  label: string,
  value: number,
  onChange: (v: number) => void,
  help: string
): HTMLElement {
  const wrap = el("div", "field");
  wrap.append(el("label", "field-label", label));
  const row = el("div", "sliderrow");
  const slider = el("input") as HTMLInputElement;
  slider.type = "range";
  slider.min = "0";
  slider.max = "1";
  slider.step = "0.05";
  slider.value = String(value);
  const val = el("span", "muted small", `${Math.round(value * 100)}%`);
  slider.oninput = () => {
    const v = parseFloat(slider.value);
    val.textContent = `${Math.round(v * 100)}%`;
    onChange(v);
  };
  row.append(slider, val);
  wrap.append(row);
  wrap.append(el("p", "muted small", help));
  return wrap;
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
