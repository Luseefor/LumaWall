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
        let (rise, set) = sunMinutes(
            dayOfYear: day,
            timezoneOffsetHours: timezoneOffsetHours,
            latitude: latitude,
            longitude: longitude
        )
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if rise <= set {
            return minutes >= rise && minutes < set
        }
        return minutes >= rise || minutes < set
    }

    /// Next sunrise/sunset strictly after `date`, or nil when neither occurs
    /// in the next two days (polar day/night). The day/night timer arms this
    /// instead of the fixed start hours when sunrise/sunset drives the
    /// period — otherwise transitions fall between two fixed boundaries and
    /// no timer ever fires for them.
    public static func nextTransition(
        after date: Date = .now,
        latitude: Double,
        longitude: Double,
        calendar: Calendar = .current
    ) -> Date? {
        var candidates: [Date] = []
        for dayOffset in 0...2 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let day = calendar.ordinality(of: .day, in: .year, for: dayDate) ?? 1
            let timezoneOffsetHours = Double(calendar.timeZone.secondsFromGMT(for: dayDate)) / 3_600
            let (rise, set) = sunMinutes(
                dayOfYear: day,
                timezoneOffsetHours: timezoneOffsetHours,
                latitude: latitude,
                longitude: longitude
            )
            // Degenerate polar pairs never transition; skip the day.
            if (rise == 0 && set == 24 * 60) || (rise == 24 * 60 && set == 0) { continue }
            for minutes in [rise, set] {
                let hour = minutes / 60
                let minute = minutes % 60
                if let candidate = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: dayDate
                ), candidate.timeIntervalSince(date) > 60 {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.min()
    }

    /// Sunrise/sunset minutes after midnight for a day of the year. Shared by
    /// the daylight check and the transition forecast so the two cannot drift.
    private static func sunMinutes(
        dayOfYear day: Int,
        timezoneOffsetHours: Double,
        latitude: Double,
        longitude: Double
    ) -> (rise: Int, set: Int) {
        let lngHour = longitude / 15
        let tRise = Double(day) + ((6 - lngHour) / 24)
        let tSet = Double(day) + ((18 - lngHour) / 24)
        let rise = solarTime(t: tRise, latitude: latitude, longitude: longitude, rising: true, timezoneOffsetHours: timezoneOffsetHours)
        let set = solarTime(t: tSet, latitude: latitude, longitude: longitude, rising: false, timezoneOffsetHours: timezoneOffsetHours)
        return (rise, set)
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
            // Polar edge: cosH > 1 means the sun never rises (polar night),
            // cosH < -1 means it never sets (polar day). The old code returned
            // rise=0/set=1440 in both cases, reporting full daylight through
            // polar night. Return a degenerate pair that reads correctly on
            // both branches of isDaylight instead.
            if cosH > 1 {
                return rising ? 24 * 60 : 0
            } else {
                return rising ? 0 : 24 * 60
            }
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
    private var _lastRequestAt: Date?
    private var _onFirstFix: (() -> Void)?

    /// Called once, when the first location fix arrives. The app uses it to
    /// re-evaluate solar automations immediately: the fix lands
    /// asynchronously after launch, and without this the sunrise/sunset mode
    /// would sit on the hour-based fallback until the next fixed boundary
    /// (up to 12 hours off).
    public var onFirstFix: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFirstFix
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onFirstFix = newValue
        }
    }

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

    /// Minimum age of the last fix before asking again. Coordinates only feed
    /// sunrise/sunset math, which barely moves within minutes, without this,
    /// every automation evaluation (clock, appearance, workspace events) wakes
    /// location hardware for a fix we already have.
    private static let fixThrottle: TimeInterval = 15 * 60

    public func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // When-In-Use is all sunrise/sunset needs (one coarse fix), and it
            // matches the declared plist keys + settings copy. Requesting Always
            // here could never be granted (no Always usage-description key), so
            // the status stayed `.notDetermined` and the system re-prompted on
            // every launch.
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            lock.lock()
            let haveFix = _coordinate != nil
            let recent = _lastRequestAt.map { Date().timeIntervalSince($0) < Self.fixThrottle } ?? false
            if !recent { _lastRequestAt = Date() }
            lock.unlock()
            // Always take the first fix (automation has nothing without it);
            // afterwards at most one fix per throttle window.
            if haveFix, recent { return }
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
        let isFirst = _coordinate == nil
        _coordinate = locations.last?.coordinate
        let handler = _onFirstFix
        lock.unlock()
        if isFirst { handler?() }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
