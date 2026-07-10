import SwiftUI

/// Sheet for editing the lamp schedule. Wake/bedtime are read-only until
/// they're wired to real settings; custom automations can be added,
/// retimed, and removed (in memory only for now).
struct ScheduleEditorView: View {
    @Bindable var store: LampScheduleStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Lamp") {
                    builtInRow(store.wake)
                    builtInRow(store.bedtime)
                }

                Section("Automations") {
                    ForEach($store.automations) { $automation in
                        HStack(spacing: 12) {
                            EventIconCircle(
                                icon: automation.icon,
                                color: automation.iconColor,
                                symbolColor: automation.iconSymbolColor,
                                diameter: 28
                            )
                            Text(automation.name)
                            Spacer()
                            DatePicker(
                                "Time",
                                selection: timeBinding($automation),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                        }
                    }
                    .onDelete { store.automations.remove(atOffsets: $0) }
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    // Stub: a real editor for name/icon/scene comes later.
                    Button("Add", systemImage: "plus") {
                        store.automations.append(
                            LampAutomation(
                                name: "Scene",
                                minuteOfDay: 17 * 60,
                                icon: "paintpalette.fill",
                                iconColor: .teal
                            )
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
    }

    private func builtInRow(_ automation: LampAutomation) -> some View {
        HStack(spacing: 12) {
            EventIconCircle(
                icon: automation.icon,
                color: automation.iconColor,
                symbolColor: automation.iconSymbolColor,
                diameter: 28
            )
            Text(automation.name)
            Spacer()
            Text(formattedTimeOfDay(automation.minuteOfDay))
                .foregroundStyle(.secondary)
        }
    }

    /// Bridges an automation's minutes-since-midnight to the DatePicker.
    private func timeBinding(_ automation: Binding<LampAutomation>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now)
                .addingTimeInterval(automation.wrappedValue.minuteOfDay * 60)
        } set: { date in
            automation.wrappedValue.minuteOfDay =
                date.timeIntervalSince(Calendar.current.startOfDay(for: date)) / 60
        }
    }
}

#Preview {
    ScheduleEditorView(store: LampScheduleStore())
        .preferredColorScheme(.dark)
}
