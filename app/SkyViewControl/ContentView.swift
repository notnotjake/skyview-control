import SwiftUI

struct ContentView: View {
    @State private var isLampOn = true
    @State private var showingDevicePicker = false
    @State private var showingSettings = false
    @State private var sunProvider = SunScheduleProvider()
    @State private var locationProvider = LocationProvider()

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
                        glassIconButton("deskclock") {}
                    }
                    .padding(.horizontal, 20)

                    DayNightTimelineView(schedule: sunProvider.schedule, chips: [
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(locationProvider: locationProvider)
                .preferredColorScheme(.dark)
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
