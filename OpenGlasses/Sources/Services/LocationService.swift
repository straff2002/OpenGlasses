import Foundation
import CoreLocation

/// The region-monitoring surface a geofence tool needs (BK P1). Abstracting it lets `GeofenceTool`
/// route through the app's single `CLLocationManager`/delegate (`LocationService`) in production,
/// and lets tests inject a fake so entering/exiting a region, the authorization state, and the
/// 20-region cap are all drivable headlessly (no `CLLocationManager` on GPU / no permission prompt).
@MainActor
protocol RegionMonitoring: AnyObject {
    var regionAuthorizationStatus: CLAuthorizationStatus { get }
    var monitoredRegionCount: Int { get }
    func regionMonitoringAvailable() -> Bool
    func requestAlwaysAuthorization()
    func startMonitoringRegion(_ region: CLCircularRegion)
    func stopMonitoringRegion(_ region: CLCircularRegion)
    /// Fired on a region enter (`didEnter == true`) / exit (`false`).
    var onRegionEvent: ((CLRegion, _ didEnter: Bool) -> Void)? { get set }
    /// Fired when authorization becomes `authorizedAlways` — the moment deferred geofences can arm.
    var onBecameAuthorizedAlways: (() -> Void)? { get set }
}

/// Provides the user's current location for LLM context
@MainActor
class LocationService: NSObject, ObservableObject {
    @Published var currentLocation: CLLocation?
    /// Human-readable place for the current location (reverse geocoded).
    @Published var geocodedPlace: String?
    @Published var locationError: String?
    @Published var isAuthorized: Bool = false

    private let locationManager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }

    /// Region-monitoring event forwarders (BK P1). Set by `GeofenceTool.activate()`.
    var onRegionEvent: ((CLRegion, Bool) -> Void)?
    var onBecameAuthorizedAlways: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100  // Update every 100m
    }

    /// Request location permissions and start updates
    func startTracking() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isAuthorized = true
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            isAuthorized = false
            locationError = "Location access denied"
        @unknown default:
            break
        }
    }

    /// Step-level guidance needs Best accuracy and a tight filter (Plan CA); all-day context
    /// does not. Guiding only — `endPrecisionGuidance` restores the coarse defaults so
    /// navigation doesn't turn the app into a battery drain.
    func beginPrecisionGuidance() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
        locationManager.activityType = .fitness
        locationManager.startUpdatingLocation()
    }

    func endPrecisionGuidance() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
        locationManager.activityType = .other
    }

    /// One-shot fix await: re-kick updates (idempotent) and poll briefly for a location.
    /// Covers the two nil-fix realities: the first GPS fix after launch takes seconds, and
    /// when-in-use permission stops updates while the app is backgrounded — a turn that
    /// needs location shouldn't silently proceed without one when ~a second would get it.
    func awaitFix(timeout: TimeInterval = 1.5) async -> CLLocation? {
        if let currentLocation { return currentLocation }
        guard isAuthorized else { return nil }
        locationManager.startUpdatingLocation()
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            if let currentLocation { return currentLocation }
        }
        return nil
    }

    /// `awaitFix` + the human-readable context string (nil if no fix arrives in time).
    func awaitLocationContext(timeout: TimeInterval = 1.5) async -> String? {
        if let context = locationContext { return context }
        guard await awaitFix(timeout: timeout) != nil else { return nil }
        return locationContext
    }

    /// Returns a human-readable location string for LLM context
    var locationContext: String? {
        if let geocodedPlace { return geocodedPlace }
        guard let location = currentLocation else { return nil }
        return String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
    }

    /// Reverse geocode the current location to a human-readable place. A small on-device model
    /// can't map raw coordinates to a city, so the USER LOCATION prompt line needs a place name;
    /// coordinates remain the fallback while geocoding is pending or offline.
    private func reverseGeocode(_ location: CLLocation) {
        Task { @MainActor [weak self] in
            guard let place = await GeocodingHelper.reverseGeocode(location) else { return }
            self?.geocodedPlace = place.cityState ?? place.fullAddress
            PrivacyLog.location(.placeResolved)
        }
    }
}

// MARK: - RegionMonitoring (BK P1)

extension LocationService: RegionMonitoring {
    var regionAuthorizationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }
    var monitoredRegionCount: Int { locationManager.monitoredRegions.count }
    func regionMonitoringAvailable() -> Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }
    func requestAlwaysAuthorization() { locationManager.requestAlwaysAuthorization() }
    func startMonitoringRegion(_ region: CLCircularRegion) { locationManager.startMonitoring(for: region) }
    func stopMonitoringRegion(_ region: CLCircularRegion) { locationManager.stopMonitoring(for: region) }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = location
            self.reverseGeocode(location)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.isAuthorized = true
                manager.startUpdatingLocation()
                PrivacyLog.location(.authorized)
                // BK P1: geofences deferred while permission was pending can arm now.
                if status == .authorizedAlways { self.onBecameAuthorizedAlways?() }
            case .denied, .restricted:
                self.isAuthorized = false
                self.locationError = "Location access denied"
                PrivacyLog.location(.denied)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            PrivacyLog.location(.updateFailed, error: SafeErrorSummary(error))
            self.locationError = error.localizedDescription
        }
    }

    // MARK: Region monitoring (BK P1) — the callbacks that were missing, so a geofence can fire.

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in self.onRegionEvent?(region, true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.onRegionEvent?(region, false) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in
            PrivacyLog.location(.regionMonitoringFailed, error: SafeErrorSummary(error))
            self.locationError = "Region monitoring failed: \(error.localizedDescription)"
        }
    }
}
