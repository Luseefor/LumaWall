import CoreLocation
import Foundation
import LumaWallCore
import Testing

/// Sunrise/sunset math with a fixed GMT calendar so results are deterministic
/// regardless of the machine's locale or timezone.
struct SolarScheduleTests {
    private var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return gmt.date(from: components)!
    }

    @Test func equatorHasDayAtNoonNightAtMidnight() {
        #expect(
            SolarSchedule.isDaylight(
                at: date(month: 6, day: 21, hour: 12), latitude: 0, longitude: 0, calendar: gmt
            ))
        #expect(
            !SolarSchedule.isDaylight(
                at: date(month: 6, day: 21, hour: 0), latitude: 0, longitude: 0, calendar: gmt
            ))
    }

    @Test func polarNightStaysDarkAtNoon() {
        // Longyearbyen in mid-January: the sun never rises (exercises the
        // polar guard branch that clamps an impossible hour angle).
        #expect(
            !SolarSchedule.isDaylight(
                at: date(month: 1, day: 15, hour: 12), latitude: 78.2, longitude: 15.6, calendar: gmt
            ))
        #expect(
            !SolarSchedule.isDaylight(
                at: date(month: 1, day: 15, hour: 0), latitude: 78.2, longitude: 15.6, calendar: gmt
            ))
    }

    @Test func polarDayStaysLightAtMidnight() {
        // Same latitude in late June: the sun never sets.
        #expect(
            SolarSchedule.isDaylight(
                at: date(month: 6, day: 21, hour: 12), latitude: 78.2, longitude: 15.6, calendar: gmt
            ))
        #expect(
            SolarSchedule.isDaylight(
                at: date(month: 6, day: 21, hour: 0), latitude: 78.2, longitude: 15.6, calendar: gmt
            ))
    }

    @Test func farLongitudeWrapsDayBoundary() {  // Solar noon near the antimeridian falls around 00:00 GMT, so the
        // rise/set pair wraps past midnight GMT (overnight branch).
        #expect(
            SolarSchedule.isDaylight(
                at: date(month: 6, day: 21, hour: 0), latitude: 0, longitude: 179, calendar: gmt
            ))
        #expect(
            !SolarSchedule.isDaylight(
                at: date(month: 6, day: 21, hour: 12), latitude: 0, longitude: 179, calendar: gmt
            ))
    }

    @Test func locationProviderTracksUpdatesAndIgnoresFailures() {
        // Self-contained against the shared singleton (no order dependence):
        // record, fail (no-op), update, read back.
        let provider = LocationDaylightProvider.shared
        let manager = CLLocationManager()
        let before = provider.coordinate
        provider.locationManager(manager, didFailWithError: NSError(domain: "test", code: 1))
        #expect(provider.coordinate?.latitude == before?.latitude)
        provider.locationManager(
            manager, didUpdateLocations: [CLLocation(latitude: 52.37, longitude: 4.9)]
        )
        #expect(abs((provider.coordinate?.latitude ?? 0) - 52.37) < 0.001)
        #expect(abs((provider.coordinate?.longitude ?? 0) - 4.9) < 0.001)
    }

    @Test func initAndInactiveCallsDoNotStartLocationManager() {
        final class Box: @unchecked Sendable {
            var created = 0
        }
        let box = Box()
        let provider = LocationDaylightProvider {
            box.created += 1
            return FakeLocationClient(authorizationStatus: .authorized)
        }
        #expect(!provider.isActive)
        #expect(box.created == 0)

        provider.onFirstFix = {}
        provider.requestIfNeeded()
        provider.locationManagerDidChangeAuthorization(CLLocationManager())
        #expect(box.created == 0)
    }

    @Test func activatingAuthorizedProviderRequestsSingleFixAndStopsOnDeactivate() {
        let client = FakeLocationClient(authorizationStatus: .authorized, fireAuthOnDelegateAssign: true)
        final class Box: @unchecked Sendable {
            var created = 0
        }
        let box = Box()
        let provider = LocationDaylightProvider {
            box.created += 1
            return client
        }

        provider.setActive(true)
        #expect(provider.isActive)
        #expect(box.created == 1)
        #expect(client.delegate === provider)
        #expect(client.desiredAccuracy == kCLLocationAccuracyKilometer)
        #expect(client.locationRequests == 1)
        #expect(client.authorizationRequests == 0)

        // Repeated requests within the throttle window do not wake location again.
        provider.requestIfNeeded()
        #expect(client.locationRequests == 1)

        // Deliver a fix, then deactivate: location stops and cached coordinate clears.
        var firstFixFired = 0
        provider.onFirstFix = { firstFixFired += 1 }
        provider.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 37.77, longitude: -122.42)]
        )
        #expect(firstFixFired == 1)
        #expect(provider.coordinate != nil)

        provider.setActive(false)
        #expect(!provider.isActive)
        #expect(client.stopCalls == 1)
        #expect(client.delegate == nil)
        #expect(provider.coordinate == nil)

        // Late authorization callbacks while inactive must not request a fix.
        provider.locationManagerDidChangeAuthorization(CLLocationManager())
        #expect(client.locationRequests == 1)
    }

    @Test func activatingUndeterminedProviderRequestsAuthorizationThenFixOnGrant() {
        let client = FakeLocationClient(authorizationStatus: .notDetermined, fireAuthOnDelegateAssign: true)
        let provider = LocationDaylightProvider { client }

        provider.setActive(true)
        #expect(client.authorizationRequests == 1)
        #expect(client.locationRequests == 0)

        client.authorizationStatus = .authorized
        provider.locationManagerDidChangeAuthorization(CLLocationManager())
        #expect(client.locationRequests == 1)
    }
}

private final class FakeLocationClient: DaylightLocationClient, @unchecked Sendable {
    var delegate: (any CLLocationManagerDelegate)? {
        didSet {
            if let delegate, fireAuthOnDelegateAssign {
                delegate.locationManagerDidChangeAuthorization?(CLLocationManager())
            }
        }
    }
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var authorizationStatus: CLAuthorizationStatus
    let fireAuthOnDelegateAssign: Bool
    var authorizationRequests = 0
    var locationRequests = 0
    var stopCalls = 0

    init(authorizationStatus: CLAuthorizationStatus, fireAuthOnDelegateAssign: Bool = true) {
        self.authorizationStatus = authorizationStatus
        self.fireAuthOnDelegateAssign = fireAuthOnDelegateAssign
    }

    func requestWhenInUseAuthorization() {
        authorizationRequests += 1
    }

    func requestLocation() {
        locationRequests += 1
    }

    func stopUpdatingLocation() {
        stopCalls += 1
    }
}
