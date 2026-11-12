import Foundation
import CoreLocation
import ImageIO

/// The system manager is replaceable in tests so permission changes and a long
/// camera session can be exercised without displaying a location prompt.
protocol CaptureLocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var delegate: CLLocationManagerDelegate? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}
extension CLLocationManager: CaptureLocationManaging {}

final class CaptureLocation: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = CaptureLocation()
    private let lock = NSLock()
    private var lastLocation: CLLocation?
    // Manager and session state are used only on the main queue. The cached fix
    // is separately locked because camera metadata is assembled off that queue.
    private var authorizationContinuations: [CheckedContinuation<Void,Never>] = []
    private var updatesRequested = false
    private let managerFactory: () -> CaptureLocationManaging
    private lazy var manager: CaptureLocationManaging = {
        let manager = managerFactory()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        return manager
    }()

    init(managerFactory: @escaping () -> CaptureLocationManaging = { CLLocationManager() }) {
        self.managerFactory = managerFactory
        super.init()
    }

    func requestAuthorizationOnly() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else { continuation.resume(); return }
                guard self.manager.authorizationStatus == .notDetermined else { continuation.resume(); return }
                let firstRequest = self.authorizationContinuations.isEmpty
                self.authorizationContinuations.append(continuation)
                if firstRequest { self.manager.requestWhenInUseAuthorization() }
            }
        }
    }

    func request() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.updatesRequested { self.clearCachedLocation() }
            self.updatesRequested = true
            switch self.manager.authorizationStatus {
            case .notDetermined:
                self.manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.startUpdatingLocation()
            default:
                self.manager.stopUpdatingLocation()
                self.clearCachedLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged()
    }

    func authorizationChanged() {
        let status = manager.authorizationStatus
        if status != .notDetermined {
            let continuations = authorizationContinuations
            authorizationContinuations.removeAll()
            for continuation in continuations { continuation.resume() }
        }
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            // A permission dialog may finish after the camera was suspended or
            // Location was disabled. Authorization alone must not restart it.
            if updatesRequested { manager.startUpdatingLocation() }
        } else {
            manager.stopUpdatingLocation()
            clearCachedLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        acceptLocations(locations)
    }

    func acceptLocations(_ locations: [CLLocation]) {
        let status = manager.authorizationStatus
        guard updatesRequested, status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        guard let value = locations.last, value.horizontalAccuracy >= 0 else { return }
        lock.lock(); lastLocation = value; lock.unlock()
        // Keep updates active for the requested foreground camera session. A
        // one-shot fix becomes stale as the photographer moves or keeps shooting.
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatesRequested = false
            self.manager.stopUpdatingLocation()
            self.clearCachedLocation()
        }
    }

    private func clearCachedLocation() {
        lock.lock(); lastLocation = nil; lock.unlock()
    }

    func current(maxAge: TimeInterval = 300, now: Date = Date()) -> CLLocation? {
        lock.lock(); defer { lock.unlock() }
        guard let value = lastLocation, abs(value.timestamp.timeIntervalSince(now)) <= maxAge else { return nil }
        return value
    }

    static func iso6709(_ location: CLLocation) -> String {
        String(format: "%+.6f%+.6f%+.1f/", location.coordinate.latitude, location.coordinate.longitude, location.altitude)
    }

    static func gpsDictionary(_ location: CLLocation) -> [String: Any] {
        let latitude = location.coordinate.latitude, longitude = location.coordinate.longitude
        return [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude as String: abs(location.altitude),
            kCGImagePropertyGPSAltitudeRef as String: location.altitude >= 0 ? 0 : 1,
            kCGImagePropertyGPSHPositioningError as String: max(0, location.horizontalAccuracy)
        ]
    }
}
