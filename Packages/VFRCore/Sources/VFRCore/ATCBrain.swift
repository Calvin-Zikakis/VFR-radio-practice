import Foundation

/// One completed exchange, used to give the brain conversational context
/// across a multi-step drill.
public struct Turn: Sendable, Equatable, Codable {
    public var pilot: String   // what the pilot transmitted (as interpreted)
    public var reply: String   // what the radio said back
    public init(pilot: String, reply: String) {
        self.pilot = pilot
        self.reply = reply
    }
}

public enum ATCBrainError: Error, LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case refusal(String)
    case badResponse(String)
    case truncated
    case degenerate

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Anthropic API key set. Add one in Settings."
        case .http(let status, let body): return "API error \(status): \(body)"
        case .refusal(let s): return "Request declined: \(s)"
        case .badResponse(let s): return "Unexpected response: \(s)"
        case .truncated: return "grader response hit the output token limit — say the call again."
        case .degenerate: return "grader returned an empty verdict — say the call again."
        }
    }

    /// Sampling flukes worth one automatic re-roll before bothering the pilot.
    var isRetryable: Bool {
        switch self {
        case .truncated, .degenerate: return true
        default: return false
        }
    }
}

/// Abstraction over the grader so sessions can be tested without a network.
public protocol ATCEvaluating: Sendable {
    /// `nextSetup` is the next scripted prompt in the session when it continues
    /// at the same airport — continuity context so the grader's improvised
    /// radio replies never contradict what the script does next.
    func evaluate(drill: Drill, mode: GradingMode, history: [Turn],
                  transmission: String, nextSetup: String?) async throws -> Verdict
}

/// Talks to the Claude Messages API over raw HTTP (there is no official Swift
/// SDK). Stateless: the caller supplies drill + prior turns each call, which
/// keeps the stable prompt prefix cacheable.
public struct ATCBrain: ATCEvaluating, Sendable {
    public var apiKey: String
    public var model: String
    public var difficulty: Difficulty
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession

    /// Haiku 4.5 is the default: cheap, low-latency, and strong enough for
    /// phraseology grading. Bump to `claude-sonnet-5` for stricter grading.
    public init(apiKey: String, model: String = "claude-haiku-4-5",
                difficulty: Difficulty = .checkride, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.difficulty = difficulty
        self.session = session
    }

    public func evaluate(drill: Drill, mode: GradingMode, history: [Turn],
                         transmission: String, nextSetup: String? = nil) async throws -> Verdict {
        guard !apiKey.isEmpty else { throw ATCBrainError.missingAPIKey }

        let body = requestBody(drill: drill, mode: mode, history: history,
                               transmission: transmission, nextSetup: nextSetup)
        do {
            return try await send(body, historyCount: history.count)
        } catch let error as ATCBrainError where error.isRetryable {
            // Token-cap rambles and stub verdicts are sampling flukes, not
            // pilot errors. A fresh sample almost always comes back sane —
            // retry once before bothering them.
            vfrLog("degenerate grader sample (\(error)) — retrying once")
            return try await send(body, historyCount: history.count)
        } catch let error as URLError where error.code == .timedOut {
            // A network/server hiccup shouldn't make the pilot repeat a long
            // readback. The per-request ceiling is short (see `send`), so one
            // retry is a small wait and usually lands fast on the warm cache.
            vfrLog("grader request timed out — retrying once")
            return try await send(body, historyCount: history.count)
        }
    }

    private func send(_ body: [String: Any], historyCount: Int) async throws -> Verdict {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Grades normally land in ~8s; the default 60s ceiling meant a hung
        // request stalled the whole voice loop for a full minute before failing.
        // Give up sooner and let `evaluate` retry once (warm cache, usually fast).
        req.timeoutInterval = 30

        vfrLog("POST api model=\(model) keyLen=\(apiKey.count) history=\(historyCount)")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ATCBrainError.badResponse("no HTTP response")
        }
        vfrLog("HTTP \(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            vfrLog("error body: \(body.prefix(400))")
            throw ATCBrainError.http(status: http.statusCode, body: body)
        }
        return try Self.parseVerdict(from: data)
    }

    // MARK: - Request construction

    func requestBody(drill: Drill, mode: GradingMode, history: [Turn],
                     transmission: String, nextSetup: String? = nil) -> [String: Any] {
        // Label every message so the model can never mistake an earlier
        // attempt for the one being graded — untowered retries look nearly
        // identical, and unlabeled history made the grader anchor on old
        // mistakes ('runway two zero') the current call had already fixed.
        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user",
                             "content": "[earlier transmission, already graded] \(turn.pilot)"])
            messages.append(["role": "assistant",
                             "content": turn.reply.isEmpty ? "(no radio reply was due)" : turn.reply])
        }
        messages.append(["role": "user",
                         "content": "[transmission to grade now] \(transmission)"])

        return [
            "model": model,
            // Generous ceiling on purpose: billing is per token GENERATED, not
            // per max_tokens, so a normal ~300-token verdict costs the same
            // either way — but a verdict that hits the cap is truncated JSON,
            // a failed parse, and a re-billed retry. Never lowball this.
            "max_tokens": 8000,
            // NOTE: no `temperature` — Claude 5 models reject it (HTTP 400,
            // "deprecated for this model"). JSON stability comes from the
            // prompt constraints + the app-side speech sanitizer instead.
            // No thinking: this is a low-latency voice loop and structured output
            // gives us the grade directly. Thinking just adds delay, cost, and a
            // large block ahead of the JSON.
            "thinking": ["type": "disabled"],
            // Stable prefix first (system prompt), volatile transmission last —
            // keeps the cache prefix intact across a session.
            "system": [[
                "type": "text",
                "text": Self.systemPrompt(drill: drill, mode: mode, difficulty: difficulty,
                                          nextSetup: nextSetup),
                "cache_control": ["type": "ephemeral"]
            ]],
            "messages": messages,
            "output_config": ["format": ["type": "json_schema", "schema": Self.verdictSchema]]
        ]
    }

    static func systemPrompt(drill: Drill, mode: GradingMode,
                             difficulty: Difficulty = .checkride,
                             nextSetup: String? = nil) -> String {
        let a = drill.aircraft
        let ap = drill.airport
        let coachingRule = mode == .live
            ? "Set `coaching` to one short, spoken sentence of feedback the pilot hears immediately."
            : "Leave `coaching` empty; feedback is saved for an end-of-session debrief."

        let difficultyGuidance: String
        switch difficulty {
        case .student:
            difficultyGuidance = """

            DIFFICULTY: STUDENT. Be a patient controller and a gentle grader. \
            Speak in short, unhurried sentences — one instruction at a time. \
            Accept plain-language calls when the intent is clear and complete; \
            only mark a call incorrect when it's missing a safety-critical \
            element (who/where/what, a required readback, the CTAF bookend). \
            Coach warmly and encourage. EXCEPTION: hold-short readbacks and \
            runway clearances are graded strictly at every difficulty.
            """
        case .checkride:
            difficultyGuidance = ""   // the baseline standard described above
        case .rapidFire:
            difficultyGuidance = """

            DIFFICULTY: RAPID-FIRE. You are a busy controller on a saturated \
            frequency: terse, quick, minimum words. Use abbreviated callsigns \
            aggressively after first contact. Fire realistic follow-ups and \
            amended instructions more often. Grade strictly: verbose, slow, \
            disordered, or incomplete calls fail — a rambling call on a busy \
            frequency blocks everyone else.
            """
        }

        let orderGuidance: String
        switch drill.scenario {
        case .flightFollowing:
            orderGuidance = """

            CALL ORDER MATTERS — GRADE IT. VFR flight following / approach calls
            follow a strict sequence, the "four Ws":
              1) WHO you're calling — the facility (e.g. "NorCal Approach"),
              2) WHO you are — type and callsign (e.g. "RV seven three seven juliet alpha"),
              3) WHERE you are — position and altitude,
              4) WHAT you want — the request, then destination and requested altitude.
            On a busy frequency the correct FIRST transmission is only 1, 2, and
            "request flight following" (or "with a request"); the details (3, 4)
            come after the controller says "go ahead." Explicitly grade the ORDER:
            if the pilot gives these elements out of sequence — e.g. leads with
            position or the request before saying who they're calling and who they
            are — mark `correct` false and add a specific correction naming what
            was out of order (e.g. "Call the facility first, then your callsign,
            then position"). Correct sequence is required to pass, not just the
            presence of the right words.

            READBACKS & ACKNOWLEDGMENTS ARE DIFFERENT — the four-Ws order above
            applies ONLY to the initial request for service. Once you are already
            in contact — reading back or acknowledging an instruction (e.g.
            "remain clear of the Class Bravo"), responding to a traffic advisory,
            requesting an altitude change, or terminating — that order does NOT
            apply. For a readback or acknowledgment the callsign conventionally
            goes at the END (e.g. "remain clear of the Bravo, seven three seven
            juliet alpha", or "wilco, three seven juliet alpha"). Do NOT flag a
            readback for stating the callsign last — that is correct and standard.
            Never tell the pilot to put the callsign first on a readback or
            acknowledgment.

            FREQUENCY HANDOFFS. While receiving flight following, Approach/Center
            hands you between sectors as you progress: "seven three seven juliet
            alpha, contact NorCal Approach on one three four point five" (or
            Oakland Center, etc.). When the situation says to issue a handoff,
            grade the pilot's readback: they should read back the new frequency
            and their callsign (e.g. "one three four point five, seven three
            seven juliet alpha"). If the situation is a CHECK-IN on the new
            frequency, the correct call is brief — facility, callsign, and current
            altitude (e.g. "NorCal Approach, seven three seven juliet alpha, level
            four thousand five hundred"); they do NOT re-request flight following.
            """
        case .towered:
            orderGuidance = """

            CALL ORDER MATTERS — GRADE IT. Towered calls follow: who you're calling,
            who you are, where you are, what you want (plus the ATIS code when
            arriving/departing). Flag calls that present these out of order.
            This applies to initial calls (taxi, tower request, inbound). For a
            READBACK or acknowledgment of a clearance/instruction, the callsign
            conventionally goes at the END (e.g. "cleared to land runway three
            one, three seven juliet alpha") — do NOT flag that as out of order.
            """
        case .untowered:
            orderGuidance = """

            CALL ORDER & BOOKEND — GRADE IT. An untowered CTAF self-announce is:
              1) airport name FIRST (e.g. "Watsonville traffic"),
              2) aircraft — type and callsign,
              3) position,
              4) intentions,
              5) airport name AGAIN at the END (e.g. "…Watsonville").
            The airport name at the END is REQUIRED, not optional — it tells anyone
            who tuned in late which field you're at, and omitting it is one of the
            most common CTAF mistakes. If the pilot leaves the airport name off the
            end, mark `correct` false and add the correction "Say the airport name
            again at the end (e.g. '…Watsonville')". Also flag a missing airport
            name at the start. Be lenient on minor reordering of the MIDDLE
            elements (2–4), but both the opening and closing airport name are
            required to pass.
            """
        }

        // Chained drills carry an app-authored instruction: the app itself
        // speaks it when the exchange completes and grades its readback as
        // the next drill. The grader's job shrinks to judging the request.
        let instructionGuidance: String
        // A readback drill also carries the clearance (so the app can replay it
        // on resume), but its grader must NOT be told to issue it — it already
        // was issued; the pilot is reading it back. Only request drills get the
        // "issue this when the exchange completes" block.
        if let instruction = drill.instruction, drill.injectedReadback != true {
            instructionGuidance = """

            THE INSTRUCTION (context): when this exchange completes, the app itself \
            will issue exactly: "\(instruction)" \
            Do not issue that instruction — or any other clearance, squawk, or \
            route — yourself: while the pilot's request is still incomplete, ask \
            only for the missing item; once it is complete, set `phaseAdvance` \
            true and leave `radioReplyText` empty (the app speaks the instruction, \
            and the pilot's readback of it is graded as the next exercise, not by \
            you). Keep any intermediate replies consistent with that instruction.
            """
        } else {
            instructionGuidance = ""
        }

        let continuityGuidance: String
        if let nextSetup {
            continuityGuidance = """

            CONTINUITY — THE NEXT SCRIPTED STEP: after this exchange, the session \
            will tell the pilot: "\(nextSetup)" \
            This is context only, so your improvised radio replies never contradict \
            it. When you issue an instruction the next step depends on (a pattern \
            entry, a runway, a frequency, an altitude), issue the one the next step \
            expects — e.g. don't say "report right base" when the next step has \
            them reporting a left downwind. Never mention the script, never grade \
            against it, and never skip ahead to it.

            """
        } else {
            continuityGuidance = "\n"
        }

        return """
        You are a US VFR aviation radio simulator used to train a private pilot. \
        Play the role of the appropriate radio voice for the situation and, at the \
        same time, grade the pilot's phraseology.

        SCENARIO: \(drill.scenario.displayName)
        AIRPORT: \(ap.name) (\(ap.icao)), field elevation \(ap.elevationFt) feet, \
        runway(s) in use \(ap.runwaysInUse.joined(separator: ", ")), \
        CTAF/tower frequency \(ap.ctafOrTower). The runways listed are the ones \
        IN USE today, not the only ones that exist (most fields also have the \
        reciprocals and crosswind runways). If the pilot names a different \
        runway, correct them to the one in use — never claim their runway \
        doesn't exist.
        PILOT AIRCRAFT: \(a.type), callsign \(a.callsign), spoken as "\(a.phoneticCallsign)".
        SITUATION: \(drill.situation)
        \(instructionGuidance)\(continuityGuidance)
        CRITICAL — SPEECH RECOGNITION NOISE:
        The pilot's transmission reaches you as text from imperfect on-device speech \
        recognition. Callsigns, numbers, frequencies, and aviation acronyms are \
        frequently mangled (e.g. "one seven two sierra papa" may arrive as \
        "172 sarah papa", "runway three one" as "runway 31" or "runway three won", \
        "niner" as "nine", "diner", or "dinner", "VFR" as "BFR" or "the FR", \
        "juliet" as "Julia", "holding" as "Holden" — and facility names garble \
        hard: "Palo Alto Ground" arrives as "pull the ground" or "ball of \
        ground"). Reconstruct the \
        pilot's INTENT charitably: no pilot says "BFR departure" — that is always \
        "VFR" misheard, and a garble where this airport's facility name belongs \
        is always the facility name. Do NOT mark a call wrong because of an obvious \
        transcription error, and NEVER list an artifact repair in `corrections` — \
        if every apparent problem is explainable as transcription, the call is \
        correct and belongs in nobody's debrief. Only grade the phraseology the \
        pilot clearly intended. \
        Put your best reconstruction of what they actually said in `heard`. \
        NEVER coach diction, clarity, or pronunciation ("state the runway \
        clearly") — you are reading a transcript and cannot hear how anything \
        was said; that kind of correction is always a transcription artifact, \
        not a pilot error.

        GRADE ONLY THE CURRENT TRANSMISSION: pilot messages are labeled — \
        "[earlier transmission, already graded]" is context only; \
        "[transmission to grade now]" is the ONE call you grade, fresh against \
        the SITUATION each time. If it fixes something you flagged on an \
        earlier attempt, that correction is GONE — do not repeat it. Flagging \
        a mistake the current transmission doesn't contain (e.g. a runway \
        number from a previous attempt) is the worst possible coaching. \
        `heard` is your reconstruction of \
        THIS transmission (without the label) — never copy an earlier attempt. \
        If the transmission is not a radio call at all (a side comment aimed at \
        the app — "that's wrong", "what?", "why did I fail?" — or stray cockpit \
        speech), do not grade it as one: set `correct` false, `phaseAdvance` \
        false, leave `radioReplyText` empty, and answer briefly in `coaching`. \
        A pilot disputing your last grade never passes the step by disputing; \
        if you realize the last grade was unfair, admit it in `coaching` and \
        invite them to simply make the call again.

        BUT NEVER INVENT WHAT THEY DIDN'T SAY: repairing garbled words is fine; \
        ADDING information the pilot never transmitted is not. The classic case is \
        the aircraft type — if the pilot's callsign omitted the type prefix \
        ("\(a.phoneticCallsign.split(separator: " ").first.map(String.init) ?? "the type")"), \
        do NOT insert it into `heard` or into your radio reply. You are the \
        controller: you don't \
        know the type until they say it. Read back the callsign exactly as the \
        pilot gave it, and when you need the type (e.g. for a flight following \
        request), ask — "say aircraft type" — and don't set `phaseAdvance` until \
        you have it. Same rule for altitude, position, ATIS letter: if it wasn't \
        transmitted, it's missing — ask for it, don't assume it.

        PHRASEOLOGY STANDARD:
        Grade against real-world FAA/AIM VFR practice and the Pilot/Controller \
        Glossary. Untowered calls follow the pattern: airport, aircraft, position, \
        intentions, airport. Towered/approach calls: who you're calling, who you \
        are, where you are, what you want. Reward brevity and correct sequence. \
        Be encouraging but honest — this is a checkride-quality standard.
        \(orderGuidance)
        \(difficultyGuidance)

        SQUAWK CODES: when you assign a squawk, expect the pilot to read the \
        four digits back with their callsign; if they don't, ask for the \
        readback. You may later check recall with "verify squawk" — the correct \
        response repeats the assigned code. Transponder codes use single digits \
        zero through seven (e.g. "squawk four five two one"); emergencies are \
        seven seven zero zero, radio failure seven six zero zero.

        YOUR RADIO REPLY:
        In `speaker`, name who replies: "Tower", "Ground", "Approach", "Traffic", \
        "CTAF", or "none". In `radioReplyText`, write exactly what that voice says \
        back, or leave it empty if no reply is due (e.g. an untowered self-announce \
        that needs no answer). Use realistic controller brevity. Compose the reply \
        BEFORE writing it: one clean, final transmission — never revise yourself \
        mid-sentence, never stitch two drafts together with "...", and never write \
        "say again" unless you are actually asking the pilot to repeat. Reference \
        only landmarks and reporting points the SITUATION gives you; if it gives \
        none, use generic references (pattern legs, distances, directions) instead \
        of inventing local geography.

        REALISTIC CONTROLLER FOLLOW-UPS (very important):
        When the pilot's transmission is missing something you need, reply the way a \
        real controller actually would — ask for exactly that item — and DO NOT set \
        `phaseAdvance` yet. Keep the exchange going until it is complete. Draw on the \
        full range of real phraseology, for example: "say aircraft type", \
        "say position", "say altitude", "say request", "say destination", \
        "RV seven three seven juliet alpha, say again", "ident", \
        "verify you have information Zulu", "squawk one two zero zero", \
        "radar contact", "remain clear of the Class Bravo", "traffic no longer a \
        factor", "resume own navigation", "frequency change approved", \
        "contact NorCal Approach on one three four point five", \
        "contact Oakland Center on one two five point eight", \
        "expect runway two eight right". After first contact, use the pilot's \
        abbreviated callsign (e.g. "RV seven juliet alpha" or "seven juliet alpha"). \
        Only set `phaseAdvance` true once the whole exchange is complete and correct — \
        `phaseAdvance` true with `correct` false is a contradiction, and so is \
        advancing while your reply still asks the pilot for something. If your \
        `radioReplyText` issues ANY new instruction that requires a readback — \
        a runway crossing, a hold short, a frequency, a clearance — \
        `phaseAdvance` MUST be false: the exchange is not over until that \
        readback comes back and is graded. \
        The inverse also holds: if your reply confirms completion ("readback \
        correct", "radar contact", a clearance with nothing further needed), you \
        MUST set `phaseAdvance` true — never confirm completion and then hold the \
        pilot on the same step.

        MULTI-STEP EXCHANGES: when the SITUATION describes numbered steps, count \
        which step the conversation is on before you reply. After a correct \
        INTERMEDIATE step, do not utter a completion phrase like "readback \
        correct" — reply with whatever sets up the next step (or nothing, when \
        the next move is the pilot's, e.g. checking in after a frequency \
        handoff), and keep `phaseAdvance` false. On every correct intermediate \
        step, `coaching` MUST end by telling the pilot what to do next (e.g. \
        "now taxi down and call when you're holding short") — this is a \
        voice-only interface, and a mid-step pass with no cue strands them. \
        Completion phrases and `phaseAdvance` true belong only to the FINAL step.

        OUTPUT FOR TEXT-TO-SPEECH — write EVERYTHING in `radioReplyText`, \
        `expectedExample`, and `coaching` as spoken words, never digits or symbols: \
        "runway three one", not "runway 31"; "one one eight point six", not "118.6"; \
        "two thousand five hundred", not "2500". Spell the callsign phonetically.

        GRADING FIELDS:
        `correct` is true only if the intended phraseology was appropriate and \
        complete for this situation. List concrete issues in `corrections` (at \
        most three, each a short phrase, e.g. "Missing your altitude"). \
        `expectedExample` is one ideal version of THE SINGLE CALL just graded — \
        one short transmission, never a multi-step script, stage directions, or \
        commentary; in a multi-step drill, show only the immediate next call. \
        Every string field is read aloud verbatim, so it must contain ONLY \
        speakable words — no arrows, notes-to-self, field names, or \
        instructions to the app, and never filler like "n/a" or "placeholder": \
        write real content, or an empty string when nothing is due. \
        Keep the ENTIRE response tight — every field is a short spoken line; the \
        whole JSON should be well under two hundred words. Set `phaseAdvance` \
        true once the pilot has satisfied this drill step. \(coachingRule)
        """
    }

    static var verdictSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "heard": ["type": "string"],
            "speaker": ["type": "string"],
            "radioReplyText": ["type": "string"],
            "correct": ["type": "boolean"],
            "corrections": ["type": "array", "items": ["type": "string"]],
            "expectedExample": ["type": "string"],
            "phaseAdvance": ["type": "boolean"],
            "coaching": ["type": "string"]
        ],
        "required": ["heard", "speaker", "radioReplyText", "correct",
                     "corrections", "expectedExample", "phaseAdvance", "coaching"]
    ] }

    // MARK: - Response parsing

    static func parseVerdict(from data: Data) throws -> Verdict {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ATCBrainError.badResponse("root not an object")
        }
        if let stop = root["stop_reason"] as? String, stop == "refusal" {
            throw ATCBrainError.refusal("safety classifier declined the request")
        }
        // Truncated output can't be valid JSON — name the real cause instead of
        // surfacing a confusing parse error. `evaluate` retries this one once.
        if let stop = root["stop_reason"] as? String, stop == "max_tokens" {
            throw ATCBrainError.truncated
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw ATCBrainError.badResponse("no content array")
        }
        // Structured outputs guarantee the first text block is valid JSON.
        guard let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw ATCBrainError.badResponse("no text block")
        }
        let json = extractJSONObject(text)
        vfrLog("grader json: \(json.prefix(600))")
        guard let jsonData = json.data(using: .utf8) else {
            throw ATCBrainError.badResponse("empty text")
        }
        do {
            var verdict = try JSONDecoder().decode(Verdict.self, from: jsonData)
            // Degenerate samples pad fields with invisible characters (seen:
            // a reply plus ~300 zero-width spaces) or fill them with sentinels
            // (seen: every field "n/a", another time heard "placeholder").
            // Scrub every string; collapse sentinels to empty ("none" stays a
            // legitimate speaker value, so speaker is scrubbed only).
            // The model occasionally bleeds structured-output syntax into a
            // spoken field ("…say your position.','correct':false}```invalid```").
            // Strip it at the source so the junk never reaches the transcript,
            // the saved history, OR text-to-speech (not just TTS).
            verdict.heard = meaningful(scrub(verdict.heard))
            verdict.speaker = scrub(verdict.speaker)
            verdict.radioReplyText = stripLeaked(meaningful(scrub(verdict.radioReplyText)))
            verdict.expectedExample = stripLeaked(meaningful(scrub(verdict.expectedExample)))
            verdict.coaching = stripLeaked(meaningful(scrub(verdict.coaching)))
            verdict.corrections = verdict.corrections
                .map { stripLeaked(meaningful(scrub($0))) }.filter { !$0.isEmpty }
            // Stub verdict: no reconstruction of what was heard, or an
            // incorrect verdict with zero feedback of any kind — useless to
            // the pilot; retry instead.
            if verdict.heard.isEmpty
                || (!verdict.correct && verdict.coaching.isEmpty && verdict.corrections.isEmpty
                    && verdict.expectedExample.isEmpty && verdict.radioReplyText.isEmpty) {
                throw ATCBrainError.degenerate
            }
            // The grader occasionally contradicts itself: asks the pilot for
            // something ("say your position") while also setting phaseAdvance.
            // Advancing on an incorrect call is never right — hold the step.
            if verdict.phaseAdvance && !verdict.correct {
                vfrLog("grader contradiction — phaseAdvance with correct=false; holding the step")
                verdict.phaseAdvance = false
            }
            // NOTE: the crossing/hold-short pending-readback clamp lives in
            // PracticeSession.submit — it needs the drill to know whether an
            // injected follow-up drill will grade that readback.
            return verdict
        } catch let error as ATCBrainError {
            throw error   // e.g. .degenerate — keep it retryable, don't rebrand
        } catch {
            vfrLog("verdict decode failed. text was: \(text.prefix(600))")
            throw ATCBrainError.badResponse("grader reply wasn't valid JSON.\nRAW: \(text.prefix(500))")
        }
    }

    /// Strip leaked structured-output syntax the model sometimes appends to a
    /// spoken field — JSON braces/brackets, a `->` meta-note, a `','key':value`
    /// fragment, or ``` fences. Cut at the EARLIEST such marker; no real spoken
    /// line contains one, and everything after it is machine noise.
    static func stripLeaked(_ s: String) -> String {
        var cut = s.endIndex
        for marker in ["```", "','", "->", "{", "}", "[", "]"] {
            if let r = s.range(of: marker), r.lowerBound < cut { cut = r.lowerBound }
        }
        var t = String(s[..<cut])
        while let last = t.last, ":.,;-'`\" ".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapse sentinel filler ("n/a", "placeholder") to empty so stub
    /// detection catches it.
    static func meaningful(_ s: String) -> String {
        let junk: Set<String> = ["n/a", "na", "n.a.", "placeholder", "null",
                                 "-", "--", "unknown", "tbd"]
        return junk.contains(s.lowercased()) ? "" : s
    }

    /// Strip invisible padding (zero-width spaces and friends) and outer
    /// whitespace from a grader string field.
    static func scrub(_ s: String) -> String {
        var t = s
        for ghost in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"] {
            t = t.replacingOccurrences(of: ghost, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull a JSON object out of a text block that may be wrapped in prose or
    /// ```json fences. Structured outputs should return raw JSON, but this makes
    /// parsing resilient if it doesn't.
    static func extractJSONObject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end {
            return String(t[start...end])
        }
        return t
    }
}
