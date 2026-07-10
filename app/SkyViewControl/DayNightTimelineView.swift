import SwiftUI
/// A schedule moment (wake/bedtime chip or sun event) the loupe is over.
struct FocusedTimelineEvent: Equatable {
    var name: String
    var minuteOfDay: Double
}

/// A programmatic scroll request for `DayNightTimelineView`. Bump
/// `generation` to fire; the view animates the requested time to the
/// viewport center. Applied on change, or at first layout when the view is
/// created with one already set.
struct TimelineScrollCommand: Equatable {
    var generation = 0
    /// Minute of day to center, or nil for the current time.
    var minuteOfDay: Double? = nil
    /// Set when the command rides a zoom/width change in the same
    /// transaction. A one-shot scrollTo loses the race against an
    /// in-flight resize (the layout pass clobbers it), so these commands
    /// instead track the live geometry frame by frame until the target
    /// time is centered — a clobbered frame is simply retried on the next.
    var tracksResize = false
}

/// One self-consistent scroll geometry snapshot: offset, content size and
/// viewport measured together, so mid-resize math never mixes scales.
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0
}

/// Horizontally scrolling day/night timeline, shaded by the sun schedule,
/// with hour ticks across the band, labels every other hour, a liquid-glass
/// "now" marker, and scheduled-event chips pinned at their times.
///
/// Infinite scroll works Mario-64-staircase style: the strip is a 20-day
/// buffer, and whenever the scroll offset drifts within two days of either
/// end it is teleported back toward the middle by an exact multiple of one
/// day's width. Every copy of the day is "today", so the jump is invisible
/// and the marker/chips repeat in each copy.
///
/// The strip is deliberately a plain HStack, not a lazy one: all the
/// offset↔time math assumes day k starts at exactly k × dayWidth, and a
/// lazy stack breaks that whenever `zoom` changes at runtime — offscreen
/// cells keep stale sizes and unmaterialized ones are estimated, leaving a
/// mixed-scale grid that desyncs the centered-time readout from the
/// rendered strip. Twenty eager day cells are cheap; a uniform grid is
/// what the math needs.
struct DayNightTimelineView: View {
    var schedule: SunSchedule = .placeholder
    var events: [TimelineEventItem] = []
    /// Hides the center loupe while a mode that doesn't scrub is up.
    var showsLoupe = true
    /// The small time readout under the loupe. The split halves hide it —
    /// they surface their centered time in the big labels below instead.
    var showsFocusedTime = true
    /// Tints the loupe's glass; the split halves color-code themselves.
    var loupeTint: Color? = nil
    /// Snapping to now fights modes where the center picks another time.
    var snapsToNow = true
    /// Which sides get the dimming edge fade. A split half only fades its
    /// device edge, not the one meeting the divider.
    var fadedEdges: HorizontalEdge.Set = [.leading, .trailing]
    /// Multiplies the hour width; the split halves zoom in for finer
    /// scrubbing. Animating this animates the strip's scale, and any
    /// scroll command issued in the same transaction targets the new
    /// scale — landing in a neighboring day copy at worst, which is
    /// invisible since every copy is today.
    var zoom: CGFloat = 1
    /// Granularity of the centered time: reported minutes round to this,
    /// and scrolls settle on its grid. The split halves pick in 5s.
    var minuteStep = 1
    var scrollCommand: TimelineScrollCommand? = nil
    var onFocusedEventChange: (FocusedTimelineEvent?) -> Void = { _ in }
    /// Reports the minute of day at the viewport center as it changes —
    /// how the split halves feed the times they're picking.
    var onCenteredMinuteChange: ((Int) -> Void)? = nil

    /// How close (in minutes) the loupe must be to an event to count as
    /// over it. ~14 min covers the loupe's own width plus a little grace.
    private static let eventGraceMinutes = 14.0

    private static let baseHourWidth: CGFloat = 44
    private static let bandHeight: CGFloat = 72
    private static let labelHeight: CGFloat = 26
    private static let labelOverlap: CGFloat = 6
    private static let headroom: CGFloat = 6
    private static let dayRange = -10 ..< 10

    private var hourWidth: CGFloat { Self.baseHourWidth * zoom }
    private var dayWidth: CGFloat { hourWidth * 24 }

    /// The strip's measured scale — equal to `dayWidth` at rest, truthful
    /// mid-resize when the declared zoom hasn't reached the layout yet.
    private var liveDayWidth: CGFloat {
        metrics.contentWidth > 0
            ? metrics.contentWidth / CGFloat(Self.dayRange.count)
            : dayWidth
    }

    private var liveViewportWidth: CGFloat {
        metrics.containerWidth > 0 ? metrics.containerWidth : viewportWidth
    }

    @State private var position = ScrollPosition()
    @State private var hasCentered = false
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var centeredHour: Int?
    @State private var focusedMinute = 0
    @State private var focusedEvent: FocusedTimelineEvent?
    @State private var hapticDetent = 0
    @State private var snapHaptic = 0
    @State private var snapHapticArmed = false
    @State private var isSnappedToNow = false
    @State private var isSnappingToNow = false
    @State private var userGestureIsActive = false
    @State private var snapAllowedForGesture = false
    @State private var gestureStartOffset: CGFloat = 0
    /// A command's animated scroll is running: hold off the infinite-strip
    /// teleports, whose raw scrollTo would cancel the animation.
    @State private var scrollCommandInFlight = false
    @State private var metrics = ScrollMetrics()
    /// Target minute a resize-riding command is converging on; driven a
    /// step per geometry frame until it lands.
    @State private var trackedMinute: Double?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMinute = context.date.timeIntervalSince(
                Calendar.current.startOfDay(for: context.date)
            ) / 60
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Self.dayRange, id: \.self) { dayIndex in
                        DayCell(
                            events: events,
                            schedule: schedule,
                            hourWidth: hourWidth,
                            bandHeight: Self.bandHeight,
                            labelHeight: Self.labelHeight,
                            labelOverlap: Self.labelOverlap,
                            headroom: Self.headroom
                        )
                        // Chips near midnight overhang into the next day;
                        // keep each day above the day to its right.
                        .zIndex(Double(-dayIndex))
                    }
                }
            }
            .scrollTargetBehavior(
                NowSnapBehavior(
                    minuteOfDay: nowMinute,
                    dayWidth: dayWidth,
                    threshold: 24,
                    isEnabled: snapsToNow && snapAllowedForGesture,
                    stepWidth: minuteStep > 1
                        ? dayWidth * CGFloat(minuteStep) / 1440
                        : nil,
                    onSnap: {
                        // The deceleration target just got retargeted onto
                        // now: collapse the loupe during the travel, not
                        // after it. Only honor calls tied to a drag ending —
                        // updateTarget can also run on layout changes.
                        guard userGestureIsActive || scrollPhase == .decelerating
                        else { return }
                        if !isSnappingToNow { snapHapticArmed = true }
                        isSnappingToNow = true
                        isSnappedToNow = true
                    }
                )
            )
            .scrollPosition($position)
            // Anchor the *initial* offset only. The size-change anchor is
            // deliberately off: it preserves the content's unit midpoint —
            // midnight of day 0 — so zooming while centered anywhere else
            // dragged the view. The zoom and width handlers below keep the
            // centered *time* fixed through resizes instead.
            .defaultScrollAnchor(.center, for: .initialOffset)
            // The initial anchor lands on the middle of the strip, which is
            // midnight; nudge once to center on the current time.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                let previousWidth = viewportWidth
                viewportWidth = width
                guard hasCentered else {
                    hasCentered = true
                    let contentWidth = CGFloat(Self.dayRange.count) * dayWidth
                    let centered = (contentWidth - width) / 2
                    // A command set before first layout picks the starting
                    // time — a view spawned mid-transition (the split's
                    // second half) begins life already on its target.
                    let startMinute = scrollCommand?.minuteOfDay ?? nowMinute
                    isSnappedToNow = scrollCommand?.minuteOfDay == nil
                    print("TL birth: width=\(width) dayW=\(dayWidth) startMinute=\(startMinute) scrollTo=\(centered + (startMinute / 1440) * dayWidth)")
                    position.scrollTo(x: centered + (startMinute / 1440) * dayWidth)
                    // Born mid-transition: the nudge above can be clobbered
                    // by the initial anchor or the resize, so keep tracking
                    // until the target actually holds.
                    if scrollCommand?.tracksResize == true {
                        trackedMinute = startMinute
                    }
                    return
                }
                // Keep the centered time fixed when the viewport resizes.
                // Skip while a command drives the scroll: its target
                // already accounts for the final width, and a raw scrollTo
                // here would cancel the command's animation.
                if width != previousWidth, previousWidth > 0,
                   !scrollCommandInFlight, trackedMinute == nil {
                    position.scrollTo(x: scrollOffset + (previousWidth - width) / 2)
                }
            }
            .onChange(of: zoom) { oldZoom, newZoom in
                guard hasCentered, oldZoom > 0, newZoom > 0,
                      oldZoom != newZoom, !scrollCommandInFlight,
                      trackedMinute == nil else { return }
                // Rescale the offset about the viewport center so the
                // centered time stays put while the strip stretches
                // around it.
                let centerX = scrollOffset + viewportWidth / 2
                position.scrollTo(x: centerX * (newZoom / oldZoom) - viewportWidth / 2)
            }
            .onChange(of: scrollCommand) { _, command in
                guard let command, hasCentered else { return }
                let minute = command.minuteOfDay ?? nowMinute
                print("TL cmd: gen=\(command.generation) minute=\(minute) tracks=\(command.tracksResize) vpW=\(viewportWidth) offset=\(scrollOffset) dayW=\(dayWidth)")
                isSnappingToNow = false
                snapHapticArmed = false
                isSnappedToNow = command.minuteOfDay == nil
                if command.tracksResize {
                    // Converges per geometry frame; see trackingStep.
                    trackedMinute = minute
                    return
                }
                trackedMinute = nil
                // At rest a single animated scroll is reliable. Shortest
                // path: target the copy of the minute nearest the current
                // center — the strip loops, so that can be opposite the
                // direction the user last scrolled.
                let targetX = nowMarkerContentX(minuteOfDay: minute, near: scrollOffset)
                scrollCommandInFlight = true
                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                    position.scrollTo(x: targetX - liveViewportWidth / 2)
                } completion: {
                    scrollCommandInFlight = false
                    print("TL cmd done: gen=\(command.generation) offset=\(scrollOffset) centeredMinute=\(minuteAtViewportCenter(offset: scrollOffset))")
                }
            }
            .onScrollGeometryChange(for: ScrollMetrics.self, of: {
                ScrollMetrics(
                    offset: $0.contentOffset.x,
                    contentWidth: $0.contentSize.width,
                    containerWidth: $0.containerSize.width
                )
            }) { _, m in
                metrics = m
                let x = m.offset
                scrollOffset = x
                if let target = trackedMinute {
                    trackingStep(toward: target, metrics: m)
                }
                let newMinute = minuteAtViewportCenter(offset: x)
                if newMinute != focusedMinute {
                    let previousStepped = steppedMinute(focusedMinute)
                    focusedMinute = newMinute
                    let stepped = steppedMinute(newMinute)
                    if stepped != previousStepped {
                        onCenteredMinuteChange?(stepped)
                    }
                }
                updateFocusedEvent()
                // Fire the snap haptic on approach, not on settle: the snap
                // eases out, so by the time the completion handler (or .idle)
                // runs the motion has visually finished and the tap reads
                // late. A few points out, plus the haptic engine's own
                // latency, lands the tap right as the loupe hits the marker.
                if snapHapticArmed {
                    let target = nowMarkerContentX(minuteOfDay: nowMinute, near: x)
                        - viewportWidth / 2
                    if abs(x - target) <= 8 {
                        snapHapticArmed = false
                        snapHaptic &+= 1
                    }
                }
                // Only a finger-driven move breaks the snap; the offset also
                // changes while decelerating onto now with the loupe already
                // collapsing, and that must not re-expand it.
                if scrollPhase == .tracking || scrollPhase == .interacting,
                   abs(x - gestureStartOffset) > 0.25,
                   isSnappedToNow {
                    isSnappedToNow = false
                }
                let contentWidth = m.contentWidth
                let margin = liveDayWidth * 2
                let recenter = liveDayWidth * 8
                if scrollCommandInFlight || trackedMinute != nil {
                    // No teleports mid-command: transient out-of-scale
                    // offsets would trip them and cancel the animation.
                    centeredHour = hourAtViewportCenter(offset: x)
                } else if x < margin {
                    let targetX = x + recenter
                    scrollOffset = targetX
                    centeredHour = hourAtViewportCenter(offset: targetX)
                    position.scrollTo(x: targetX)
                } else if x > contentWidth - margin {
                    let targetX = x - recenter
                    scrollOffset = targetX
                    centeredHour = hourAtViewportCenter(offset: targetX)
                    position.scrollTo(x: targetX)
                } else {
                    let newCenteredHour = hourAtViewportCenter(offset: x)
                    if let centeredHour,
                       centeredHour != newCenteredHour,
                       (scrollPhase == .interacting || scrollPhase == .decelerating) {
                        hapticDetent &+= 1
                    }
                    centeredHour = newCenteredHour
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                scrollPhase = newPhase
                // A quick drag can skip .tracking and report .interacting
                // first, and catching a decelerating fling starts a new
                // gesture with no .idle in between — so a gesture begins on
                // any transition from a non-touch phase to a touch phase.
                let oldIsTouch = oldPhase == .tracking || oldPhase == .interacting
                let newIsTouch = newPhase == .tracking || newPhase == .interacting
                if newIsTouch, !oldIsTouch {
                    userGestureIsActive = true
                    gestureStartOffset = context.geometry.contentOffset.x
                    // If this drag starts from the snapped position, let it
                    // escape without re-snapping; the next drag snaps again.
                    snapAllowedForGesture = !isSnappedToNow
                    isSnappingToNow = false
                    snapHapticArmed = false
                    // Grabbing the strip cancels any in-flight command.
                    scrollCommandInFlight = false
                    trackedMinute = nil
                }
                if newPhase == .interacting, isSnappedToNow {
                    isSnappedToNow = false
                }
                if newPhase == .idle, userGestureIsActive {
                    userGestureIsActive = false
                    if snapsToNow, snapAllowedForGesture {
                        snapToNowIfClose(
                            minuteOfDay: nowMinute,
                            offset: context.geometry.contentOffset.x
                        )
                    }
                }
            }
            .frame(
                height: Self.headroom + Self.bandHeight
                    + Self.labelHeight - Self.labelOverlap
            )
            .overlay(alignment: .top) {
                centerLoupe
                    .padding(.top, Self.headroom + 8)
                    .opacity(showsLoupe ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showsLoupe)
            }
            .overlay(alignment: .topLeading) {
                nowMarker(minuteOfDay: nowMinute)
                    .offset(
                        x: nowMarkerViewportX(minuteOfDay: nowMinute) - 4,
                        y: Self.headroom + 8
                    )
            }
            .overlay(alignment: .top) {
                focusedTimeLabel
                    .padding(.top, Self.headroom + Self.bandHeight - Self.labelOverlap)
                    .opacity(showsFocusedTime ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showsFocusedTime)
            }
            .overlay(edgeFade)
            .sensoryFeedback(.selection, trigger: hapticDetent)
            .sensoryFeedback(
                .impact(weight: .heavy, intensity: 0.9),
                trigger: snapHaptic
            )
        }
    }

    /// One convergence step for a resize-riding command: recompute where
    /// the target time sits in the *measured* geometry and nudge the
    /// offset a fraction closer. Runs once per geometry frame — the
    /// resize's own frames drive it while the layout is animating, and
    /// each nudge triggers the next frame after that. Ends by pinning
    /// exactly once the declared scale has landed.
    private func trackingStep(toward minute: Double, metrics m: ScrollMetrics) {
        let dayW = m.contentWidth / CGFloat(Self.dayRange.count)
        guard dayW > 0 else { return }
        let base = (minute / 1440) * dayW
        let centerX = m.offset + m.containerWidth / 2
        let copies = ((centerX - base) / dayW).rounded()
        let desired = base + copies * dayW - m.containerWidth / 2
        let delta = desired - m.offset
        let resizeSettled =
            abs(m.contentWidth - CGFloat(Self.dayRange.count) * dayWidth) < 0.5
        // Close out with an exact pin once the strip has its final scale
        // and we're a hair away. The threshold is generous (8pt) because
        // sub-pixel nudges don't move the offset, which would stop the
        // frame stream and strand the tracker just short of its target.
        if resizeSettled, abs(delta) <= 8 {
            trackedMinute = nil
            position.scrollTo(x: desired)
            print("TL track done: offset=\(desired) minute=\(minute)")
            return
        }
        position.scrollTo(x: m.offset + delta * 0.12)
    }

    private func hourAtViewportCenter(offset: CGFloat) -> Int {
        Int(floor((offset + liveViewportWidth / 2) / (liveDayWidth / 24)))
    }

    private func steppedMinute(_ minute: Int) -> Int {
        guard minuteStep > 1 else { return minute }
        let stepped = (Double(minute) / Double(minuteStep)).rounded()
            * Double(minuteStep)
        return Int(stepped) % 1440
    }

    private func minuteAtViewportCenter(offset: CGFloat) -> Int {
        let centerX = offset + liveViewportWidth / 2
        let dayX = centerX.truncatingRemainder(dividingBy: liveDayWidth)
        let normalizedX = dayX < 0 ? dayX + liveDayWidth : dayX
        return Int((normalizedX / liveDayWidth * 1440).rounded()) % 1440
    }

    private func updateFocusedEvent() {
        let candidates = events.map {
            FocusedTimelineEvent(name: $0.label, minuteOfDay: $0.minuteOfDay)
        } + [
            FocusedTimelineEvent(name: "Sunrise", minuteOfDay: schedule.sunrise),
            FocusedTimelineEvent(name: "Sunset", minuteOfDay: schedule.sunset),
        ]
        let minute = Double(focusedMinute)
        let event = candidates
            .min { distance($0.minuteOfDay, minute) < distance($1.minuteOfDay, minute) }
            .flatMap {
                distance($0.minuteOfDay, minute) <= Self.eventGraceMinutes ? $0 : nil
            }
        guard event != focusedEvent else { return }
        focusedEvent = event
        onFocusedEventChange(event)
    }

    /// Minutes between two times of day, wrapping across midnight.
    private func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1440)
        return min(d, 1440 - d)
    }

    private func nowMarkerViewportX(minuteOfDay: Double) -> CGFloat {
        nowMarkerContentX(minuteOfDay: minuteOfDay, near: scrollOffset) - scrollOffset
    }

    private func nowMarkerContentX(minuteOfDay: Double, near offset: CGFloat) -> CGFloat {
        let markerX = (minuteOfDay / 1440) * liveDayWidth
        let centeredContentX = offset + liveViewportWidth / 2
        let nearestDay = ((centeredContentX - markerX) / liveDayWidth).rounded()
        return markerX + nearestDay * liveDayWidth
    }

    private func snapToNowIfClose(minuteOfDay: Double, offset: CGFloat) {
        let markerX = nowMarkerContentX(minuteOfDay: minuteOfDay, near: offset)
        let targetOffset = markerX - viewportWidth / 2
        let distance = abs(targetOffset - offset)
        guard distance <= 24 else { return }

        if distance <= 1 {
            // Only arm if no snap is in flight: a deceleration snap ends
            // here too, and its approach haptic has already fired.
            if !isSnappingToNow { snapHapticArmed = true }
            completeNowSnap()
            return
        }

        isSnappingToNow = true
        // Collapse the loupe alongside the scroll, not after it.
        isSnappedToNow = true
        snapHapticArmed = true
        withAnimation(.snappy(duration: 0.24)) {
            position.scrollTo(x: targetOffset)
        } completion: {
            guard isSnappingToNow else { return }
            completeNowSnap()
        }
    }

    private func completeNowSnap() {
        isSnappingToNow = false
        isSnappedToNow = true
        // Normally the approach check has already fired; this covers the
        // already-at-target case (distance <= 1, no travel to observe).
        if snapHapticArmed {
            snapHapticArmed = false
            snapHaptic &+= 1
        }
    }

    private func nowMarker(minuteOfDay: Double) -> some View {
        Color.clear
            .frame(width: 8, height: Self.bandHeight - 16)
            .glassEffect(
                .clear.tint(Color(red: 0.92, green: 0.12, blue: 0.16)),
                in: .capsule
            )
            .allowsHitTesting(false)
    }

    /// A fixed clear-glass lens marking the time at the viewport center.
    /// Tinted variants run narrower: the colored glass reads heavier than
    /// the clear ring at the same width.
    private var loupeWidth: CGFloat { loupeTint == nil ? 18 : 11 }

    private var centerLoupe: some View {
        Color.clear
            // Animate the real size rather than scaleEffect: a transform
            // squashes the rendered glass (refraction and highlights
            // included), which reads as growing from one side. A true size
            // change lets the glass morph its shape, centered.
            .frame(
                width: isSnappedToNow ? 5 : loupeWidth,
                height: (Self.bandHeight - 16) * (isSnappedToNow ? 0.85 : 1)
            )
            .glassEffect(
                loupeTint.map { Glass.clear.tint($0) } ?? .clear,
                in: .capsule
            )
            // Cut the clear center back out, leaving a true glass ring.
            .mask {
                Capsule()
                    .strokeBorder(lineWidth: 3.5)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.38),
                                .white.opacity(0.10),
                                .white.opacity(0.28),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
            }
            // Fixed footprint: the overlay pins the loupe's top edge, so
            // without this the height change would shrink it upward instead
            // of about its center.
            .frame(width: loupeWidth, height: Self.bandHeight - 16)
            .animation(
                .spring(response: 0.32, dampingFraction: 0.72),
                value: isSnappedToNow
            )
            .allowsHitTesting(false)
    }

    private var focusedTimeLabel: some View {
        let hour = focusedMinute / 60
        let minute = focusedMinute % 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? "AM" : "PM"

        return HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text("\(hour12):\(String(format: "%02d", minute))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(meridiem)
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        // Shield hugs the label: 4pt solid past the text, then an 11pt
        // falloff, instead of a fixed overall width.
        .padding(.horizontal, 15)
        .frame(height: Self.labelHeight)
        .background {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 11)
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 11)
            }
        }
        .animation(.snappy(duration: 0.18), value: focusedMinute)
        .allowsHitTesting(false)
    }

    /// Dimming gradients at the faded edges, over everything. Eased with
    /// smoothstep so the fade has no visible start or end line.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            if fadedEdges.contains(.leading) {
                dimGradient(fadeFrom: .leading)
                    .frame(width: 40)
            }
            Spacer(minLength: 0)
            if fadedEdges.contains(.trailing) {
                dimGradient(fadeFrom: .trailing)
                    .frame(width: 40)
            }
        }
        .allowsHitTesting(false)
    }

    private func dimGradient(fadeFrom edge: HorizontalEdge) -> LinearGradient {
        let stops = (0 ... 8).map { i in
            let t = Double(i) / 8
            let eased = t * t * (3 - 2 * t)
            let alpha = 0.5 * (edge == .leading ? 1 - eased : eased)
            return Gradient.Stop(color: .black.opacity(alpha), location: t)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}

private struct NowSnapBehavior: ScrollTargetBehavior {
    let minuteOfDay: Double
    let dayWidth: CGFloat
    let threshold: CGFloat
    let isEnabled: Bool
    /// When set, scrolls rest on multiples of this content width instead
    /// of snapping to now — the minute grid in split mode.
    let stepWidth: CGFloat?
    let onSnap: () -> Void

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        if let stepWidth, stepWidth > 0 {
            let center = target.rect.origin.x + context.containerSize.width / 2
            let snapped = (center / stepWidth).rounded() * stepWidth
            target.rect.origin.x += snapped - center
            return
        }

        guard isEnabled else { return }

        let proposedCenterX = target.rect.origin.x + context.containerSize.width / 2
        let firstNowX = (minuteOfDay / 1440) * dayWidth
        let nearestDay = ((proposedCenterX - firstNowX) / dayWidth).rounded()
        let nearestNowX = firstNowX + nearestDay * dayWidth

        guard abs(nearestNowX - proposedCenterX) <= threshold else { return }
        target.rect.origin.x = nearestNowX - context.containerSize.width / 2
        // updateTarget runs inside scroll-view layout; defer the state
        // change out of it.
        DispatchQueue.main.async(execute: onSnap)
    }
}

/// One 24-hour copy of the strip: the sky band with ticks, the now marker
/// and event chips overlaid at their times, and hour labels beneath.
private struct DayCell: View {
    let events: [TimelineEventItem]
    let schedule: SunSchedule
    let hourWidth: CGFloat
    let bandHeight: CGFloat
    let labelHeight: CGFloat
    let labelOverlap: CGFloat
    let headroom: CGFloat

    private var dayWidth: CGFloat { hourWidth * 24 }

    var body: some View {
        VStack(spacing: -labelOverlap) {
            band
                .overlay(alignment: .leading) { eventRow }
            labels
        }
        .padding(.top, headroom)
    }

    private var band: some View {
        HStack(spacing: 0) {
            ForEach(0 ..< 24, id: \.self) { hour in
                LinearGradient(
                    stops: gradientStops(forHour: hour),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: hourWidth, height: bandHeight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(red: 0.72, green: 0.80, blue: 1.0).opacity(0.14))
                        .frame(width: 1)
                        .blendMode(.plusLighter)
                        .offset(x: -0.5)
                }
            }
        }
        .overlay(alignment: .leading) {
            sunEventLine(minute: schedule.sunrise, name: "Sunrise", brightEdge: .top)
        }
        .overlay(alignment: .leading) {
            sunEventLine(minute: schedule.sunset, name: "Sunset", brightEdge: .bottom)
        }
        // Feather the band's top and bottom edges (ticks and sun lines
        // included).
        .mask(verticalFeather)
    }

    /// Dotted vertical line marking a sun event's time in the band, a more
    /// visible cousin of the hour ticks. Faded toward the sun's direction:
    /// sunrise is bright at the top and dissolves downward, sunset the
    /// reverse — clear at the dim end, smoothstepped to full ~30% in.
    private func sunEventLine(
        minute: Double,
        name: String,
        brightEdge: VerticalEdge
    ) -> some View {
        // Ease-in ramp compressed into the 15–85% span: the outer 15% at
        // each end sits inside the feather mask's own fade, so the ramp
        // holds its endpoint values there and does its work where it's
        // actually visible. A nonzero floor keeps the full line readable;
        // the ramp carries it from faint to bright.
        let floorOpacity = 0.14
        let peakOpacity = 0.7
        let stops = [Gradient.Stop(color: .white.opacity(floorOpacity), location: 0)]
            + (0 ... 8).map { i in
                let p = Double(i) / 8
                return Gradient.Stop(
                    color: .white.opacity(
                        floorOpacity + (peakOpacity - floorOpacity) * p * p
                    ),
                    location: 0.15 + p * 0.7
                )
            }
            + [Gradient.Stop(color: .white.opacity(peakOpacity), location: 1)]

        return Path { path in
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 1, y: bandHeight - 1))
        }
        .stroke(
            LinearGradient(
                stops: stops,
                startPoint: brightEdge == .top ? .bottom : .top,
                endPoint: brightEdge == .top ? .top : .bottom
            ),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.001, 6])
        )
        .blendMode(.plusLighter)
        .frame(width: 2, height: bandHeight)
        .offset(x: (minute / 1440) * dayWidth - 1)
        .accessibilityLabel("\(name), \(formattedTime(minute))")
    }

    /// A long, eased feather that reaches full opacity without the visible
    /// edge produced by a short clear-to-opaque linear ramp.
    private var verticalFeather: LinearGradient {
        let fadeLength: CGFloat = 24
        let stops = (0 ... 32).map { step in
            let location = CGFloat(step) / 32
            let distanceFromEdge = min(location, 1 - location) * bandHeight
            let progress = min(distanceFromEdge / fadeLength, 1)
            // Smootherstep has zero slope at both ends of the fade.
            let opacity = progress * progress * progress
                * (progress * (progress * 6 - 15) + 10)

            return Gradient.Stop(
                color: .white.opacity(opacity),
                location: location
            )
        }

        return LinearGradient(
            stops: stops,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var eventRow: some View {
        ForEach(events) { event in
            Group {
                switch event.style {
                case .chip:
                    ScheduleChip(
                        icon: event.icon,
                        iconColor: event.iconColor,
                        iconSymbolColor: event.iconSymbolColor,
                        label: event.label
                    )
                case .dot:
                    ScheduleDot(
                        icon: event.icon,
                        iconColor: event.iconColor,
                        iconSymbolColor: event.iconSymbolColor
                    )
                }
            }
            .fixedSize()
            // Pin the marker's icon circle to the event's time. The explicit
            // band-sized frame anchors each marker to the band's leading edge
            // itself — markers of different widths otherwise get mutually
            // aligned by the overlay's implicit stack, shifting the narrow
            // ones right of their time.
            .offset(
                x: (event.minuteOfDay / 1440) * dayWidth - EventMarker.timeAnchor
            )
            .frame(width: dayWidth, height: bandHeight, alignment: .leading)
        }
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(0 ..< 24, id: \.self) { hour in
                ZStack(alignment: .leading) {
                    if hour.isMultiple(of: 2) {
                        label(forHour: hour)
                            .fixedSize()
                    }
                }
                .frame(width: hourWidth, height: labelHeight, alignment: .leading)
            }
        }
    }

    private func formattedTime(_ minute: Double) -> String {
        let roundedMinute = Int(minute.rounded()) % 1440
        let hour = roundedMinute / 60
        let minute = roundedMinute % 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(hour12):\(String(format: "%02d", minute))"
    }

    /// Sky colors sampled every 15 minutes across the hour.
    private func gradientStops(forHour hour: Int) -> [Gradient.Stop] {
        let startMinute = Double(hour) * 60
        return (0 ... 4).map { step in
            Gradient.Stop(
                color: schedule.color(atMinute: startMinute + Double(step) * 15),
                location: Double(step) / 4
            )
        }
    }

    private func label(forHour hour: Int) -> Text {
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? "AM" : "PM"
        return (
            Text("\(hour12)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            + Text(" \(meridiem)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
        )
        .foregroundStyle(.secondary)
    }
}

#Preview {
    DayNightTimelineView(events: [
        TimelineEventItem(
            minuteOfDay: 6 * 60 + 30,
            icon: "sunrise.fill",
            iconColor: .yellow,
            iconSymbolColor: .black.opacity(0.75),
            label: "Wake"
        ),
        TimelineEventItem(
            minuteOfDay: 22 * 60 + 30,
            icon: "bed.double.fill",
            iconColor: .purple,
            iconSymbolColor: .white,
            label: "Bedtime"
        ),
        TimelineEventItem(
            minuteOfDay: 19 * 60,
            style: .dot,
            icon: "lamp.table.fill",
            iconColor: .orange,
            iconSymbolColor: .white,
            label: "Warm Light"
        ),
    ])
    .background(.black)
    .preferredColorScheme(.dark)
}
