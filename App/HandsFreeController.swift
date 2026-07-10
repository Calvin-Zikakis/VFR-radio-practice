import Foundation
import AVFoundation
import UIKit
import VFRCore

/// Orchestrates a practice session in either input mode:
///  - hands-free: an internal loop auto-listens (silence detection) and advances.
///  - push-to-talk: the UI drives via `talkDown()` / `talkUp()`.
/// Voice commands ("next", "repeat", "stop") work in both.
@MainActor
final class HandsFreeController: ObservableObject {
    enum Phase: Equatable { case idle, briefing, listening, thinking, replying, readyToTalk, paused, finished }

    struct Line: Identifiable, Equatable {
        enum Role { case instructor, pilot, radio, system }
        let id = UUID()
        let role: Role
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: [Line] = []
    @Published private(set) var currentSetup = ""
    @Published private(set) var progressText = ""
    @Published private(set) var lastVerdict: Verdict?
    @Published private(set) var debrief: [PracticeSession.DebriefEntry] = []
    /// The airplane this session is being flown in, shown in the on-screen banner.
    @Published private(set) var aircraft: Aircraft?
    @Published var errorMessage: String?

    /// Fires each time a call is graded, so the UI can flash a glow + haptic.
    struct ResultFlash: Equatable { let id = UUID(); let success: Bool }
    @Published private(set) var lastResult: ResultFlash?

    let speech = SpeechRecognizer()
    let speaker = RadioSpeaker()

    private var session: PracticeSession?
    /// The in-flight grading call, so "redo" can abort it without waiting.
    private var gradeTask: Task<Verdict?, Error>?
    /// Bumped by `redoCall()`; a graded turn whose id is stale gets discarded.
    private var turnID = 0
    private var mode: GradingMode = .live
    private var interaction: InteractionMode = .handsFree
    private var pause: Double = 2.0
    private var scenario: ScenarioType?
    private var trip: TripPlan?
    private var callTypes: Set<CallType>?
    private var busy = false            // busy-frequency simulation
    private var echo = false            // read the model call after a miss
    private var sessionLabel = ""       // human name for the snapshot / resume card
    /// Model call for the drill in play (from its last verdict, or fetched on
    /// demand by the "example" voice command). Cleared at each briefing.
    private var currentExample: String?
    private var sessionDrills: [Drill] = []   // exact drills in play (post-randomize)
    private weak var settings: SettingsStore?
    private var runTask: Task<Void, Never>?
    /// True while `handsFreeLoop` is running, so a mid-session mode switch
    /// never starts a second loop alongside it.
    private var loopActive = false

    var isRunning: Bool { phase != .idle && phase != .finished }

    /// How many drills this session holds (for the finish scorecard).
    var totalDrills: Int { sessionDrills.count }

    init() {
        // Auto-pause when the audio session is interrupted (phone call, Siri,
        // another app grabbing audio) and resume when the system says it's ok.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
                    if self.isRunning, self.phase != .paused { self.pauseSession() }
                } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue,
                          AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume),
                          self.phase == .paused {
                    self.resumeSession()
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Practice a single scenario's drills, optionally starting from a chosen
    /// drill (from the drill browser). A chosen start point keeps library
    /// order so "start from here" means what it says.
    func start(scenario: ScenarioType, settings: SettingsStore, startingAt startIndex: Int = 0) {
        self.scenario = scenario
        self.trip = nil
        self.callTypes = nil
        beginSession(settings: settings, label: scenario.displayName, startIndex: startIndex) { plane in
            let drills = DrillLibrary.drills(for: scenario, aircraft: plane)
            return (settings.randomizeDrills && startIndex == 0) ? drills.shuffled() : drills
        }
    }

    /// Fly a full cross-country trip — the generated, ordered call sequence.
    /// `startingAt` lets you join the flight mid-stream (e.g. skip the taxi
    /// calls you've already got cold).
    func start(trip: TripPlan, settings: SettingsStore, startingAt startIndex: Int = 0) {
        self.scenario = nil
        self.trip = trip
        self.callTypes = nil
        let label = "Trip: " + trip.stops.map(\.name).joined(separator: " → ")
        beginSession(settings: settings, label: label, startIndex: startIndex) { plane in
            TripBuilder.drills(for: trip, aircraft: plane)   // order is the point; never shuffled
        }
    }

    /// Practice a focused mix of specific call types, shuffled from the library.
    func start(callTypes: Set<CallType>, settings: SettingsStore) {
        self.scenario = nil
        self.trip = nil
        self.callTypes = callTypes
        // One type reads as a focused session ("Ground / Taxi"), not a mix.
        let label = callTypes.count == 1
            ? (callTypes.first?.displayName ?? "Mix")
            : "Mix (\(callTypes.count) call types)"
        beginSession(settings: settings, label: label) { plane in
            DrillLibrary.drills(matching: callTypes, aircraft: plane).shuffled()
        }
    }

    /// Pick up a snapshotted session exactly where it left off — same drills
    /// (randomized details intact), same position, same debrief and transcript.
    func resume(from snap: SessionSnapshot, settings: SettingsStore) {
        self.scenario = nil
        self.trip = nil
        self.callTypes = nil
        beginSession(settings: settings,
                     label: snap.label,
                     startIndex: snap.drillIndex,
                     restoredDebrief: snap.debrief,
                     restoredTranscript: snap.transcript.map {
                         Line(role: Line.Role(storageKey: $0.role), text: $0.text)
                     },
                     fixedAircraft: snap.aircraft,
                     applyVariation: false) { _ in snap.drills }
    }

    /// Shared setup for every entry point. `makeDrills` is called synchronously
    /// with the chosen airplane to produce the ordered drill list.
    private func beginSession(settings: SettingsStore,
                              label: String,
                              startIndex: Int = 0,
                              restoredDebrief: [PracticeSession.DebriefEntry] = [],
                              restoredTranscript: [Line] = [],
                              fixedAircraft: Aircraft? = nil,
                              applyVariation: Bool = true,
                              makeDrills: (Aircraft) -> [Drill]) {
        stop()
        errorMessage = nil
        transcript = restoredTranscript
        lastVerdict = nil
        debrief = restoredDebrief
        self.settings = settings
        self.sessionLabel = label

        guard settings.isConfigured else {
            errorMessage = "Add your Anthropic API key in Settings first."
            return
        }
        let brain = ATCBrain(apiKey: settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                             model: settings.model,
                             difficulty: settings.difficulty)
        mode = settings.gradingMode
        interaction = settings.interactionMode
        pause = settings.endOfSpeechPause
        busy = settings.busyFrequency
        echo = settings.echoModelCall
        speaker.voiceIdentifier = settings.voiceIdentifier
        speaker.speechRate = Float(settings.speechRate)
        // Rapid-fire controllers talk noticeably faster.
        speaker.controllerRate = Float(settings.controllerSpeechRate)
            + (settings.difficulty == .rapidFire ? 0.06 : 0)
        speaker.radioEffect = settings.radioEffect

        // One airplane per session. Resume keeps the snapshot's plane; otherwise
        // fly the pinned plane, or a random one from the fleet. The banner names it.
        let plane: Aircraft
        if let fixedAircraft {
            plane = fixedAircraft
        } else {
            let fleet = settings.aircraftFleet.isEmpty ? DrillLibrary.fleet : settings.aircraftFleet
            if !settings.selectedAircraftCallsign.isEmpty,
               let match = fleet.first(where: { $0.callsign == settings.selectedAircraftCallsign }) {
                plane = match
            } else {
                plane = fleet.randomElement() ?? DrillLibrary.defaultAircraft
            }
        }
        aircraft = plane
        // Vary incidental details (ATIS letter, distances, squawk codes) so
        // repeat sessions can't be answered from memory. Never re-vary a
        // resumed session — its details are already baked into the snapshot.
        let made = makeDrills(plane)
        sessionDrills = (applyVariation && settings.varyDetails) ? DrillRandomizer.vary(made) : made
        session = PracticeSession(brain: brain, mode: mode, drills: sessionDrills,
                                  startIndex: startIndex, debrief: restoredDebrief)
        // Don't let the screen lock mid-session — it kills the microphone,
        // and this app's whole point is long hands-free stretches.
        UIApplication.shared.isIdleTimerDisabled = true
        runTask = Task { [weak self] in await self?.begin() }
    }

    // MARK: - Snapshot persistence (resume across app launches)

    /// Save a resumable picture of the session. Called after every state
    /// change, so quitting the app loses at most the in-progress utterance.
    private func persistSnapshot() async {
        guard let session, let aircraft else { return }
        let progress = await session.progress
        guard progress.drillIndex < progress.totalDrills else { return }
        let snap = SessionSnapshot(
            label: sessionLabel,
            mode: mode,
            // Live list, not the original: injected readback drills must
            // survive a resume or the saved index points at the wrong drill.
            drills: await session.liveDrills,
            drillIndex: progress.drillIndex,
            aircraft: aircraft,
            debrief: await session.debrief,
            transcript: transcript.map { .init(role: $0.role.storageKey, text: $0.text) },
            savedAt: Date())
        ResumeStore.save(snap)
    }

    // MARK: - Pause / resume (hands-free)

    /// Halt listening and speech without losing session progress.
    func pauseSession() {
        guard isRunning, phase != .paused else { return }
        runTask?.cancel()
        runTask = nil
        speech.cancel()
        speaker.stop()
        phase = .paused
        append(.system, "Paused.")
    }

    /// Pick the session back up. Fresh drill: re-brief it. Mid-exchange
    /// (the controller already said something and is waiting on the pilot):
    /// re-briefing would restart the script — re-anchor by replaying the
    /// controller's last transmission instead.
    func resumeSession() {
        guard phase == .paused else { return }
        append(.system, "Resuming.")
        runTask = Task { [weak self] in
            guard let self else { return }
            if await self.session?.isMidExchange == true {
                self.phase = .briefing
                if let reply = await self.session?.lastRadioReply {
                    await self.speakInstructor("Resuming where you left off. They last said:")
                    self.append(.radio, "(again) \(reply)")
                    await self.speaker.speak(reply, as: .controller)
                } else {
                    await self.speakInstructor("Resuming where you left off — it's your call.")
                }
            } else {
                await self.briefCurrent()
            }
            if self.interaction == .handsFree {
                await self.handsFreeLoop()
            } else if self.phase != .finished {
                self.phase = .readyToTalk
            }
        }
    }

    func restart() {
        guard let settings else { return }
        if let callTypes { start(callTypes: callTypes, settings: settings) }
        else if let trip { start(trip: trip, settings: settings) }
        else if let scenario { start(scenario: scenario, settings: settings) }
        else if !sessionDrills.isEmpty {
            // Resumed session: run the same drill set again from the top.
            let drills = sessionDrills
            beginSession(settings: settings, label: sessionLabel,
                         fixedAircraft: aircraft, applyVariation: false) { _ in drills }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        gradeTask?.cancel()
        gradeTask = nil
        speech.cancel()
        speaker.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle   // always return to the home screen
    }

    /// Abort the in-flight grading and take the call again — no waiting for
    /// the response you already know you flubbed.
    func redoCall() {
        guard phase == .thinking else { return }
        turnID += 1          // whatever comes back for the old turn is discarded
        gradeTask?.cancel()  // abort the network call outright
        append(.system, "Redo — say it again.")
    }

    // MARK: - Push-to-talk entry points

    func talkDown() {
        guard interaction == .pushToTalk, phase == .readyToTalk else { return }
        phase = .listening
        do { try speech.start() }
        catch { errorMessage = error.localizedDescription; phase = .readyToTalk }
    }

    func talkUp() {
        guard interaction == .pushToTalk, phase == .listening else { return }
        phase = .thinking
        Task {
            let text = await speech.stopAndCollect()
            await process(text)
        }
    }

    // MARK: - On-screen nav (both modes; safe when not mid-listen in hands-free)

    func repeatBriefing() {
        Task { await speaker.speak(currentSetup, as: .instructor, volume: repeatVolume) }
    }

    func skipCurrent() {
        Task {
            if interaction == .handsFree, phase == .listening {
                // Close the open mic first — otherwise the next briefing gets
                // captured as the pilot's transmission — then rejoin the loop.
                runTask?.cancel()
                runTask = nil
                speech.cancel()
                await performSkip()
                if phase != .finished {
                    runTask = Task { [weak self] in await self?.handsFreeLoop() }
                }
                return
            }
            await performSkip()
            if interaction == .pushToTalk, phase != .finished { phase = .readyToTalk }
        }
    }

    // MARK: - Core

    private func begin() async {
        vfrLog("begin() — requesting authorization")
        guard await speech.requestAuthorization() else {
            errorMessage = "Microphone or speech permission denied."
            phase = .idle
            return
        }
        vfrLog("authorized. interaction=\(interaction)")
        await briefCurrent()
        vfrLog("first briefing complete")
        if interaction == .handsFree {
            await handsFreeLoop()
        } else if phase != .finished {
            phase = .readyToTalk
        }
    }

    private func handsFreeLoop() async {
        loopActive = true
        defer { loopActive = false }
        while !Task.isCancelled {
            guard await session?.currentDrill != nil else { return }
            phase = .listening
            vfrLog("listening (silence timeout \(pause)s)")
            let text: String
            do { text = try await speech.listenWithSilence(timeout: pause, idleLimit: 30) }
            catch {
                vfrLog("listen error: \(error)")
                errorMessage = error.localizedDescription; phase = .idle; return
            }
            vfrLog("heard: \(text.isEmpty ? "<nothing>" : text)")
            if Task.isCancelled { return }
            // Nothing at all for 30s: the pilot has stepped away — pause
            // instead of listening forever (and burning the mic + screen).
            if text.isEmpty, speech.lastListenIdledOut {
                append(.system, "No radio calls for 30 seconds.")
                pauseSession()
                await speaker.speak("Pausing the session. Tap play when you're ready.",
                                    as: .instructor, volume: repeatVolume)
                return
            }
            let finished = await process(text)
            if finished { return }
        }
    }

    private func briefCurrent() async {
        guard let drill = await session?.currentDrill else { await finish(); return }
        currentSetup = drill.setup
        currentExample = nil
        // Bias the recognizer toward this drill's proper nouns so it stops
        // hearing "Julia" for "juliet" and "Reid Hillview" as random words.
        speech.contextualPhrases = [
            drill.aircraft.phoneticCallsign,
            drill.aircraft.callsign,
            drill.airport.name,
            "\(drill.airport.name) traffic",
            "\(drill.airport.name) Tower",
            "\(drill.airport.name) Ground",
            "NorCal Approach",
        ] + drill.airport.runwaysInUse.map { "runway \(TripBuilder.spokenRunway($0))" }
        progressText = await progressLabel()
        append(.instructor, drill.setup)
        phase = .briefing
        vfrLog("briefing drill '\(drill.title)'")
        await persistSnapshot()
        await speakInstructor(drill.setup)

        // Busy frequency: sometimes another aircraft gets a word in before you.
        if busy, Double.random(in: 0..<1) < 0.35, let line = Self.chatter.randomElement() {
            append(.radio, "Radio: \(line)")
            await speaker.speak(line, as: .traffic)
        }
    }

    /// Background calls from other aircraft for the busy-frequency simulation.
    private static let chatter = [
        "Cessna four two one five foxtrot, traffic is a Cirrus at your two o'clock, three miles, southbound.",
        "Skyhawk six niner two bravo kilo, roger, report midfield downwind.",
        "Cherokee four eight two zero lima, number two, follow the Skyhawk on downwind.",
        "Bonanza niner zero one seven quebec, radar contact, say requested altitude.",
        "Citation five five papa golf, descend and maintain four thousand, expect the visual.",
        "Cirrus three four six delta victor, squawk five two four one and ident."
    ]

    /// Instructor speech is governed by the global volume sliders, the same in
    /// both input modes: zero silences it everywhere, anything above zero
    /// speaks everywhere at that level. Read live from settings so slider
    /// changes apply mid-session. Radio replies are always spoken.
    private func speakInstructor(_ text: String) async {
        await speaker.speak(text, as: .instructor,
                            volume: Float(settings?.instructorVolume ?? 1))
    }

    /// Polish notes on a PASSED call have their own volume slider.
    private func speakPassNote(_ text: String) async {
        await speaker.speak(text, as: .instructor,
                            volume: Float(settings?.passNotesVolume ?? 0))
    }

    /// An explicit "repeat" (button tap or voice command) should be audible
    /// even with the instructor volume at zero — the pilot just asked for it.
    private var repeatVolume: Float {
        let v = Float(settings?.instructorVolume ?? 1)
        return v > 0.001 ? v : 1
    }

    /// Voice command "example": read the model call for the drill in play.
    /// Uses the example from this drill's last grading when there is one;
    /// otherwise asks the grader for it (without it counting as an attempt).
    private func speakExample() async {
        if currentExample == nil {
            phase = .thinking
            currentExample = try? await session?.modelExample()
        }
        guard let ex = currentExample, !ex.isEmpty else {
            append(.system, "Couldn't fetch the model call.")
            await speaker.speak("Couldn't fetch the model call — just try your call.",
                                as: .instructor, volume: repeatVolume)
            return
        }
        append(.system, "Model call: \(ex)")
        await speaker.speak("Here's the model call. \(ex)", as: .instructor, volume: repeatVolume)
    }

    /// Handle one pilot transmission. Returns true if the session finished.
    @discardableResult
    private func process(_ text: String) async -> Bool {
        guard let session else { return true }

        switch navCommand(text) {
        case .stop:
            stop(); return true
        case .pause:
            pauseSession(); return true
        case .skip:
            await performSkip()
            return await settleAfterTurn()
        case .repeatSetup:
            append(.system, "Say again.")
            await speaker.speak(currentSetup, as: .instructor, volume: repeatVolume)
            return await settleAfterTurn()
        case .example:
            await speakExample()
            return await settleAfterTurn()
        case .none:
            break
        }

        append(.pilot, text)

        // Busy frequency: occasionally your transmission gets stepped on and
        // you have to say it again — just like a real Saturday morning.
        if busy, !text.isEmpty, Double.random(in: 0..<1) < 0.15 {
            append(.radio, "Radio: Two aircraft calling at the same time — say again.")
            await speaker.speak("Two aircraft calling at the same time. Say again.", as: .controller)
            return await settleAfterTurn()
        }

        phase = .thinking
        let myTurn = turnID
        let gradedDrill = await session.currentDrill
        do {
            // Grade in a child task so `redoCall()` can cancel it mid-flight.
            let task = Task { try await session.submit(text) }
            gradeTask = task
            defer { gradeTask = nil }
            let graded = try await task.value
            // Redone while grading: throw the stale verdict away and re-listen.
            guard myTurn == turnID else { return await settleAfterTurn() }
            guard let verdict = graded else { return true }
            vfrLog("verdict correct=\(verdict.correct) advance=\(verdict.phaseAdvance) speaker=\(verdict.speaker) reply=\"\(verdict.radioReplyText)\" coaching=\"\(verdict.coaching)\" corrections=\(verdict.corrections)")
            lastVerdict = verdict
            // Cache the model call only while the same call is still on deck.
            // expectedExample describes the call JUST GRADED — after a correct
            // mid-step call the exchange moves on, and reading the old example
            // would model the wrong (previous) transmission. Clearing it makes
            // "example" fetch fresh, with history, yielding the next step's call.
            if verdict.correct && !verdict.phaseAdvance {
                currentExample = nil
            } else if !verdict.expectedExample.isEmpty {
                currentExample = verdict.expectedExample
            }
            // Red means exactly one thing: "say that again." A call can be
            // correct without advancing (mid-step of a multi-turn exchange) or
            // advance despite minor notes — both of those are green.
            lastResult = ResultFlash(success: verdict.correct || verdict.phaseAdvance)
            if let gradedDrill {
                StatsStore.shared.record(callType: DrillLibrary.callType(for: gradedDrill),
                                         passed: verdict.phaseAdvance)
            }
            phase = .replying

            var spoke = false
            if !verdict.radioReplyText.isEmpty {
                append(.radio, "\(verdict.speaker): \(verdict.radioReplyText)")
                await speaker.speak(verdict.radioReplyText, as: .controller)
                spoke = true
            }
            if mode == .live && !verdict.coaching.isEmpty {
                // Notes always show on screen. Spoken loudness comes from the
                // global sliders, keyed off CORRECTNESS (not advancement):
                // any green call's note — including a correct mid-step call's
                // "now do X" cue — is a pass note; only coaching on a miss
                // speaks at instructor volume. With pass notes at zero, cues
                // for multi-step drills are on screen only.
                append(.system, verdict.coaching)
                if !verdict.correct {
                    await speakInstructor(verdict.coaching)
                    spoke = true
                } else {
                    await speakPassNote(verdict.coaching)
                }
            }

            if verdict.phaseAdvance {
                if await session.currentDrill == nil { await finish(); return true }
                await briefCurrent()
            } else {
                // Shadow practice: read the model call so the pilot can echo it.
                if echo, !verdict.expectedExample.isEmpty {
                    append(.system, "Model call: \(verdict.expectedExample)")
                    await speakInstructor("Here's the model call. \(verdict.expectedExample)")
                } else if !spoke {
                    await speakInstructor("Try that again.")
                }
            }
        } catch {
            // A redo cancels the network call — that lands here. Quietly go
            // back to listening; it's not an error.
            if myTurn != turnID || error is CancellationError {
                return await settleAfterTurn()
            }
            // Debug: surface the actual error (API status/body or raw model text)
            // in the transcript instead of a generic message.
            let detail = error.localizedDescription
            vfrLog("brain error: \(detail)")
            errorMessage = detail
            append(.system, "⚠️ \(detail)")
            await speakInstructor("Say again, I didn't catch that.")
        }
        await persistSnapshot()
        return await settleAfterTurn()
    }

    /// Put the UI back into a ready state after a turn. In push-to-talk that
    /// means waiting for the button; if the user switched to hands-free while
    /// this button-driven turn was in flight, hand off to the auto-listen loop.
    private func settleAfterTurn() async -> Bool {
        if phase == .finished { return true }
        if interaction == .pushToTalk {
            phase = .readyToTalk
        } else if !loopActive {
            runTask?.cancel()
            runTask = Task { [weak self] in await self?.handsFreeLoop() }
        }
        return false
    }

    /// Switch input mode mid-session (the Settings sheet changed it while
    /// running). Hands-free needs its auto-listen loop started or stopped —
    /// without this, flipping the setting changed the UI but left the session
    /// deaf.
    func setInteraction(_ new: InteractionMode) {
        guard new != interaction else { return }
        interaction = new
        guard isRunning, phase != .paused else { return }   // resumeSession honors the new mode
        if new == .handsFree {
            append(.system, "Hands-free — just talk.")
            switch phase {
            case .readyToTalk:
                guard !loopActive else { break }
                runTask?.cancel()
                runTask = Task { [weak self] in await self?.handsFreeLoop() }
            case .listening:
                // Mid button press: treat the switch as releasing the button;
                // settleAfterTurn then hands off to the loop.
                phase = .thinking
                Task { [weak self] in
                    guard let self else { return }
                    let text = await self.speech.stopAndCollect()
                    await self.process(text)
                }
            default:
                break   // in-flight turn ends in settleAfterTurn, which starts the loop
            }
        } else {
            append(.system, "Push-to-talk — hold the button.")
            // Stop the auto-listen loop; the button drives from here. Cancel
            // the task first so the loop discards the aborted listen instead
            // of grading it.
            runTask?.cancel()
            runTask = nil
            if phase == .listening {
                speech.cancel()
                phase = .readyToTalk
            }
            // Briefing/thinking/replying turns settle to .readyToTalk on their own.
        }
    }

    private func performSkip() async {
        guard let session else { return }
        await session.skip()
        if await session.currentDrill == nil {
            await finish()
        } else {
            append(.system, "Skipping.")
            await briefCurrent()
        }
    }

    private func finish() async {
        phase = .finished
        debrief = await session?.debrief ?? []
        ResumeStore.clear()   // a finished session isn't resumable
        UIApplication.shared.isIdleTimerDisabled = false
        await speakInstructor(debriefSummary())
    }

    // MARK: - Helpers

    private enum NavCommand { case none, skip, repeatSetup, stop, pause, example }

    private func navCommand(_ text: String) -> NavCommand {
        let t = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard t.split(separator: " ").count <= 3 else { return .none }
        if t == "skip" || t == "next" || t == "move on" { return .skip }
        if t == "repeat" || t == "say again" || t == "again" { return .repeatSetup }
        if t == "stop" || t == "quit" { return .stop }
        if t == "pause" || t == "hold on" { return .pause }
        if t == "example" || t == "model call" || t == "give me example" { return .example }
        return .none
    }

    private func append(_ role: Line.Role, _ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        transcript.append(Line(role: role, text: clean))
    }

    private func progressLabel() async -> String {
        guard let session else { return "" }
        let p = await session.progress
        return "Drill \(min(p.drillIndex + 1, p.totalDrills)) of \(p.totalDrills)"
    }

    private func debriefSummary() -> String {
        if debrief.isEmpty { return "Session complete. Every call was on the money. Nicely flown." }
        return "Session complete. We flagged \(debrief.count) call\(debrief.count == 1 ? "" : "s") to review. Check the debrief on screen."
    }
}

// Stringly-typed Role round-tripping for the session snapshot.
extension HandsFreeController.Line.Role {
    var storageKey: String {
        switch self {
        case .instructor: return "instructor"
        case .pilot: return "pilot"
        case .radio: return "radio"
        case .system: return "system"
        }
    }

    init(storageKey: String) {
        switch storageKey {
        case "instructor": self = .instructor
        case "pilot": self = .pilot
        case "radio": self = .radio
        default: self = .system
        }
    }
}
