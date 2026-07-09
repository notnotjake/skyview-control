import CoreLocation
import SwiftUI

/// Owns the location permission flow and the lamp's coordinates.
///
/// Every fix is persisted, so a user who chose "Allow Once" keeps their
/// location across launches without being re-prompted (Allow Once resets
/// the authorization to "not determined" on the next launch — we only
/// re-prompt if we've never gotten a fix at all). With standing permission,
/// the location is refreshed on every app open.
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private static let latitudeKey = "lampLocation.latitude"
    private static let longitudeKey = "lampLocation.longitude"

    private let manager = CLLocationManager()

    private(set) var location: CLLocation?
    private(set) var status: CLAuthorizationStatus
    private(set) var placeDescription: String?

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if let saved = Self.loadSavedLocation() {
            location = saved
            Task { await reverseGeocode(saved) }
        }
    }

    /// Call on app open: prompts on true first run, otherwise refreshes the
    /// fix if we're allowed to.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // A saved fix means a previous "Allow Once" — don't ask again.
            if location == nil {
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let fix = locations.last else { return }
        Task { @MainActor in
            location = fix
            Self.save(fix)
            await reverseGeocode(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location fetch failed: \(error)")
    }

    private func reverseGeocode(_ location: CLLocation) async {
        guard let placemark = try? await CLGeocoder()
            .reverseGeocodeLocation(location).first
        else { return }
        placeDescription = [placemark.locality, placemark.administrativeArea]
            .compactMap(\.self)
            .joined(separator: ", ")
    }

    private static func loadSavedLocation() -> CLLocation? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: latitudeKey) != nil else { return nil }
        return CLLocation(
            latitude: defaults.double(forKey: latitudeKey),
            longitude: defaults.double(forKey: longitudeKey)
        )
    }

    private static func save(_ location: CLLocation) {
        let defaults = UserDefaults.standard
        defaults.set(location.coordinate.latitude, forKey: latitudeKey)
        defaults.set(location.coordinate.longitude, forKey: longitudeKey)
    }
}
