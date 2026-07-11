import SwiftUI

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
    @State private var debugZoom = 1.0
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
                    } else {
                        // The extra padding trims the aspect-fit lamp's
                        // height while keeping its shape, so it ends near
                        // the screen's vertical middle.
                        LampPreviewView()
                            .padding(
                                .horizontal,
                                72 + LampShape.aspectRatio * 32 / 2
                            )
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
                // the timeline and the palette.
                .padding(.bottom, 108)
            }

            bottomBar
                .offset(y: editingSleepSchedule ? 100 : 0)
                .opacity(editingSleepSchedule ? 0 : 1)
        }
        .ignoresSafeArea(edges: .bottom)
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
                Slider(value: $debugZoom, in: 0.5 ... 3)
                Text(String(format: "%.2f×", debugZoom))
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
                zoom: editingSleepSchedule
                    ? Self.splitZoom
                    : (timelineDebugMode ? debugZoom : 1),
                minuteStep: editingSleepSchedule ? 5 : 1,
                scrollCommand: bedtimeScroll,
                onFocusedEventChange: { event in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        focusedTimelineEvent = event
                    }
                },
                onCenteredMinuteChange: { minute in
                    if editingSleepSchedule {
                        draftBedtimeMinute = Double(minute)
                    }
                }
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
                    minuteStep: 5,
                    scrollCommand: wakeScroll,
                    onCenteredMinuteChange: { draftWakeMinute = Double($0) }
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

    /// Large read-only bedtime/wake times shown in place of the sliders
    /// while the sleep-schedule mode is up, with the night's total length
    /// between them, on the labels' line.
    private var sleepScheduleTimes: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            sleepTimeSection(
                label: "Bedtime",
                minuteOfDay: draftBedtimeMinute ?? scheduleStore.bedtime.minuteOfDay,
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
                minuteOfDay: draftWakeMinute ?? scheduleStore.wake.minuteOfDay,
                alignment: .trailing
            )
        }
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
        minuteOfDay: Double,
        alignment: HorizontalAlignment
    ) -> some View {
        let minute = Int(minuteOfDay.rounded()) % 1440
        let hour = minute / 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12

        return VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(hour12):\(String(format: "%02d", minute % 60))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(hour < 12 ? "AM" : "PM")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            // Lay out at ideal width: the flexible half-width frame below
            // otherwise pins the text to its width at creation, wrapping
            // wider times like 11:11 onto a second line.
            .lineLimit(1)
            .fixedSize()
        }
        .animation(.snappy(duration: 0.18), value: minute)
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading ? .leading : .trailing
        )
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

    private var bottomBar: some View {
        // Placeholder capsule; interactions coming next.
        Color.clear
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24 + 56 + 12)
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
