import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var locationProvider: LocationProvider
    var sunProvider: SunScheduleProvider

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    if let place = locationProvider.placeDescription {
                        LabeledContent("Location", value: place)
                    } else if let location = locationProvider.location {
                        LabeledContent(
                            "Location",
                            value: String(
                                format: "%.2f, %.2f",
                                location.coordinate.latitude,
                                location.coordinate.longitude
                            )
                        )
                    } else if !locationProvider.isDenied {
                        LabeledContent("Location", value: "Not available")
                    }

                    if locationProvider.isDenied {
                        Text("Location access is off, so sunrise and sunset times may not match where you are.")
                            .foregroundStyle(.secondary)
                        Button("Turn On in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }

                Section("Sun Schedule Diagnostics") {
                    LabeledContent(
                        "Source",
                        value: sunProvider.isLoading ? "Loading…" : sunProvider.source.label
                    )
                    LabeledContent(
                        "Sunrise",
                        value: formattedTime(sunProvider.schedule.sunrise)
                    )
                    LabeledContent(
                        "Sunset",
                        value: formattedTime(sunProvider.schedule.sunset)
                    )

                    if let location = sunProvider.scheduleLocation {
                        LabeledContent(
                            "Query Coordinates",
                            value: String(
                                format: "%.4f, %.4f",
                                location.coordinate.latitude,
                                location.coordinate.longitude
                            )
                        )
                    }

                    if let lastUpdated = sunProvider.lastUpdated {
                        LabeledContent(
                            "Updated",
                            value: lastUpdated.formatted(date: .omitted, time: .standard)
                        )
                    }

                    if let error = sunProvider.errorMessage {
                        Text("WeatherKit error: \(error)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if sunProvider.source == .placeholder {
                        Text("These are built-in placeholder times, not live WeatherKit data.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if sunProvider.source == .weatherKitFallback {
                        Text("WeatherKit was queried using the San Francisco fallback location.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Version", value: "0.1.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func formattedTime(_ minute: Double) -> String {
        let roundedMinute = Int(minute.rounded()) % 1440
        let hour = roundedMinute / 60
        let minute = roundedMinute % 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? "AM" : "PM"
        return "\(hour12):\(String(format: "%02d", minute)) \(meridiem)"
    }
}

#Preview {
    SettingsView(
        locationProvider: LocationProvider(),
        sunProvider: SunScheduleProvider()
    )
        .preferredColorScheme(.dark)
}
