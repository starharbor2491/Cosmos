import CoreLocation
import CosmosEngine

/// Asks macOS where the Mac is, as Cosmos (so the question names Cosmos, and an answer survives Chromium updates), for a
/// site the user allowed to know. One position at a time; nil when macOS says no or has none within a few seconds.
@MainActor
final class LocationSource: NSObject, CLLocationManagerDelegate {
    static let shared = LocationSource()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<PageLocation?, Never>] = []
    /// Counts lookups, so a lookup's timeout does not end a later one.
    private var round = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> PageLocation? {
        await withCheckedContinuation { c in
            waiting.append(c)
            guard waiting.count == 1 else { return }
            round += 1
            let this = round
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(nil); return
            default: manager.requestLocation()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let self, self.round == this { self.finish(nil) }
            }
        }
    }

    private func finish(_ location: PageLocation?) {
        let done = waiting
        waiting = []
        done.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard !waiting.isEmpty, status != .notDetermined else { return }
            if status == .denied || status == .restricted { finish(nil) } else { manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let found = PageLocation(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, accuracy: l.horizontalAccuracy)
        MainActor.assumeIsolated { finish(found) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
