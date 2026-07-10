import CoreLocation
import SwiftUI
import WeatherKit

/// Fetches today's real sun events from WeatherKit and exposes them as a
/// SunSchedule for the timeline. Falls back to the placeholder schedule
/// until a fetch succeeds (or if WeatherKit is unreachable).
@MainActor
@Observable
final class SunScheduleProvider {
    enum Source: Equatable {
        case placeholder
        case weatherKit
        case weatherKitFallback

        var label: String {
            switch self {
            case .placeholder: "Placeholder"
            case .weatherKit: "WeatherKit"
            case .weatherKitFallback: "WeatherKit (fallback)"
            }
        }
    }

    /// Used until the user grants location access at least once.
    static let fallbackLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)

    private(set) var schedule: SunSchedule = .placeholder
    private(set) var source: Source = .placeholder
    private(set) var scheduleLocation: CLLocation?
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    func refresh(at location: CLLocation?) async {
        let requestedLocation = location ?? Self.fallbackLocation
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let forecast = try await WeatherService.shared.weather(
                for: requestedLocation,
                including: .daily
            )
            let today = forecast.first { Calendar.current.isDateInToday($0.date) }
            if let sun = (today ?? forecast.first)?.sun,
               let schedule = SunSchedule(sunEvents: sun) {
                self.schedule = schedule
                source = location == nil ? .weatherKitFallback : .weatherKit
                scheduleLocation = requestedLocation
                lastUpdated = .now
            } else {
                errorMessage = "WeatherKit returned no usable sun events."
            }
        } catch {
            errorMessage = error.localizedDescription
            print("WeatherKit refresh failed: \(error)")
        }
    }
}

extension SunSchedule {
    /// Maps WeatherKit's SunEvents onto the minute-based schedule. Twilight
    /// moments can be nil at extreme latitudes; those fall back to fixed
    /// offsets from sunrise/sunset.
    init?(sunEvents: SunEvents, calendar: Calendar = .current) {
        func minutes(_ date: Date?) -> Double? {
            guard let date else { return nil }
            return date.timeIntervalSince(calendar.startOfDay(for: date)) / 60
        }
        guard
            let sunrise = minutes(sunEvents.sunrise),
            let sunset = minutes(sunEvents.sunset)
        else { return nil }

        self.init(
            astronomicalDawn: minutes(sunEvents.astronomicalDawn) ?? max(0, sunrise - 90),
            nauticalDawn: minutes(sunEvents.nauticalDawn) ?? max(0, sunrise - 60),
            civilDawn: minutes(sunEvents.civilDawn) ?? max(0, sunrise - 30),
            sunrise: sunrise,
            sunset: sunset,
            civilDusk: minutes(sunEvents.civilDusk) ?? min(1440, sunset + 30),
            nauticalDusk: minutes(sunEvents.nauticalDusk) ?? min(1440, sunset + 60),
            astronomicalDusk: minutes(sunEvents.astronomicalDusk) ?? min(1440, sunset + 90)
        )
    }
}
