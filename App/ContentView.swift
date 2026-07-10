import SwiftUI
import UIKit
import VFRCore

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var controller = HandsFreeController()

    @State private var scenario: ScenarioType = .untowered
    /// Single-mode "Taxi" tile: a session of just the Ground/Taxi drills.
    @State private var taxiFocus = false
    @State private var showSettings = false
    @State private var showDrillBrowser = false
    @State private var glowColor: Color?
    @State private var resumeSnapshot: SessionSnapshot?

    // Session-building mode + trip configuration.
    enum SessionMode: String, CaseIterable, Hashable {
        case single, trip, mix
        var displayName: String {
            switch self {
            case .single: return "Single"
            case .trip: return "Trip"
            case .mix: return "Mix"
            }
        }
    }
    @State private var sessionMode: SessionMode = .single
    @State private var tripStops: [Airport] = DrillLibrary.defaultTripStops
    @State private var tripFF = true
    @State private var tripPattern = true
    @State private var selectedCallTypes: Set<CallType> = Set(CallType.allCases)

    private var tripPlan: TripPlan {
        TripPlan(stops: tripStops, flightFollowing: tripFF, patternWork: tripPattern)
    }

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 14) {
                header
                if controller.isRunning || controller.phase == .finished {
                    liveSession
                        .transition(.opacity)
                } else {
                    setup
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: 640)   // keep iPad layouts from stretching edge-to-edge
            .animation(.easeInOut(duration: 0.2), value: controller.isRunning)
        }
        .tint(Theme.accent)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
                .preferredColorScheme(preferredScheme)
        }
        .sheet(isPresented: $showDrillBrowser) {
            switch sessionMode {
            case .single:
                if taxiFocus {
                    // Browse-only: taxi sessions are shuffled, so there's no
                    // meaningful "start from here".
                    DrillBrowserView(title: "Ground / Taxi",
                                     drills: DrillLibrary.drills(matching: [.taxi],
                                                                 aircraft: DrillLibrary.defaultAircraft)) { _ in
                        showDrillBrowser = false
                        controller.start(callTypes: [.taxi], settings: settings)
                    }
                    .preferredColorScheme(preferredScheme)
                } else {
                    DrillBrowserView(title: scenario.displayName,
                                     drills: DrillLibrary.drills(for: scenario)) { index in
                        showDrillBrowser = false
                        controller.start(scenario: scenario, settings: settings, startingAt: index)
                    }
                    .preferredColorScheme(preferredScheme)
                }
            case .trip:
                DrillBrowserView(title: "Trip — \(tripStops.map(\.icao).joined(separator: " → "))",
                                 drills: TripBuilder.drills(for: tripPlan,
                                                            aircraft: DrillLibrary.defaultAircraft)) { index in
                    showDrillBrowser = false
                    controller.start(trip: tripPlan, settings: settings, startingAt: index)
                }
                .preferredColorScheme(preferredScheme)
            case .mix:
                EmptyView()   // mix is shuffled; "start from" has no meaning there
            }
        }
        .alert("Heads up", isPresented: .constant(controller.errorMessage != nil)) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .onChange(of: controller.lastResult) { _, _ in flashGlow() }
        .onChange(of: controller.isRunning) { _, running in
            if !running { resumeSnapshot = ResumeStore.load() }
        }
        .onAppear { resumeSnapshot = ResumeStore.load() }
    }

    /// nil = follow the system.
    private var preferredScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3.bold())
                .foregroundStyle(Theme.accent)
            Text("VFR RADIO")
                .font(.title3.weight(.heavy))
                .tracking(2)
                .foregroundStyle(.primary)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 6)
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    if let snap = resumeSnapshot { resumeCard(snap) }

                    sessionCard
                    preferencesCard

                    Text("\(sessionCallCount) \(sessionMode == .single ? "drills" : "calls") · say “next”, “repeat”, “example”, “pause”, or “stop” anytime")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            startButton
        }
        // Swipe horizontally anywhere on the setup screen to switch modes.
        .simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    let modes = SessionMode.allCases
                    guard let i = modes.firstIndex(of: sessionMode) else { return }
                    let next = value.translation.width < 0
                        ? min(i + 1, modes.count - 1)
                        : max(i - 1, 0)
                    guard next != i else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.2)) { sessionMode = modes[next] }
                }
        )
    }

    // MARK: - Home cards

    /// Everything about what you'll fly: mode, scenario/route/mix, browse.
    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Mode", selection: $sessionMode) {
                ForEach(SessionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            switch sessionMode {
            case .single:
                scenarioTiles
                browseDrillsButton
            case .trip:
                tripBuilder
            case .mix:
                callTypePicker
            }
        }
        .card()
    }

    /// Three tiles, one per environment — icon, name, and what talks back.
    /// A grid (not an HStack) so the columns are exactly equal width no matter
    /// how long each label is.
    private var scenarioTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                  spacing: 8) {
            scenarioTile(.untowered, icon: "wave.3.right", name: "Untowered", detail: "CTAF")
            scenarioTile(.towered, icon: "building.2.fill", name: "Towered", detail: "ATC")
            scenarioTile(.flightFollowing, icon: "dot.radiowaves.up.forward", name: "Following", detail: "NorCal")
            taxiTile
        }
    }

    /// Fourth tile: a session of just the Ground/Taxi drills — complex routes,
    /// crossings, hold-shorts.
    private var taxiTile: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { taxiFocus = true }
        } label: {
            tileLabel(icon: "arrow.triangle.turn.up.right.diamond.fill",
                      name: "Taxi", detail: "Ground", selected: taxiFocus)
        }
        .buttonStyle(.plain)
    }

    private func scenarioTile(_ s: ScenarioType, icon: String, name: String, detail: String) -> some View {
        let selected = !taxiFocus && scenario == s
        return Button {
            withAnimation(.snappy(duration: 0.15)) { scenario = s; taxiFocus = false }
        } label: {
            tileLabel(icon: icon, name: name, detail: detail, selected: selected)
        }
        .buttonStyle(.plain)
    }

    private func tileLabel(icon: String, name: String, detail: String, selected: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(height: 22)   // icons have different intrinsic sizes; pin the slot
            Text(name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(selected ? Theme.accent.opacity(0.8) : Color.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 78)   // every tile the exact same box
        .padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.15) : Theme.chipFill,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .foregroundStyle(selected ? Theme.accent : .secondary)
    }

    /// Settings-style rows for the set-and-forget choices.
    private var preferencesCard: some View {
        VStack(spacing: 0) {
            prefPickerRow("Input", icon: "mic.fill",
                          selection: settingBinding(\.interactionMode),
                          options: InteractionMode.allCases) { $0.displayName }
            Divider().padding(.leading, 30)
            prefPickerRow("Feedback", icon: "text.bubble.fill",
                          selection: settingBinding(\.gradingMode),
                          options: GradingMode.allCases) { $0.displayName }
            if sessionMode == .single {
                Divider().padding(.leading, 30)
                HStack {
                    Label("Shuffle order", systemImage: "shuffle")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: settingBinding(\.randomizeDrills))
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                .padding(.vertical, 8)
            }
        }
        .card(padding: 14)
    }

    private func prefPickerRow<T: Hashable>(_ title: String, icon: String,
                                            selection: Binding<T>, options: [T],
                                            label: @escaping (T) -> String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
            Spacer()
            Menu {
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label(selection.wrappedValue))
                        .font(.subheadline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    /// Card offering to pick an interrupted session back up.
    private func resumeCard(_ snap: SessionSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.forward.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.label)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("\(snap.progressText) · \(snap.savedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Resume") {
                controller.resume(from: snap, settings: settings)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Button {
                withAnimation { ResumeStore.clear(); resumeSnapshot = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard saved session")
        }
        .card(padding: 14)
    }

    /// Peek at every drill in the selected scenario; tap one to start there.
    private var browseDrillsButton: some View {
        browseButton("Browse all \(DrillLibrary.drills(for: scenario).count) drills")
    }

    /// Peek at the trip's full call sequence; tap a call to join the flight
    /// there (e.g. skip past the taxi calls).
    private var browseTripButton: some View {
        browseButton("Browse all \(sessionCallCount) calls · start anywhere")
    }

    private func browseButton(_ title: String) -> some View {
        Button {
            showDrillBrowser = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var startButton: some View {
        VStack(spacing: 8) {
            if !settings.isConfigured {
                Label("Add your Anthropic API key in Settings to begin.", systemImage: "key.fill")
                    .font(.footnote).foregroundStyle(Theme.amber)
            }
            Button {
                switch sessionMode {
                case .single:
                    if taxiFocus { controller.start(callTypes: [.taxi], settings: settings) }
                    else { controller.start(scenario: scenario, settings: settings) }
                case .trip:   controller.start(trip: tripPlan, settings: settings)
                case .mix:    controller.start(callTypes: selectedCallTypes, settings: settings)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                    Text(sessionMode == .trip ? "Start Trip" : "Start Session")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.5)
        }
        .padding(.top, 6)
    }

    private var canStart: Bool {
        guard settings.isConfigured else { return false }
        switch sessionMode {
        case .single: return true
        case .trip:   return tripPlan.isValid
        case .mix:    return !selectedCallTypes.isEmpty
        }
    }

    private var sessionCallCount: Int {
        switch sessionMode {
        case .single:
            return taxiFocus
                ? DrillLibrary.drills(matching: [.taxi], aircraft: DrillLibrary.defaultAircraft).count
                : DrillLibrary.drills(for: scenario).count
        case .trip:   return TripBuilder.drills(for: tripPlan, aircraft: DrillLibrary.defaultAircraft).count
        case .mix:    return DrillLibrary.drills(matching: selectedCallTypes, aircraft: DrillLibrary.defaultAircraft).count
        }
    }

    // MARK: - Call-type mix

    private var callTypePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("CALL TYPES")
                    .font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if StatsStore.shared.hasWeakSpots {
                    Button("Weak spots") {
                        withAnimation {
                            selectedCallTypes = Set(StatsStore.shared.weakestCallTypes(limit: 3))
                        }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.amber)
                }
                Button("All") {
                    withAnimation { selectedCallTypes = Set(CallType.allCases) }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Button("None") {
                    withAnimation { selectedCallTypes = [] }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(CallType.allCases) { type in
                    callTypeChip(type)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func callTypeChip(_ type: CallType) -> some View {
        let on = selectedCallTypes.contains(type)
        let fill: Color = on ? Theme.accent.opacity(0.18) : Theme.chipFill
        let stroke: Color = on ? Theme.accent.opacity(0.8) : Theme.stroke
        return Button {
            withAnimation(.snappy(duration: 0.15)) {
                if on { selectedCallTypes.remove(type) } else { selectedCallTypes.insert(type) }
            }
        } label: {
            Text(type.displayName)
                .font(.footnote.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1))
                .foregroundStyle(on ? Theme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Trip builder

    private var tripBuilder: some View {
        VStack(spacing: 18) {
            section("ROUTE") {
                VStack(spacing: 8) {
                    ForEach(Array(tripStops.enumerated()), id: \.offset) { i, _ in
                        tripStopRow(i)
                    }
                    Button {
                        withAnimation {
                            tripStops.append(tripStops.last ?? DrillLibrary.routableAirports[0])
                        }
                    } label: {
                        Label("Add stop", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Theme.accent.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            section("ENROUTE") {
                VStack(spacing: 12) {
                    Toggle(isOn: $tripFF) {
                        Label("Flight following (NorCal)", systemImage: "dot.radiowaves.up.forward")
                            .font(.subheadline).foregroundStyle(.primary)
                    }
                    .tint(Theme.accent)
                    Divider()
                    Toggle(isOn: $tripPattern) {
                        Label("Pattern work / touch-and-goes", systemImage: "arrow.triangle.turn.up.right.circle")
                            .font(.subheadline).foregroundStyle(.primary)
                    }
                    .tint(Theme.accent)
                }
            }

            browseTripButton
        }
    }

    private func tripStopRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.18), in: Circle())
                .foregroundStyle(Theme.accent)
            tripStopMenu(i)
            removeStopButton(i)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.chipFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func removeStopButton(_ i: Int) -> some View {
        if tripStops.count > 2 {
            Button {
                let _ = withAnimation { tripStops.remove(at: i) }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Theme.failure.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    private func tripStopMenu(_ i: Int) -> some View {
        let ap = tripStops[i]
        let tagColor: Color = ap.isTowered ? Theme.accent : Theme.amber
        return Menu {
            ForEach(DrillLibrary.routableAirports) { option in
                Button("\(option.name) — \(option.isTowered ? "Towered" : "Untowered")") {
                    tripStops[i] = option
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(ap.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(ap.isTowered ? "TWR" : "CTAF")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tagColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(tagColor)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Live session

    private var liveSession: some View {
        VStack(spacing: 12) {
            if let ac = controller.aircraft { aircraftBanner(ac) }
            HStack {
                phaseBadge
                Spacer()
                Text(controller.progressText)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }

            transcriptCard

            if controller.phase == .finished {
                // debrief lives inside the transcript card area already; show controls
            } else if settings.interactionMode == .pushToTalk {
                pushToTalkButton
            }

            controlBar
        }
        // Input mode can be flipped in Settings mid-session; the controller
        // has to start/stop its auto-listen loop to match.
        .onChange(of: settings.interactionMode) { _, new in
            controller.setInteraction(new)
        }
    }

    private let bottomAnchor = "TRANSCRIPT_BOTTOM"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private var transcriptCard: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.transcript) { line in
                            bubble(line).id(line.id)
                        }
                        if controller.phase == .finished { debriefBlock }
                        // Anchor we always scroll to, so the view stays pinned
                        // to the bottom as lines, the listening state, and the
                        // debrief appear.
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                }
                .scrollIndicators(.hidden)
                .onChange(of: controller.transcript.count) { scrollToBottom(proxy) }
                .onChange(of: controller.phase) { scrollToBottom(proxy) }
                .onChange(of: controller.debrief.count) { scrollToBottom(proxy) }
            }

            if controller.phase == .listening {
                HStack(spacing: 8) {
                    ListeningDots()
                    Text(controller.speech.partialText.isEmpty ? "Listening…" : controller.speech.partialText)
                        .font(.callout).foregroundStyle(Theme.accent)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(glowColor ?? .clear, lineWidth: 2.5)
        )
        .shadow(color: (glowColor ?? .clear).opacity(0.75), radius: 22)
        .animation(.easeOut(duration: 0.3), value: glowColor)
        .frame(maxHeight: .infinity)
        // Swipe the transcript (push-to-talk): left = skip, right = repeat the
        // briefing. Hands-free keeps the voice commands instead — a swipe there
        // would talk over the listening loop.
        .simultaneousGesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    guard settings.interactionMode == .pushToTalk,
                          controller.phase != .finished,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5
                    else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if value.translation.width < 0 {
                        controller.skipCurrent()
                    } else {
                        controller.repeatBriefing()
                    }
                }
        )
    }

    private var pushToTalkButton: some View {
        let listening = controller.phase == .listening
        return Text(listening ? "Listening… release when done" : "Hold to Talk")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(
                (listening ? Theme.accent : Theme.chipFill),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(listening ? 0 : 0.6), lineWidth: 1.5))
            .foregroundStyle(listening ? Theme.onAccent : Theme.accent)
            .scaleEffect(listening ? 0.98 : 1)
            .shadow(color: Theme.accent.opacity(listening ? 0.5 : 0), radius: 18)
            .animation(.snappy(duration: 0.15), value: listening)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if controller.phase == .readyToTalk { controller.talkDown() } }
                    .onEnded { _ in controller.talkUp() }
            )
            .disabled(!(controller.phase == .readyToTalk || listening))
            .opacity(controller.phase == .readyToTalk || listening ? 1 : 0.45)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            if controller.phase == .finished {
                Button { controller.restart() } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                iconButton("xmark", tint: Theme.failure) { controller.stop() }
            } else {
                if settings.interactionMode == .pushToTalk {
                    iconButton("arrow.counterclockwise", tint: .secondary) { controller.repeatBriefing() }
                    iconButton("forward.fill", tint: .secondary) { controller.skipCurrent() }
                }
                if controller.phase == .thinking {
                    // Abort the in-flight grading and take the call again.
                    iconButton("arrow.uturn.backward", tint: Theme.accent) { controller.redoCall() }
                }
                if controller.phase == .paused {
                    iconButton("play.fill", tint: Theme.success) { controller.resumeSession() }
                } else {
                    iconButton("pause.fill", tint: Theme.amber) { controller.pauseSession() }
                }
                Button(role: .destructive) { controller.stop() } label: {
                    Label("Exit", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Theme.failure.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Theme.failure)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Small pieces

    /// Slim banner naming the airplane for this session. Tap it to hear the
    /// spoken callsign.
    private func aircraftBanner(_ ac: Aircraft) -> some View {
        Button {
            Task { await controller.speaker.speak(ac.phoneticCallsign, as: .instructor) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "airplane")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Theme.accent)
                Text("\(ac.callsign) · \(ac.type)")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text("“\(ac.phoneticCallsign)”")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Image(systemName: "speaker.wave.2")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Aircraft \(ac.callsign), \(ac.type). Tap to hear the spoken callsign.")
    }

    /// Distinct drills that got flagged (one drill can log several notes).
    private var flaggedCount: Int {
        Set(controller.debrief.map(\.drillTitle)).count
    }

    private var debriefExport: String {
        var s = "VFR Radio Practice — Debrief · \(Date().formatted(date: .abbreviated, time: .shortened))\n"
        s += "\(max(0, controller.totalDrills - flaggedCount)) of \(controller.totalDrills) calls clean\n"
        for entry in controller.debrief {
            s += "\n• \(entry.drillTitle)\n"
            s += "  You said: \(entry.pilotSaid)\n"
            for c in entry.corrections { s += "  – \(c)\n" }
            s += "  Model call: \(entry.expectedExample)\n"
        }
        return s
    }

    private var debriefBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("DEBRIEF").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                ShareLink(item: debriefExport) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
            }

            // Scorecard: how the session went at a glance.
            HStack(spacing: 10) {
                scorePill(count: max(0, controller.totalDrills - flaggedCount),
                          label: "clean", color: Theme.success, icon: "checkmark.circle.fill")
                scorePill(count: flaggedCount,
                          label: "to review", color: flaggedCount == 0 ? Theme.success : Theme.amber,
                          icon: "flag.fill")
            }

            if controller.debrief.isEmpty {
                Label("All calls were on the money. Nicely flown.", systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(Theme.success)
            } else {
                ForEach(Array(controller.debrief.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.drillTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        ForEach(entry.corrections, id: \.self) { c in
                            Text("• \(c)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Model: \(entry.expectedExample)")
                            .font(.caption2).foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1))
                }
            }
        }
        .padding(.top, 4)
    }

    private func scorePill(count: Int, label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text("\(count)").font(.headline.weight(.bold))
            Text(label).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(color)
    }

    private func bubble(_ line: HandsFreeController.Line) -> some View {
        let (label, color): (String, Color) = switch line.role {
        case .instructor: ("Instructor", Theme.purple)
        case .pilot: ("You", Theme.accent)
        case .radio: ("Radio", Theme.success)
        case .system: ("Note", Theme.amber)
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(color)
            Text(line.text).font(.callout).foregroundStyle(.primary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private var phaseBadge: some View {
        let (text, color, icon): (String, Color, String) = switch controller.phase {
        case .briefing: ("Briefing", Theme.purple, "text.bubble.fill")
        case .listening: ("Listening", Theme.accent, "mic.fill")
        case .thinking: ("Thinking", Theme.amber, "brain.head.profile")
        case .replying: ("Radio", Theme.success, "antenna.radiowaves.left.and.right")
        case .readyToTalk: ("Your call", Theme.accent, "hand.tap.fill")
        case .paused: ("Paused", Theme.amber, "pause.fill")
        case .finished: ("Complete", Theme.success, "checkmark.seal.fill")
        case .idle: ("Idle", .gray, "pause.fill")
        }
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.weight(.bold))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        .foregroundStyle(color)
    }

    private func iconButton(_ system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.headline)
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingBinding<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func flashGlow() {
        guard let result = controller.lastResult else { return }
        UINotificationFeedbackGenerator().notificationOccurred(result.success ? .success : .error)
        glowColor = result.success ? Theme.success : Theme.failure
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await MainActor.run { glowColor = nil }
        }
    }
}

/// Every drill in a scenario or trip, in order — tap one to start the session
/// from that point.
private struct DrillBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let drills: [Drill]
    let onSelect: (Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(drills.enumerated()), id: \.element.id) { i, drill in
                        Button {
                            onSelect(i)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 24, height: 24)
                                    .background(Theme.accent.opacity(0.15), in: Circle())
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(drill.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(drill.setup)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text("Tap a drill to start the session from there (in listed order).")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Animated three-dot listening indicator.
private struct ListeningDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(0.4 + 0.6 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}
