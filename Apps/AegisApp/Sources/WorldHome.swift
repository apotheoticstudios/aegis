import CoreLocation
import Foundation

/// Home for the World view (#265): where the Mac was when the owner said "set my home here", kept only in Aegis's
/// private folder. The exact point is used only on the local globe; anything sent out is rounded to about 10 km.
enum WorldHome {
    struct Point: Codable {
        let latitude: Double
        let longitude: Double
    }

    private static var file: URL {
        WorldSidecar.folder.deletingLastPathComponent().appendingPathComponent("home.json")
    }

    static var point: Point? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Point.self, from: data)
    }

    static func save(_ point: Point) -> Bool {
        guard let data = try? JSONEncoder().encode(point) else { return false }
        try? FileManager.default.removeItem(at: file)
        return FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

/// One reading of the Mac's location, when the owner asks (#265). macOS asks the owner the first time.
@MainActor
final class HomeLocator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    /// The Mac's location, or nil when it isn't allowed or can't be found within 20 seconds.
    func locate() async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            return nil
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.finish(nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            if waiting != nil {
                manager.requestLocation()
            }
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_: CLLocationManager, didFailWithError _: any Error) {
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }
}
