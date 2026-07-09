import SwiftUI

/// A scheduled lamp event pinned to the day/night timeline.
struct TimelineChipItem: Identifiable {
    var id: String { label }
    var minuteOfDay: Double
    var icon: String
    var iconColor: Color
    var iconSymbolColor: Color
    var label: String
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
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [iconColor, iconColor.mix(with: .black, by: 0.22)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconSymbolColor)
                }
                .frame(width: 26, height: 26)

                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 7)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
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
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
    .preferredColorScheme(.dark)
}
