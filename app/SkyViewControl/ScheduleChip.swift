import SwiftUI

/// A scheduled lamp event pinned to the day/night timeline.
struct TimelineEventItem: Identifiable {
    enum Style {
        /// Glass capsule with icon and label (wake / bedtime).
        case chip
        /// Compact glass circle with just the icon (custom automations).
        case dot
    }

    var id = UUID()
    var minuteOfDay: Double
    var style: Style = .chip
    var icon: String
    var iconColor: Color
    var iconSymbolColor: Color
    var label: String
}

/// Shared geometry for the timeline's event markers. Chips and dots both
/// place their icon circle's center `timeAnchor` in from their leading edge,
/// so the timeline pins either style to its time with one offset.
enum EventMarker {
    static let iconDiameter: CGFloat = 26
    static let iconMargin: CGFloat = 7
    /// Distance from a marker's leading edge to its icon circle's center.
    static let timeAnchor = iconMargin + iconDiameter / 2
    /// The dot's fixed square side: icon plus a uniform margin, matching
    /// the chip's height and keeping the anchor at the dot's center.
    static let dotDiameter = iconDiameter + 2 * iconMargin
}

/// The gradient icon disc shared by chips, dots, and schedule editor rows.
struct EventIconCircle: View {
    let icon: String
    let color: Color
    let symbolColor: Color
    var diameter: CGFloat = EventMarker.iconDiameter

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.mix(with: .black, by: 0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: icon)
                .font(.system(size: diameter * 0.5, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Capsule chip for a scheduled lamp event (wake / bedtime). Will later open
/// a time picker and show the configured time; for now it's a static stub.
struct ScheduleChip: View {
    let icon: String
    let iconColor: Color
    let iconSymbolColor: Color
    let label: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                EventIconCircle(
                    icon: icon,
                    color: iconColor,
                    symbolColor: iconSymbolColor
                )
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.leading, EventMarker.iconMargin)
            .padding(.trailing, 16)
            .padding(.vertical, EventMarker.iconMargin)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Compact marker for a custom automation: the chip's gradient icon circle
/// in a glass disc, without the text.
struct ScheduleDot: View {
    let icon: String
    let iconColor: Color
    let iconSymbolColor: Color
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            EventIconCircle(
                icon: icon,
                color: iconColor,
                symbolColor: iconSymbolColor
            )
            // An explicit square frame, not padding: the glass takes the
            // shape of the view it's attached to, and a fixed square is the
            // only way to guarantee it stays a circle.
            .frame(width: EventMarker.dotDiameter, height: EventMarker.dotDiameter)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

#Preview {
    HStack(spacing: 12) {
        ScheduleChip(
            icon: "sunrise.fill",
            iconColor: .yellow,
            iconSymbolColor: .black.opacity(0.75),
            label: "Wake"
        )
        ScheduleChip(
            icon: "bed.double.fill",
            iconColor: .purple,
            iconSymbolColor: .white,
            label: "Bedtime"
        )
        ScheduleDot(
            icon: "lamp.table.fill",
            iconColor: .orange,
            iconSymbolColor: .white
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
    .preferredColorScheme(.dark)
}
