import SwiftUI

/// A schedule moment (wake/bedtime chip or sun event) the loupe is over.
struct FocusedTimelineEvent: Equatable {
    var name: String
    var minuteOfDay: Double
}

/// Horizontally scrolling day/night timeline, shaded by the sun schedule,
/// with hour ticks across the band, labels every other hour, a liquid-glass
/// "now" marker, and scheduled-event chips pinned at their times.
///
/// Infinite scroll works Mario-64-staircase style: the strip is a ~100-day
/// buffer, and whenever the scroll offset drifts within two days of either
/// end it is teleported back toward the middle by an exact multiple of one
/// day's width. Every copy of the day is "today", so the jump is invisible
/// and the marker/chips repeat in each copy.
///
/// The lazy unit is one full day, so decorations that spill past an hour
/// (chips, the marker) aren't culled until the whole day leaves the screen.
struct DayNightTimelineView: View {
    var schedule: SunSchedule = .placeholder
    var events: [TimelineEventItem] = []
    var onFocusedEventChange: (FocusedTimelineEvent?) -> Void = { _ in }

    /// How close (in minutes) the loupe must be to an event to count as
    /// over it. ~14 min covers the loupe's own width plus a little grace.
    private static let eventGraceMinutes = 14.0

    private static let hourWidth: CGFloat = 44
    private static let bandHeight: CGFloat = 72
    private static let labelHeight: CGFloat = 26
    private static let labelOverlap: CGFloat = 6
    private static let headroom: CGFloat = 6
    private static let dayWidth = hourWidth * 24
    private static let dayRange = -50 ..< 50

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
    @State private var isSnappedToNow = false
    @State private var isSnappingToNow = false
    @State private var userGestureIsActive = false
    @State private var snapAllowedForGesture = false
    @State private var gestureStartOffset: CGFloat = 0

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMinute = context.date.timeIntervalSince(
                Calendar.current.startOfDay(for: context.date)
            ) / 60
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Self.dayRange, id: \.self) { dayIndex in
                        DayCell(
                            events: events,
                            schedule: schedule,
                            hourWidth: Self.hourWidth,
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
                    dayWidth: Self.dayWidth,
                    threshold: 24,
                    isEnabled: snapAllowedForGesture,
                    onSnap: {
                        // The deceleration target just got retargeted onto
                        // now: collapse the loupe during the travel, not
                        // after it. Only honor calls tied to a drag ending —
                        // updateTarget can also run on layout changes.
                        guard userGestureIsActive || scrollPhase == .decelerating
                        else { return }
                        isSnappingToNow = true
                        isSnappedToNow = true
                    }
                )
            )
            .scrollPosition($position)
            .defaultScrollAnchor(.center)
            // defaultScrollAnchor lands on the middle of the strip, which is
            // midnight; nudge once to center on the current time.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                viewportWidth = width
                guard !hasCentered else { return }
                hasCentered = true
                let contentWidth = CGFloat(Self.dayRange.count) * Self.dayWidth
                let centered = (contentWidth - width) / 2
                isSnappedToNow = true
                position.scrollTo(x: centered + (nowMinute / 1440) * Self.dayWidth)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                scrollOffset = x
                focusedMinute = minuteAtViewportCenter(offset: x)
                updateFocusedEvent()
                // Only a finger-driven move breaks the snap; the offset also
                // changes while decelerating onto now with the loupe already
                // collapsing, and that must not re-expand it.
                if scrollPhase == .tracking || scrollPhase == .interacting,
                   abs(x - gestureStartOffset) > 0.25,
                   isSnappedToNow {
                    isSnappedToNow = false
                }
                let contentWidth = CGFloat(Self.dayRange.count) * Self.dayWidth
                let margin = Self.dayWidth * 2
                let recenter = Self.dayWidth * 40
                if x < margin {
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
                }
                if newPhase == .interacting, isSnappedToNow {
                    isSnappedToNow = false
                }
                if newPhase == .idle, userGestureIsActive {
                    userGestureIsActive = false
                    if snapAllowedForGesture {
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
            }
            .overlay(edgeFade)
            .sensoryFeedback(.selection, trigger: hapticDetent)
            .sensoryFeedback(
                .impact(weight: .heavy, intensity: 0.9),
                trigger: snapHaptic
            )
        }
    }

    private func hourAtViewportCenter(offset: CGFloat) -> Int {
        Int(floor((offset + viewportWidth / 2) / Self.hourWidth))
    }

    private func minuteAtViewportCenter(offset: CGFloat) -> Int {
        let centerX = offset + viewportWidth / 2
        let dayX = centerX.truncatingRemainder(dividingBy: Self.dayWidth)
        let normalizedX = dayX < 0 ? dayX + Self.dayWidth : dayX
        return Int((normalizedX / Self.dayWidth * 1440).rounded()) % 1440
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
        let markerX = (minuteOfDay / 1440) * Self.dayWidth
        let centeredContentX = offset + viewportWidth / 2
        let nearestDay = ((centeredContentX - markerX) / Self.dayWidth).rounded()
        return markerX + nearestDay * Self.dayWidth
    }

    private func snapToNowIfClose(minuteOfDay: Double, offset: CGFloat) {
        let markerX = nowMarkerContentX(minuteOfDay: minuteOfDay, near: offset)
        let targetOffset = markerX - viewportWidth / 2
        let distance = abs(targetOffset - offset)
        guard distance <= 24 else { return }

        if distance <= 1 {
            completeNowSnap()
            return
        }

        isSnappingToNow = true
        // Collapse the loupe alongside the scroll, not after it.
        isSnappedToNow = true
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
        snapHaptic &+= 1
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
    private var centerLoupe: some View {
        Color.clear
            // Animate the real size rather than scaleEffect: a transform
            // squashes the rendered glass (refraction and highlights
            // included), which reads as growing from one side. A true size
            // change lets the glass morph its shape, centered.
            .frame(
                width: isSnappedToNow ? 5 : 18,
                height: (Self.bandHeight - 16) * (isSnappedToNow ? 0.85 : 1)
            )
            .glassEffect(.clear, in: .capsule)
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
            .frame(width: 18, height: Self.bandHeight - 16)
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

    /// Dimming gradients at the left/right edges, over everything. Eased
    /// with smoothstep so the fade has no visible start or end line.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            dimGradient(fadeFrom: .leading)
                .frame(width: 40)
            Spacer(minLength: 0)
            dimGradient(fadeFrom: .trailing)
                .frame(width: 40)
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
    let onSnap: () -> Void

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
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
        // Feather the band's top and bottom edges (ticks included).
        .mask(verticalFeather)
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
        ZStack(alignment: .leading) {
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

            sunEventLabel(
                minute: schedule.sunrise,
                edge: .leading
            )
            sunEventLabel(
                minute: schedule.sunset,
                edge: .trailing
            )
        }
    }

    private func sunEventLabel(minute: Double, edge: HorizontalEdge) -> some View {
        let shieldWidth: CGFloat = 104
        let eventInset: CGFloat = 18
        let markerWidth: CGFloat = 10
        let eventX = (minute / 1440) * dayWidth
        let isSunrise = edge == .leading

        return ZStack(alignment: isSunrise ? .leading : .trailing) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(spacing: 5) {
                if !isSunrise { eventTime(minute) }
                sunEventMarker(isSunrise: isSunrise)
                if isSunrise { eventTime(minute) }
            }
            .padding(
                isSunrise ? .leading : .trailing,
                eventInset - markerWidth / 2
            )
        }
        .frame(width: shieldWidth, height: labelHeight)
        .offset(
            x: isSunrise
                ? eventX - eventInset
                : eventX + eventInset - shieldWidth
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(isSunrise ? "Sunrise" : "Sunset"), \(formattedTime(minute))"
        )
    }

    private func eventTime(_ minute: Double) -> Text {
        Text(formattedTime(minute))
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
    }

    /// Capsule pointing the sun's way: sunrise glows toward the top with a
    /// white sun dot rising out of it, sunset glows toward the bottom with
    /// a black dot sinking into it.
    private func sunEventMarker(isSunrise: Bool) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: isSunrise
                        ? [Color(red: 1, green: 0.76, blue: 0.22), .black]
                        : [.black, Color(red: 0.98, green: 0.52, blue: 0.20)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: isSunrise ? .top : .bottom) {
                Circle()
                    .fill(isSunrise ? Color.white : Color.black)
                    .frame(width: 5, height: 5)
                    .padding(2.5)
            }
            .frame(width: 10, height: 16)
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
