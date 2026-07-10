import SwiftUI

/// A scheduled lamp action pinned to a time of day.
struct LampAutomation: Identifiable {
    enum Role {
        /// The built-in on/off pair, always present.
        case wake, bedtime
        /// A user automation, e.g. switching to a scene.
        case custom
    }

    var id = UUID()
    var role: Role = .custom
    var name: String
    var minuteOfDay: Double
    var icon: String
    var iconColor: Color
    var iconSymbolColor: Color = .white
}

/// Owns the lamp schedule shown on the timeline and edited in the schedule
/// sheet. In-memory for now: wake/bedtime are hardcoded until they're wired
/// to real settings, and persistence will replace the seeded automations.
@Observable
final class LampScheduleStore {
    let wake = LampAutomation(
        role: .wake,
        name: "Wake",
        minuteOfDay: 6 * 60 + 30,
        icon: "sunrise.fill",
        iconColor: .yellow,
        iconSymbolColor: .black.opacity(0.75)
    )
    let bedtime = LampAutomation(
        role: .bedtime,
        name: "Bedtime",
        minuteOfDay: 22 * 60 + 30,
        icon: "bed.double.fill",
        iconColor: .purple
    )

    var automations: [LampAutomation] = [
        LampAutomation(
            name: "Warm Light",
            minuteOfDay: 19 * 60,
            icon: "lamp.table.fill",
            iconColor: .orange
        ),
        LampAutomation(
            name: "Wind Down",
            minuteOfDay: 21 * 60 + 15,
            icon: "moon.fill",
            iconColor: .indigo
        ),
    ]

    /// Everything the timeline shows, built-ins first.
    var all: [LampAutomation] { [wake, bedtime] + automations }
}

extension TimelineEventItem {
    /// Built-ins keep the labeled chip; custom automations render as dots.
    init(_ automation: LampAutomation) {
        self.init(
            id: automation.id,
            minuteOfDay: automation.minuteOfDay,
            style: automation.role == .custom ? .dot : .chip,
            icon: automation.icon,
            iconColor: automation.iconColor,
            iconSymbolColor: automation.iconSymbolColor,
            label: automation.name
        )
    }
}

/// "9:05 PM"-style formatting for minutes since local midnight.
func formattedTimeOfDay(_ minuteOfDay: Double) -> String {
    let roundedMinute = Int(minuteOfDay.rounded()) % 1440
    let hour = roundedMinute / 60
    let minute = roundedMinute % 60
    let hour12 = hour % 12 == 0 ? 12 : hour % 12
    let meridiem = hour < 12 ? "AM" : "PM"
    return "\(hour12):\(String(format: "%02d", minute)) \(meridiem)"
}
