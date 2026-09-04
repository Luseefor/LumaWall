import CoreLocation
import Foundation

/// Approximate sunrise/sunset using the NOAA solar noon equation.
public enum SolarSchedule: Sendable {
    public static func isDaylight(
        at date: Date = .now,
        latitude: Double,
        longitude: Double,
        calendar: Calendar = .current
    ) -> Bool {
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let timezoneOffsetHours = Double(calendar.timeZone.secondsFromGMT(for: date)) / 3_600
        let lngHour = longitude / 15
        let tRise = Double(day) + ((6 - lngHour) / 24)
        let tSet = Double(day) + ((18 - lngHour) / 24)
        let rise = solarTime(t: tRise, latitude: latitude, longitude: longitude, rising: true, timezoneOffsetHours: timezoneOffsetHours)
        let set = solarTime(t: tSet, latitude: latitude, longitude: longitude, rising: false, timezoneOffsetHours: timezoneOffsetHours)
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if rise <= set {
            return minutes >= rise && minutes < set
        }
        return minutes >= rise || minutes < set
    }

    private static func solarTime(
        t: Double,
        latitude: Double,
        longitude: Double,
        rising: Bool,
        timezoneOffsetHours: Double
    ) -> Int {
        let m = (0.9856 * t) - 3.289
        var l = m + (1.916 * sin(m * .pi / 180)) + (0.020 * sin(2 * m * .pi / 180)) + 282.634
        l = normalizeDegrees(l)
        var ra = atan(0.91764 * tan(l * .pi / 180)) * 180 / .pi
        ra = normalizeDegrees(ra)
        ra = (ra + (floor(l / 90) * 90 - floor(ra / 90) * 90)) / 15
        let sinDec = 0.39782 * sin(l * .pi / 180)
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(90.833 * .pi / 180) - (sinDec * sin(latitude * .pi / 180)))
            / (cosDec * cos(latitude * .pi / 180))
        guard cosH >= -1, cosH <= 1 else {
            return rising ? 0 : 24 * 60
        }
        var h = rising
            ? 360 - (acos(cosH) * 180 / .pi)
            : (acos(cosH) * 180 / .pi)
        h /= 15
        let tLocal = h + ra - (0.06571 * t) - 6.622
        var ut = tLocal - longitude / 15
        ut = ((ut.truncatingRemainder(dividingBy: 24)) + 24).truncatingRemainder(dividingBy: 24)
        let local = ((ut + timezoneOffsetHours).truncatingRemainder(dividingBy: 24) + 24)
            .truncatingRemainder(dividingBy: 24)
        return Int((local * 60).rounded())
    }

    private static func normalizeDegrees(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }
}

/// Rough location for sunrise/sunset. Safe to call from the main actor app model.
public final class LocationDaylightProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    public static let shared = LocationDaylightProvider()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var _coordinate: CLLocationCoordinate2D?

    public var coordinate: CLLocationCoordinate2D? {
        lock.lock()
        defer { lock.unlock() }
        return _coordinate
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lock.lock()
        defer { lock.unlock() }
        _coordinate = locations.last?.coordinate
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
