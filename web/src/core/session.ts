// Port of PracticeSession (Session.swift) + the pieces of DrillLibrary/
// DrillRandomizer the loop needs. Owns drill sequencing and the app-composed
// readback/amendment chain; the grader only judges the pilot's transmission.

import type { Drill, Verdict, Turn, CallType, GradingMode, Difficulty } from "./types";
import { grade, type GraderConfig } from "./client";

/** Classify a drill by its explicit tag or a fallback derived from its id. */
export function callType(drill: Drill): CallType {
  if (drill.callType) return drill.callType;
  const id = drill.id;
  if (id.includes("readback")) return "readback";
  if (id.includes("bravo")) return "bravo";
  if (id.includes("traffic")) return "advisory";
  if (id.startsWith("ff-")) return "flightFollowing";
  if (id.includes("taxi") || id.includes("clearance")) return "taxi";
  if (id.endsWith("clear") || id.includes("afterlanding")) return "afterLanding";
  if (id.includes("departure")) return "departure";
  if (
    id.includes("downwind") ||
    id.includes("base") ||
    id.includes("teardrop") ||
    id.includes("touchgo")
  )
    return "pattern";
  if (id.includes("inbound") || id.includes("arrival")) return "arrival";
  return drill.scenario === "flightFollowing" ? "flightFollowing" : "arrival";
}

function pick<T>(xs: T[]): T {
  return xs[Math.floor(Math.random() * xs.length)];
}

/** Resolve the app-composed instruction (and any amendment) for a chained
 *  drill. Picks a random authored variant. The full substitution randomizer
 *  (taxiway shuffle, squawk digits) is a later port; this already gives
 *  cross/hold-short/route variety from the authored variants. */
export function resolveInstructions(drill: Drill): Drill {
  const d = { ...drill };
  if (d.instruction == null && d.instructionVariants?.length)
    d.instruction = pick(d.instructionVariants);
  if (d.amendment == null && d.amendmentVariants?.length)
    d.amendment = pick(d.amendmentVariants);
  return d;
}

/** Serializable session state for resume-after-exit. */
export interface SessionSnapshot {
  drills: Drill[];
  index: number;
  history: Turn[];
}

export interface SubmitResult {
  verdict: Verdict;
  /** The app-composed clearance the controller spoke this turn, if any — the
   *  UI speaks this in the radio voice. */
  spokenInstruction: string | null;
  finished: boolean;
}

export class PracticeSession {
  private drills: Drill[];
  private index = 0;
  private history: Turn[] = [];
  private config: GraderConfig;
  private mode: GradingMode;

  constructor(
    drills: Drill[],
    config: GraderConfig,
    mode: GradingMode = "live"
  ) {
    this.drills = drills.map(resolveInstructions);
    this.config = config;
    this.mode = mode;
  }

  /** Capture the current state (drills already resolved) for later resume. */
  snapshot(): SessionSnapshot {
    return { drills: this.drills, index: this.index, history: this.history };
  }

  /** Rebuild a session from a snapshot without re-resolving/re-randomizing. */
  static from(snap: SessionSnapshot, config: GraderConfig, mode: GradingMode): PracticeSession {
    const s = new PracticeSession([], config, mode);
    s.drills = snap.drills;
    s.index = snap.index;
    s.history = snap.history;
    return s;
  }

  get currentDrill(): Drill | null {
    return this.index < this.drills.length ? this.drills[this.index] : null;
  }

  get isFinished(): boolean {
    return this.index >= this.drills.length;
  }

  get progress(): { index: number; total: number } {
    return { index: this.index, total: this.drills.length };
  }

  setDifficulty(difficulty: Difficulty) {
    this.config = { ...this.config, difficulty };
  }

  /** Advance past the current drill without grading it. */
  skip() {
    this.index += 1;
    this.history = [];
  }

  async submit(transmission: string, signal?: AbortSignal): Promise<SubmitResult | null> {
    const drill = this.currentDrill;
    if (!drill) return null;

    const next = this.index + 1 < this.drills.length ? this.drills[this.index + 1] : null;
    const nextSetup =
      next && next.airport.icao === drill.airport.icao ? next.setup : null;

    const verdict = await grade(
      this.config,
      drill,
      this.mode,
      this.history,
      transmission,
      nextSetup,
      signal
    );

    // App-composed instruction: on the advancing turn the SESSION issues the
    // authored clearance, not the grader. A request drill issues its
    // `instruction`; a readback drill that carries an `amendment` issues that.
    let issueText: string | null = null;
    let carryAmendment: string | null = null;
    if (drill.followUpReadback === true && drill.instruction) {
      issueText = drill.instruction;
      carryAmendment = drill.amendment ?? null;
    } else if (drill.injectedReadback === true && drill.amendment) {
      issueText = drill.amendment;
    }
    const willInject = issueText !== null;

    if (verdict.phaseAdvance && issueText) {
      verdict.radioReplyText = issueText;
    }

    // A crossing/hold-short the grader ISSUES demands its own readback, so
    // advancing past it is a contradiction — unless we're injecting a follow-up
    // or this drill is itself a readback (its reply is an acknowledgment).
    const isReadbackDrill =
      drill.injectedReadback === true || callType(drill) === "readback";
    if (verdict.phaseAdvance && !willInject && !isReadbackDrill) {
      const reply = verdict.radioReplyText.toLowerCase();
      if (reply.includes("cross runway") || reply.includes("hold short")) {
        verdict.phaseAdvance = false;
      }
    }

    this.history.push({ pilot: verdict.heard, reply: verdict.radioReplyText });

    let spokenInstruction: string | null = null;
    if (verdict.phaseAdvance) {
      if (issueText) {
        spokenInstruction = issueText;
        this.drills.splice(
          this.index + 1,
          0,
          this.readbackFollowUp(drill, verdict, issueText, carryAmendment)
        );
      }
      this.index += 1;
      this.history = [];
    }

    return { verdict, spokenInstruction, finished: this.isFinished };
  }

  private readbackFollowUp(
    drill: Drill,
    verdict: Verdict,
    instruction: string,
    amendment: string | null
  ): Drill {
    let voice: string;
    switch (verdict.speaker) {
      case "Ground":
      case "Tower":
        voice = `${drill.airport.name} ${verdict.speaker}`;
        break;
      case "Approach":
      case "Center":
        voice = `NorCal ${verdict.speaker}`;
        break;
      case "":
      case "none":
        voice = `${drill.airport.name} ${drill.airport.isTowered ? "Tower" : "Ground"}`;
        break;
      default:
        voice = verdict.speaker;
    }
    return {
      id: `${drill.id}-readback`,
      scenario: drill.scenario,
      title: "Read back your instructions",
      setup: `${voice} has just given you your instructions. Read them back — and if you missed part of it, ask them to say again.`,
      situation: `You are ${voice}. You just issued exactly this instruction: '${instruction}'. Grade the pilot's readback against it — every element that requires a readback must be VERBATIM: runway instructions (assigned runway, route, crossings, hold shorts), squawk codes, frequencies, altitude restrictions, and clearances, plus the callsign. Advisory extras in your instruction (traffic, weather, 'radar contact') need no readback. THE CALLSIGN IS REQUIRED — but grade it ONLY from what the pilot actually transmitted: if their transmission contains no callsign at all, it is MISSING, so mark the readback incomplete and ask them to add their callsign. NEVER insert a callsign they did not say. If anything required is missing or wrong, say exactly which item to read back and do not advance. If the pilot asks you to say again, repeat the instruction verbatim and do not advance. On a complete, correct readback, set phaseAdvance true and leave radioReplyText EMPTY — a real controller does NOT acknowledge a correct readback, they simply move on. Speak here ONLY to point out a wrong or missing item, or to answer a say-again; never say 'readback correct', never re-read the clearance, and never issue a NEW instruction here.`,
      aircraft: drill.aircraft,
      airport: drill.airport,
      callType: "readback",
      instruction,
      injectedReadback: true,
      amendment,
    };
  }
}
