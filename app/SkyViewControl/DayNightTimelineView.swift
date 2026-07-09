import SwiftUI

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
    var chips: [TimelineChipItem] = []

    private static let hourWidth: CGFloat = 44
    private static let bandHeight: CGFloat = 65
    private static let labelHeight: CGFloat = 26
    private static let headroom: CGFloat = 6
    private static let dayWidth = hourWidth * 24
    private static let dayRange = -50 ..< 50

    @State private var position = ScrollPosition()
    @State private var hasCentered = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nowMinute = context.date.timeIntervalSince(
                Calendar.current.startOfDay(for: context.date)
            ) / 60
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Self.dayRange, id: \.self) { dayIndex in
                        DayCell(
                            nowMinuteOfDay: nowMinute,
                            chips: chips,
                            schedule: schedule,
                            hourWidth: Self.hourWidth,
                            bandHeight: Self.bandHeight,
                            labelHeight: Self.labelHeight,
                            headroom: Self.headroom
                        )
                        // Chips near midnight overhang into the next day;
                        // keep each day above the day to its right.
                        .zIndex(Double(-dayIndex))
                    }
                }
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.center)
            // defaultScrollAnchor lands on the middle of the strip, which is
            // midnight; nudge once to center on the current time.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { viewportWidth in
                guard !hasCentered else { return }
                hasCentered = true
                let contentWidth = CGFloat(Self.dayRange.count) * Self.dayWidth
                let centered = (contentWidth - viewportWidth) / 2
                position.scrollTo(x: centered + (nowMinute / 1440) * Self.dayWidth)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                let contentWidth = CGFloat(Self.dayRange.count) * Self.dayWidth
                let margin = Self.dayWidth * 2
                let recenter = Self.dayWidth * 40
                if x < margin {
                    position.scrollTo(x: x + recenter)
                } else if x > contentWidth - margin {
                    position.scrollTo(x: x - recenter)
                }
            }
            .frame(height: Self.headroom + Self.bandHeight + Self.labelHeight)
            .overlay(edgeFade)
        }
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

/// One 24-hour copy of the strip: the sky band with ticks, the now marker
/// and event chips overlaid at their times, and hour labels beneath.
private struct DayCell: View {
    let nowMinuteOfDay: Double
    let chips: [TimelineChipItem]
    let schedule: SunSchedule
    let hourWidth: CGFloat
    let bandHeight: CGFloat
    let labelHeight: CGFloat
    let headroom: CGFloat

    private var dayWidth: CGFloat { hourWidth * 24 }

    var body: some View {
        VStack(spacing: 0) {
            band
                .overlay(alignment: .leading) { nowMarker }
                .overlay(alignment: .leading) { chipRow }
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
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 10 / bandHeight),
                    .init(color: .white, location: 1 - 10 / bandHeight),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var nowMarker: some View {
        Color.clear
            .frame(width: 8, height: bandHeight + 2)
            .glassEffect(
                .clear.tint(Color(red: 0.92, green: 0.12, blue: 0.16)),
                in: .capsule
            )
            .offset(x: (nowMinuteOfDay / 1440) * dayWidth - 4)
    }

    private var chipRow: some View {
        ForEach(chips) { chip in
            ScheduleChip(
                icon: chip.icon,
                iconColor: chip.iconColor,
                iconSymbolColor: chip.iconSymbolColor,
                label: chip.label
            )
            .fixedSize()
            // 20 = chip leading padding (7) + icon radius (13), so the icon
            // circle is centered on the event time.
            .offset(x: (chip.minuteOfDay / 1440) * dayWidth - 20)
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
    DayNightTimelineView(chips: [
        TimelineChipItem(
            minuteOfDay: 6 * 60 + 30,
            icon: "sunrise.fill",
            iconColor: .yellow,
            iconSymbolColor: .black.opacity(0.75),
            label: "Wake"
        ),
        TimelineChipItem(
            minuteOfDay: 22 * 60 + 30,
            icon: "bed.double.fill",
            iconColor: .purple,
            iconSymbolColor: .white,
            label: "Bedtime"
        ),
    ])
    .background(.black)
    .preferredColorScheme(.dark)
}
