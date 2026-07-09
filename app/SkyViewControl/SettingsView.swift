import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var locationProvider: LocationProvider

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
}

#Preview {
    SettingsView(locationProvider: LocationProvider())
        .preferredColorScheme(.dark)
}
