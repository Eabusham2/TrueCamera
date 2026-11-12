import XCTest
import CoreLocation
@testable import TrueCamera

final class CaptureLocationTests: XCTestCase {
    private final class Manager: CaptureLocationManaging {
        var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
        weak var delegate: CLLocationManagerDelegate?
        var desiredAccuracy: CLLocationAccuracy = 0
        var authorizationRequests = 0
        var starts = 0
        var stops = 0
        var onAuthorizationRequest: (() -> Void)?

        func requestWhenInUseAuthorization() {
            authorizationRequests += 1
            onAuthorizationRequest?()
        }
        func startUpdatingLocation() { starts += 1 }
        func stopUpdatingLocation() { stops += 1 }
        func authorize(_ status: CLAuthorizationStatus) {
            authorizationStatus = status
            (delegate as? CaptureLocation)?.authorizationChanged()
        }
        func deliver(_ location: CLLocation) {
            (delegate as? CaptureLocation)?.acceptLocations([location])
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func fix(latitude: Double = 30.2, at date: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -97.7),
                   altitude: 140, horizontalAccuracy: 5, verticalAccuracy: 10, timestamp: date)
    }

    @MainActor func testAccurateFixKeepsTrackingAndRefreshesLongCameraSession() async throws {
        let manager = Manager()
        let capture = CaptureLocation(managerFactory: { manager })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        capture.request()
        await drainMainQueue()
        XCTAssertEqual(manager.starts, 1)

        manager.deliver(fix(at: start))
        XCTAssertNotNil(capture.current(now: start))
        XCTAssertEqual(manager.stops, 0, "An accurate first fix must not stop an active camera session.")

        // Six minutes later the original fix is expired, but the running manager
        // supplies the photographer's new position for the next capture.
        let later = start.addingTimeInterval(360)
        XCTAssertNil(capture.current(now: later))
        manager.deliver(fix(latitude: 30.3, at: later))
        XCTAssertEqual(try XCTUnwrap(capture.current(now: later)).coordinate.latitude, 30.3)
        XCTAssertEqual(manager.stops, 0)
        capture.stop()
        await drainMainQueue()
        XCTAssertEqual(manager.stops, 1)
    }

    @MainActor func testStopDropsCachedAndLateFixesAndResumeRequiresFreshFix() async throws {
        let manager = Manager()
        let capture = CaptureLocation(managerFactory: { manager })
        let now = Date()
        capture.request()
        await drainMainQueue()
        manager.deliver(fix(at: now))
        XCTAssertNotNil(capture.current(now: now))

        capture.stop()
        await drainMainQueue()
        XCTAssertNil(capture.current(now: now))
        manager.deliver(fix(latitude: 30.4, at: now))
        XCTAssertNil(capture.current(now: now), "A queued callback after stop must not repopulate the cache.")

        capture.request()
        await drainMainQueue()
        XCTAssertEqual(manager.starts, 2)
        XCTAssertNil(capture.current(now: now), "Re-enabling Location must not reuse the previous session's fix.")
        manager.deliver(fix(latitude: 30.5, at: now))
        XCTAssertEqual(try XCTUnwrap(capture.current(now: now)).coordinate.latitude, 30.5)
    }

    @MainActor func testPermissionReplyAfterStopDoesNotRestartTracking() async {
        let manager = Manager()
        manager.authorizationStatus = .notDetermined
        let capture = CaptureLocation(managerFactory: { manager })
        capture.request()
        await drainMainQueue()
        XCTAssertEqual(manager.authorizationRequests, 1)
        capture.stop()
        await drainMainQueue()

        manager.authorize(.authorizedWhenInUse)
        XCTAssertEqual(manager.starts, 0)
        manager.deliver(fix(at: Date()))
        XCTAssertNil(capture.current())
        capture.request()
        await drainMainQueue()
        XCTAssertEqual(manager.starts, 1)
    }

    @MainActor func testRevokedAuthorizationClearsFixAndRejectsFurtherDelivery() async {
        for denied in [CLAuthorizationStatus.denied, .restricted] {
            let manager = Manager()
            let capture = CaptureLocation(managerFactory: { manager })
            capture.request()
            await drainMainQueue()
            manager.deliver(fix(at: Date()))
            XCTAssertNotNil(capture.current())

            manager.authorize(denied)
            XCTAssertEqual(manager.stops, 1)
            XCTAssertNil(capture.current())
            manager.deliver(fix(at: Date()))
            XCTAssertNil(capture.current(), "A revoked permission must not leave GPS available to capture metadata.")
        }
    }

    @MainActor func testAuthorizationOnlyDoesNotStartLocationUpdates() async {
        let manager = Manager()
        manager.authorizationStatus = .notDetermined
        let requested = expectation(description: "Location permission requested")
        manager.onAuthorizationRequest = { requested.fulfill() }
        let capture = CaptureLocation(managerFactory: { manager })
        let authorization = Task { @MainActor in await capture.requestAuthorizationOnly() }
        await fulfillment(of: [requested], timeout: 2)
        manager.authorize(.authorizedWhenInUse)
        await authorization.value
        XCTAssertEqual(manager.authorizationRequests, 1)
        XCTAssertEqual(manager.starts, 0)
        XCTAssertNil(capture.current())
    }
}
