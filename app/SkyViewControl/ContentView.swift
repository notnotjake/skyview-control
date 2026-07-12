import SwiftUI

/// Which of the sleep-schedule times owns the keypad.
enum SleepTimeField: Hashable {
    case bedtime, wake
}

struct ContentView: View {
    @State private var brightness = 0.65
    @State private var colorTemperature = 0.4
    @State private var showingColorTemp = false
    /// Per-channel control mode, entered from the color-temp row's more
    /// button; the timeline hides and four channel sliders take over.
    @State private var showingChannels = false
    @State private var channelRed = 0.0
    @State private var channelWarm = 0.0
    @State private var channelWhite = 0.0
    @State private var channelBlue = 0.0
    @Namespace private var sliderSwap
    @State private var showingDevicePicker = false
    @State private var showingSettings = false
    @State private var showingScheduleEditor = false
    @State private var editingSleepSchedule = false
    /// Chips and loupe fade out ahead of the split animation (and return
    /// after the merge), so they aren't caught mid-transition.
    @State private var timelineDecorationsHidden = false
    /// Toggled in Settings → Developer; swaps the lamp preview for the
    /// timeline debug controls.
    @AppStorage("timelineDebugMode") private var timelineDebugMode = false
    @State private var debugMarksVisible = true
    /// Mock preset dots in the bottom palette.
    @State private var presetCount = 0
    @State private var selectedPreset: Int?
    /// Pinch-persisted timeline zoom; the debug panel's slider edits the
    /// same value.
    @State private var userZoom = 1.0
    @State private var timelineWidth: CGFloat = 0
    @State private var bedtimeScroll = TimelineScrollCommand()
    @State private var wakeScroll = TimelineScrollCommand()
    /// Times being picked in the split halves; nil outside the mode.
    @State private var draftBedtimeMinute: Double?
    @State private var draftWakeMinute: Double?
    @State private var scheduleStore = LampScheduleStore()
    @State private var sunProvider = SunScheduleProvider()
    @State private var locationProvider = LocationProvider()
    @State private var focusedTimelineEvent: FocusedTimelineEvent?
    /// Keypad editing of the big sleep times. Focus routes the system
    /// number pad into `timeEntry` via a hidden proxy text field; the
    /// mirrored bool drives the layout changes (lamp hides, content rises)
    /// with an animation FocusState itself can't carry.
    @FocusState private var focusedTimeField: SleepTimeField?
    @State private var timeEntry = TimeKeypadEntry()
    @State private var keypadBuffer = ContentView.keypadSentinel
    @State private var timeKeyboardUp = false

    /// The proxy field always holds this one character, so a delete (the
    /// buffer emptying) is distinguishable from typed digits appended
    /// after it.
    private static let keypadSentinel = "•"

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 28) {
                topBar

                VStack(spacing: 8) {
                    if timelineDebugMode {
                        timelineDebugPanel
                            .padding(.horizontal, 24)
                    } else if !timeKeyboardUp {
                        // The extra padding trims the aspect-fit lamp's
                        // height while keeping its shape, so it ends near
                        // the screen's vertical middle. The keypad hides
                        // the lamp outright: everything below rises to
                        // stay clear of the keyboard.
                        LampPreviewView()
                            .padding(
                                .horizontal,
                                72 + LampShape.aspectRatio * 32 / 2
                            )
                            .transition(.opacity)
                    }

                    if !showingChannels {
                        HStack {
                            if editingSleepSchedule {
                                // The confirm/cancel pair keeps the original
                                // larger glyphs.
                                glassIconButton("xmark", iconSize: 48 * 0.48) {
                                    exitSleepScheduleMode()
                                }
                                Spacer()
                                glassIconButton(
                                    "checkmark",
                                    tint: .blue,
                                    iconSize: 48 * 0.48
                                ) {
                                    exitSleepScheduleMode()
                                }
                            } else {
                                glassIconButton("bed.double.fill") {
                                    enterSleepScheduleMode()
                                }
                                Spacer()
                                glassIconButton("deskclock") {
                                    showingScheduleEditor = true
                                }
                            }
                        }
                        .overlay(alignment: .bottom) { timelineCallout }
                        .padding(.horizontal, 20)

                        timelineArea
                    }
                }
                // Wins the vertical-space contest: the aspect-fit lamp is
                // compressible, and without priority the flexible slider
                // region below would squash it to a fraction of its size.
                .layoutPriority(1)

                // Sliders float centered between the timeline and the
                // palette; the sleep-mode times stay pinned up top.
                Group {
                    if editingSleepSchedule {
                        sleepScheduleTimes
                            .padding(.top, 4)
                    } else {
                        sliderRow
                    }
                }
                .padding(.horizontal, 24)
                .frame(
                    maxHeight: .infinity,
                    alignment: editingSleepSchedule ? .top : .center
                )
                // Palette region (56 + 24) plus a margin matching the
                // stack spacing above, so the centering is true between
                // the timeline and the palette. With the keyboard up the
                // palette is gone and every point matters.
                .padding(.bottom, timeKeyboardUp ? 16 : 108)
            }

            bottomBar
                .offset(y: editingSleepSchedule ? 100 : 0)
                .opacity(editingSleepSchedule ? 0 : 1)
        }
        // Container-only: the keyboard must still inset the layout so the
        // sleep times ride up above it.
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: focusedTimeField) { _, newValue in
            // A fresh focus (or a field switch) starts over at whole-time
            // selection, per the pickers' prior art.
            timeEntry = TimeKeypadEntry()
            keypadBuffer = Self.keypadSentinel
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                timeKeyboardUp = newValue != nil
            }
        }
        .task {
            locationProvider.start()
            await sunProvider.refresh(at: locationProvider.location)
        }
        .onChange(of: locationProvider.location) { _, newLocation in
            Task { await sunProvider.refresh(at: newLocation) }
        }
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerView()
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingScheduleEditor) {
            ScheduleEditorView(store: scheduleStore)
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                locationProvider: locationProvider,
                sunProvider: sunProvider
            )
                .preferredColorScheme(.dark)
        }
    }

    /// The label popping up out of the timeline, centered between the two
    /// buttons above it: the sleep-schedule mode title while that mode is
    /// up, otherwise the name and precise time of the event the loupe is
    /// over. The timeline is a later sibling, so the offset transition
    /// sinks the label down behind it.
    @ViewBuilder
    private var timelineCallout: some View {
        if editingSleepSchedule {
            Text("Sleep Schedule")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize()
                .transition(.offset(y: 26).combined(with: .opacity))
                .allowsHitTesting(false)
        } else if let event = focusedTimelineEvent {
            let minuteOfDay = Int(event.minuteOfDay.rounded()) % 1440
            let hour = minuteOfDay / 60
            let hour12 = hour % 12 == 0 ? 12 : hour % 12

            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(event.name)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(hour12):\(String(format: "%02d", minuteOfDay % 60))")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(hour < 12 ? "AM" : "PM")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.secondary)
            }
            // Ideal-size layout: the transition's animated frame otherwise
            // truncates the text mid-flight.
            .fixedSize()
            .id(event.name)
            .transition(.offset(y: 26).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    /// Controls for exercising the timeline in isolation: mark visibility,
    /// live zoom, and programmatic snap-to-now.
    private var timelineDebugPanel: some View {
        VStack(spacing: 12) {
            Toggle("Timeline marks", isOn: $debugMarksVisible)

            HStack(spacing: 10) {
                Text("Zoom")
                Slider(value: $userZoom, in: 0.5 ... 3)
                Text(String(format: "%.2f×", userZoom))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            Button {
                bedtimeScroll = TimelineScrollCommand(
                    generation: bedtimeScroll.generation + 1
                )
            } label: {
                Label("Snap to Now", systemImage: "location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .padding(14)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }

    private static let splitDividerWidth: CGFloat = 6
    /// Hour width multiplier for the split halves: 1.4 for the wider look,
    /// times another 1.5 to slow dragging — in a scroll view, pixels per
    /// minute is both the visual scale and the finger-travel ratio.
    private static let splitZoom: CGFloat = 2.1

    private var splitTimelineWidth: CGFloat {
        max((timelineWidth - Self.splitDividerWidth) / 2, 0)
    }

    /// One timeline normally; in sleep-schedule mode it splits in two —
    /// bedtime on the left, wake on the right — scrolling independently.
    ///
    /// The primary instance is never removed, so its scroll state carries
    /// across the mode switch; it animates between full and half width
    /// while being scroll-commanded to bedtime (entering) or now
    /// (exiting). The second instance exists only in the mode: it spawns
    /// already centered on wake, rides the layout animation in from the
    /// right, and on exit is commanded back to now while it slides away
    /// and fades. The fixed-width container clips the mid-transition
    /// overflow.
    private var timelineArea: some View {
        HStack(spacing: 0) {
            DayNightTimelineView(
                schedule: sunProvider.schedule,
                events: timelineDecorationsHidden
                    || (timelineDebugMode && !debugMarksVisible)
                    ? []
                    : scheduleStore.all.map(TimelineEventItem.init),
                showsLoupe: editingSleepSchedule || !timelineDecorationsHidden,
                showsFocusedTime: !editingSleepSchedule && !timelineDecorationsHidden,
                loupeTint: editingSleepSchedule ? .purple : nil,
                snapsToNow: !editingSleepSchedule,
                fadedEdges: editingSleepSchedule ? .leading : .all,
                zoom: editingSleepSchedule ? Self.splitZoom : userZoom,
                // Keypad entry types exact minutes; the 5s grid would
                // round them back off when the scroll reports in.
                minuteStep: editingSleepSchedule
                    ? (focusedTimeField == .bedtime ? 1 : 5)
                    : 1,
                scrollCommand: bedtimeScroll,
                onFocusedEventChange: { event in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        focusedTimelineEvent = event
                    }
                },
                onCenteredMinuteChange: { minute in
                    // While the keypad owns this field the typed value is
                    // the source of truth; the command scroll's in-between
                    // frames must not churn the label.
                    if editingSleepSchedule, focusedTimeField != .bedtime {
                        draftBedtimeMinute = Double(minute)
                    }
                },
                onPinchZoom: editingSleepSchedule
                    ? nil
                    : { newZoom in userZoom = newZoom }
            )
            .frame(width: editingSleepSchedule ? splitTimelineWidth : nil)

            if editingSleepSchedule {
                Color.black
                    .frame(width: Self.splitDividerWidth)
                DayNightTimelineView(
                    schedule: sunProvider.schedule,
                    events: [],
                    showsLoupe: true,
                    showsFocusedTime: false,
                    loupeTint: .orange,
                    snapsToNow: false,
                    fadedEdges: .trailing,
                    zoom: Self.splitZoom,
                    minuteStep: focusedTimeField == .wake ? 1 : 5,
                    scrollCommand: wakeScroll,
                    onCenteredMinuteChange: { minute in
                        if focusedTimeField != .wake {
                            draftWakeMinute = Double(minute)
                        }
                    }
                )
                .frame(width: splitTimelineWidth)
                .transition(.opacity)
            }
        }
        // The divider is a bare Color with no height of its own; without
        // this it stretches the row to fill all free vertical space.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        // Grabbing a timeline half hands control back to scrolling: the
        // keyboard drops and the halves resume feeding the drafts.
        .scrollDismissesKeyboard(.immediately)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            timelineWidth = $0
        }
    }

    private func enterSleepScheduleMode() {
        // Clear the chips and loupe quickly first, then split once they're
        // gone — mid-transition label fades read as clutter.
        withAnimation(.easeOut(duration: 0.15)) {
            timelineDecorationsHidden = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            bedtimeScroll = TimelineScrollCommand(
                generation: bedtimeScroll.generation + 1,
                minuteOfDay: scheduleStore.bedtime.minuteOfDay,
                tracksResize: true
            )
            // The wake half doesn't exist yet: this is its birth command,
            // picked up at its first layout rather than via onChange.
            wakeScroll = TimelineScrollCommand(
                generation: wakeScroll.generation + 1,
                minuteOfDay: scheduleStore.wake.minuteOfDay,
                tracksResize: true
            )
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                editingSleepSchedule = true
            }
        }
    }

    /// For now both the X and the checkmark just leave the mode; discard
    /// vs. save comes when the times are editable.
    private func exitSleepScheduleMode() {
        focusedTimeField = nil
        bedtimeScroll = TimelineScrollCommand(
            generation: bedtimeScroll.generation + 1,
            tracksResize: true
        )
        // The wake half scrolls home too, converging with the primary
        // while it slides off and fades.
        wakeScroll = TimelineScrollCommand(
            generation: wakeScroll.generation + 1,
            tracksResize: true
        )
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            editingSleepSchedule = false
        }
        draftBedtimeMinute = nil
        draftWakeMinute = nil
        // Bring the chips and loupe back once the merge has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard !editingSleepSchedule else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                timelineDecorationsHidden = false
            }
        }
    }

    /// Large bedtime/wake times shown in place of the sliders while the
    /// sleep-schedule mode is up, with the night's total length between
    /// them, on the labels' line. Tapping a time opens the number pad on
    /// it (see `tapTimeSegment`); the hidden proxy fields in the
    /// background are what actually hold keyboard focus.
    private var sleepScheduleTimes: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            sleepTimeSection(
                label: "Bedtime",
                field: .bedtime,
                minuteOfDay: draftBedtimeMinute ?? scheduleStore.bedtime.minuteOfDay,
                tint: .purple,
                alignment: .leading
            )
            Text(sleepDurationText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: sleepDurationText)
            sleepTimeSection(
                label: "Wake Up",
                field: .wake,
                minuteOfDay: draftWakeMinute ?? scheduleStore.wake.minuteOfDay,
                tint: .orange,
                alignment: .trailing
            )
        }
        .background { keypadProxyFields }
        .onChange(of: keypadBuffer) { _, newValue in
            handleKeypadBuffer(newValue)
        }
    }

    /// One invisible number-pad text field per sleep time. Keyboard input
    /// has to land in a real text field; these stay a point big and
    /// near-transparent (a zero-size or fully hidden field can't take
    /// focus) while the visible time renders the state.
    private var keypadProxyFields: some View {
        ZStack {
            keypadProxyField(for: .bedtime)
            keypadProxyField(for: .wake)
        }
        .accessibilityHidden(true)
    }

    private func keypadProxyField(for field: SleepTimeField) -> some View {
        TextField("", text: $keypadBuffer)
            .keyboardType(.numberPad)
            .focused($focusedTimeField, equals: field)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedTimeField = nil }
                        .fontWeight(.semibold)
                }
            }
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .allowsHitTesting(false)
    }

    /// Routes the proxy field's changes into the entry state: an emptied
    /// buffer was a delete, anything after the sentinel was typed digits.
    /// The buffer then resets so every keystroke diffs against the same
    /// baseline.
    private func handleKeypadBuffer(_ newValue: String) {
        guard newValue != Self.keypadSentinel else { return }
        defer { keypadBuffer = Self.keypadSentinel }
        guard let field = focusedTimeField else { return }
        if newValue.isEmpty {
            timeEntry.backspace()
            return
        }
        let typed = newValue.hasPrefix(Self.keypadSentinel)
            ? newValue.dropFirst()
            : newValue[...]
        for character in typed {
            guard let digit = character.wholeNumberValue else { continue }
            let updated = timeEntry.apply(digit: digit, to: sleepTimeValue(field))
            if updated != sleepTimeValue(field) {
                setDraftTime(updated, for: field)
            }
        }
    }

    private func sleepTimeValue(_ field: SleepTimeField) -> Int {
        let minuteOfDay = field == .bedtime
            ? draftBedtimeMinute ?? scheduleStore.bedtime.minuteOfDay
            : draftWakeMinute ?? scheduleStore.wake.minuteOfDay
        return Int(minuteOfDay.rounded()) % 1440
    }

    /// Commits a keypad-typed (or meridiem-toggled) time: the draft shows
    /// it immediately and the matching timeline half glides over to it.
    private func setDraftTime(_ minute: Int, for field: SleepTimeField) {
        switch field {
        case .bedtime:
            draftBedtimeMinute = Double(minute)
            bedtimeScroll = TimelineScrollCommand(
                generation: bedtimeScroll.generation + 1,
                minuteOfDay: Double(minute)
            )
        case .wake:
            draftWakeMinute = Double(minute)
            wakeScroll = TimelineScrollCommand(
                generation: wakeScroll.generation + 1,
                minuteOfDay: Double(minute)
            )
        }
    }

    private enum TimeSegment {
        case hour, minutes
    }

    /// First tap anywhere on a time focuses it with the whole time
    /// selected; further taps narrow onto the hour or minutes, and a tap
    /// on the surrounding whitespace/colon re-selects the whole time.
    private func tapTimeSegment(_ segment: TimeSegment?, in field: SleepTimeField) {
        guard focusedTimeField == field else {
            focusedTimeField = field
            return
        }
        switch segment {
        case .hour: timeEntry.selectHour()
        case .minutes: timeEntry.selectMinutes()
        case nil: timeEntry.selectAll()
        }
    }

    /// While a time is focused its AM/PM is a toggle; unfocused it opens
    /// the keypad like the rest of the time.
    private func tapMeridiem(in field: SleepTimeField) {
        guard focusedTimeField == field else {
            focusedTimeField = field
            return
        }
        setDraftTime((sleepTimeValue(field) + 720) % 1440, for: field)
    }

    /// Bedtime-to-wake span, wrapping midnight: "8 hrs 45 mins", "1 hr",
    /// or just "13 mins" under an hour. The inflect interpolation handles
    /// the hr/hrs and min/mins pluralization.
    private var sleepDurationText: String {
        let bedtime = draftBedtimeMinute ?? scheduleStore.bedtime.minuteOfDay
        let wake = draftWakeMinute ?? scheduleStore.wake.minuteOfDay
        let span = wake - bedtime + 1440
        let total = Int(span.rounded()) % 1440
        let hours = total / 60
        let minutes = total % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(String(
                AttributedString(
                    localized: "^[\(hours) hr](inflect: true)"
                ).characters
            ))
        }
        if minutes > 0 || hours == 0 {
            parts.append(String(
                AttributedString(
                    localized: "^[\(minutes) min](inflect: true)"
                ).characters
            ))
        }
        return parts.joined(separator: " ")
    }

    private func sleepTimeSection(
        label: String,
        field: SleepTimeField,
        minuteOfDay: Double,
        tint: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        let minute = Int(minuteOfDay.rounded()) % 1440
        let hour = minute / 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let isFocused = focusedTimeField == field
        let allSelected = isFocused && timeEntry.selectsAll

        return VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                // The time splits into tappable hour/minute segments; the
                // shared modifiers on the stack keep them rendering as one
                // run of text.
                HStack(spacing: 0) {
                    Text("\(hour12)")
                        .background {
                            selectionHighlight(
                                tint,
                                on: isFocused && timeEntry.hourSelected
                            )
                        }
                        .contentShape(.rect)
                        .onTapGesture { tapTimeSegment(.hour, in: field) }
                    Text(":")
                    Text(String(format: "%02d", minute % 60))
                        .background {
                            selectionHighlight(
                                tint,
                                on: isFocused && timeEntry.minutesSelected
                            )
                        }
                        .contentShape(.rect)
                        .onTapGesture { tapTimeSegment(.minutes, in: field) }
                }
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .background { selectionHighlight(tint, on: allSelected) }
                .contentShape(.rect)
                .onTapGesture { tapTimeSegment(nil, in: field) }
                Text(hour < 12 ? "AM" : "PM")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                    .onTapGesture { tapMeridiem(in: field) }
            }
            .foregroundStyle(.white)
            // Lay out at ideal width: the flexible half-width frame below
            // otherwise pins the text to its width at creation, wrapping
            // wider times like 11:11 onto a second line.
            .lineLimit(1)
            .fixedSize()
        }
        .animation(.snappy(duration: 0.18), value: minute)
        .animation(.easeOut(duration: 0.12), value: timeEntry)
        .animation(.easeOut(duration: 0.12), value: focusedTimeField)
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading ? .leading : .trailing
        )
    }

    /// The text-selection-style pill behind whichever part of a focused
    /// time the next digit will overwrite. Negative padding grows it past
    /// the glyphs without disturbing the text layout.
    @ViewBuilder
    private func selectionHighlight(_ tint: Color, on: Bool) -> some View {
        if on {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.35))
                .padding(.horizontal, -3)
                .padding(.vertical, -1)
        }
    }

    /// In brightness mode the row is just the slider — power lives in a
    /// well embedded at the track's left end — and the more button. Temp
    /// mode inserts a round brightness button on the left (tap to bring
    /// the brightness slider back) while the more button turns into the
    /// upcoming advanced controls.
    ///
    /// The invisible overlays are matched-geometry anchors: while a slider
    /// is offscreen its id lives on the circle it merged into, so the
    /// capsule visibly shrinks into that circle and grows back out of it.
    /// The left button is created and destroyed with the mode switch, so
    /// the brightness slider reads as collapsing into a freshly minted
    /// button and re-inflating from it on the way back.
    private var sliderRow: some View {
        // Bottom-aligned so the flanking buttons stay with the bottom
        // slider when the channel sliders stack up above it.
        HStack(alignment: .bottom, spacing: 12) {
            if showingColorTemp {
                glassIconButton(
                    showingChannels ? "xmark" : "sun.max.fill",
                    size: PuckSlider.height,
                    iconSize: showingChannels ? 48 * 0.48 : nil
                ) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                        if showingChannels {
                            showingChannels = false
                        } else {
                            showingColorTemp = false
                        }
                    }
                }
                .overlay {
                    Color.clear
                        .matchedGeometryEffect(id: "brightness", in: sliderSwap)
                }
            }

            VStack(spacing: 12) {
                if showingChannels {
                    // Staggered from the bottom up on the way in — the
                    // stack grows out of the existing slider — and back
                    // down top-first on the way out, mirroring it.
                    channelSlider(
                        $channelRed,
                        label: "Red channel",
                        peak: Color(red: 1.0, green: 0.16, blue: 0.10),
                        insertionDelay: 0.12,
                        removalDelay: 0
                    )
                    channelSlider(
                        $channelWarm,
                        label: "Warm channel",
                        peak: Color(red: 1.0, green: 0.55, blue: 0.15),
                        insertionDelay: 0.06,
                        removalDelay: 0.06
                    )
                    channelSlider(
                        $channelWhite,
                        label: "White channel",
                        peak: Color(red: 1.0, green: 0.92, blue: 0.78),
                        insertionDelay: 0,
                        removalDelay: 0.12
                    )
                }

                ZStack {
                    if showingChannels {
                        channelSlider(
                            $channelBlue,
                            label: "Blue channel",
                            peak: Color(red: 0.40, green: 0.58, blue: 1.0)
                        )
                    } else if showingColorTemp {
                        PuckSlider(
                            value: $colorTemperature,
                            label: "Color temperature",
                            stops: .colorTemperature,
                            detentStep: 0.125,
                            detentFeedback: .impact(flexibility: .soft, intensity: 0.5)
                        )
                        .matchedGeometryEffect(id: "temperature", in: sliderSwap)
                        .transition(.untouchable.combined(with: .opacity))
                    } else {
                        PuckSlider(
                            value: $brightness,
                            label: "Brightness",
                            stops: .brightness,
                            hasPowerWell: true,
                            detentStep: 0.2
                        )
                        .matchedGeometryEffect(id: "brightness", in: sliderSwap)
                        .transition(.untouchable.combined(with: .opacity))
                    }
                }
            }

            glassIconButton(
                showingChannels
                    ? "checkmark"
                    : (showingColorTemp
                        ? "slider.horizontal.3"
                        : "circle.lefthalf.striped.horizontal"),
                size: PuckSlider.height,
                tint: showingChannels ? .blue : nil,
                iconSize: showingChannels ? 48 * 0.48 : nil
            ) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                    if showingChannels {
                        showingChannels = false
                    } else if showingColorTemp {
                        showingChannels = true
                    } else {
                        showingColorTemp = true
                    }
                }
            }
            .overlay {
                if !showingColorTemp {
                    Color.clear
                        .matchedGeometryEffect(id: "temperature", in: sliderSwap)
                }
            }
        }
    }

    /// One lamp-channel intensity slider, dim-to-bright in the channel's
    /// color. Both directions fade while translating a few points, each on
    /// its own delay so the stack staggers in and back out.
    private func channelSlider(
        _ value: Binding<Double>,
        label: String,
        peak: Color,
        insertionDelay: Double = 0,
        removalDelay: Double = 0
    ) -> some View {
        PuckSlider(
            value: value,
            label: label,
            stops: .channel(peak: peak),
            detentStep: 0.125,
            detentFeedback: .impact(flexibility: .soft, intensity: 0.5)
        )
        .transition(
            .asymmetric(
                insertion: .untouchable
                    .combined(with: .opacity)
                    .combined(with: .offset(y: 14))
                    .animation(
                        .spring(response: 0.42, dampingFraction: 0.8)
                            .delay(insertionDelay)
                    ),
                removal: .untouchable
                    .combined(with: .opacity)
                    .combined(with: .offset(y: 14))
                    .animation(
                        .spring(response: 0.34, dampingFraction: 0.85)
                            .delay(removalDelay)
                    )
            )
        )
    }

    private var topBar: some View {
        devicePickerButton
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                glassIconButton("switch.2") {
                    showingSettings = true
                }
            }
            .padding(.horizontal, 20)
    }

    private var devicePickerButton: some View {
        Button {
            showingDevicePicker = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.green, Color.green.mix(with: .black, by: 0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 8, height: 8)
                Text("Bedroom")
                    .font(.headline)
                    .foregroundStyle(.white)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    /// Mock preset palette: starts as a "Save Preset" pill; saving fills
    /// it with dots and a trailing plus for adding more. Real preset
    /// storage comes later.
    private var bottomBar: some View {
        Group {
            if presetCount == 0 {
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                        presetCount = 1
                        selectedPreset = 0
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.gray)
                        Text("Save Preset")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 56)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 14) {
                    // Framed like the plus so the dots sit visually
                    // centered between the two glyphs.
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.gray)
                        .frame(width: 32, height: 56)
                        .contentShape(.rect)

                    ForEach(0 ..< presetCount, id: \.self) { index in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedPreset = index
                            }
                        } label: {
                            Circle()
                                .fill(.white.opacity(0.35))
                                .frame(width: 26, height: 26)
                                // Selection ring floats with a gap of clear
                                // space between it and the dot.
                                .overlay {
                                    if selectedPreset == index {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 1.5)
                                            .frame(width: 34, height: 34)
                                            .transition(
                                                .scale(scale: 0.6)
                                                    .combined(with: .opacity)
                                            )
                                    }
                                }
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            presetCount += 1
                            selectedPreset = presetCount - 1
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.gray)
                            .frame(width: 32, height: 56)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
            }
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 25))
        .padding(.bottom, 24)
    }

    private func glassIconButton(
        _ icon: String,
        size: CGFloat = 48,
        tint: Color? = nil,
        iconSize: CGFloat? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(
                    size: iconSize ?? (size * 0.48 - 3),
                    weight: .medium
                ))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                // The frame's transparent area isn't hit-testable on its
                // own — only the glyph would take taps without this.
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            tint.map { Glass.regular.tint($0).interactive() }
                ?? .regular.interactive(),
            in: .circle
        )
    }
}

/// Disables hit testing while a view is inserting or removing. The
/// departing slider morphs directly onto the left circle button, and its
/// drag gesture would otherwise swallow taps there until the removal
/// animation finishes.
private struct HitTestingModifier: ViewModifier {
    var isEnabled: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(isEnabled)
    }
}

extension AnyTransition {
    static var untouchable: AnyTransition {
        .modifier(
            active: HitTestingModifier(isEnabled: false),
            identity: HitTestingModifier(isEnabled: true)
        )
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
