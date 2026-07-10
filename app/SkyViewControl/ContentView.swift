import SwiftUI

struct ContentView: View {
    @State private var isLampOn = true
    @State private var showingDevicePicker = false
    @State private var showingSettings = false
    @State private var showingScheduleEditor = false
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
                    LampPreviewView()
                        .padding(.horizontal, 72)

                    HStack {
                        glassIconButton("bed.double.fill") {}
                        Spacer()
                        glassIconButton("deskclock") {
                            showingScheduleEditor = true
                        }
                    }
                    .overlay(alignment: .bottom) { timelineEventCallout }
                    .padding(.horizontal, 20)

                    DayNightTimelineView(
                        schedule: sunProvider.schedule,
                        events: scheduleStore.all.map(TimelineEventItem.init),
                        onFocusedEventChange: { event in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                                focusedTimelineEvent = event
                            }
                        }
                    )
                }

                Spacer()
            }

            bottomBar
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

    /// Name and precise time of the event the timeline loupe is over,
    /// centered between the two schedule buttons. The timeline is a later
    /// sibling, so the offset transition sinks the label down behind it —
    /// it reads as popping up out of the timeline.
    @ViewBuilder
    private var timelineEventCallout: some View {
        if let event = focusedTimelineEvent {
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

    private var topBar: some View {
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
        HStack(spacing: 12) {
            glassIconButton("power", size: 56) {
                isLampOn.toggle()
            }

            // Placeholder capsule; interactions coming next.
            Color.clear
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .capsule)

            glassIconButton("gear", size: 56) {
                showingSettings = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func glassIconButton(
        _ icon: String,
        size: CGFloat = 48,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
