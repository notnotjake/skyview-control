import SwiftUI

/// Sun event times for one day, expressed as minutes since local midnight.
/// Currently a hardcoded placeholder; will be populated from WeatherKit's
/// SunEvents (which exposes the same set of dawn/dusk moments).
struct SunSchedule {
    var astronomicalDawn: Double = 3 * 60 + 45
    var nauticalDawn: Double = 4 * 60 + 35
    var civilDawn: Double = 5 * 60 + 15
    var sunrise: Double = 5 * 60 + 45
    var sunset: Double = 20 * 60 + 30
    var civilDusk: Double = 21 * 60 + 0
    var nauticalDusk: Double = 21 * 60 + 40
    var astronomicalDusk: Double = 22 * 60 + 30

    static let placeholder = SunSchedule()

    private static let night = Color(red: 0.04, green: 0.05, blue: 0.12)
    private static let day = Color(red: 0.36, green: 0.54, blue: 0.78)
    private static let warm = Color(red: 0.95, green: 0.55, blue: 0.28)

    /// Sky color for a moment in the day, for shading the timeline.
    func color(atMinute minute: Double) -> Color {
        let base = Self.night.mix(with: Self.day, by: daylight(atMinute: minute))
        return base.mix(with: Self.warm, by: warmth(atMinute: minute))
    }

    /// 0 = deep night, 1 = full day, ramping through the twilight stages.
    private func daylight(atMinute m: Double) -> Double {
        let keypoints: [(Double, Double)] = [
            (astronomicalDawn, 0), (nauticalDawn, 0.10), (civilDawn, 0.30),
            (sunrise, 0.65), (sunrise + 45, 1),
            (sunset - 45, 1), (sunset, 0.65),
            (civilDusk, 0.30), (nauticalDusk, 0.10), (astronomicalDusk, 0),
        ]
        guard m > keypoints.first!.0 else { return 0 }
        guard m < keypoints.last!.0 else { return 0 }
        for ((t0, v0), (t1, v1)) in zip(keypoints, keypoints.dropFirst()) where m <= t1 {
            return v0 + (v1 - v0) * ((m - t0) / (t1 - t0))
        }
        return 0
    }

    /// Orange glow concentrated around sunrise and sunset.
    private func warmth(atMinute m: Double) -> Double {
        func glow(around event: Double) -> Double {
            let d = (m - event) / 40
            return 0.45 * exp(-d * d)
        }
        return min(0.45, glow(around: sunrise) + glow(around: sunset))
    }
}
