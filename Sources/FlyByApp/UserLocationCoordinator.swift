import AppKit
import CoreLocation
import FlyByCore
import Foundation

@MainActor
final class UserLocationCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((Result<Coordinate, Error>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refresh(completion: @escaping (Result<Coordinate, Error>) -> Void) {
        guard self.completion == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil
        else {
            completion(.failure(LocationRequestError.missingUsageDescription))
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            completion(.failure(LocationRequestError.servicesDisabled))
            return
        }

        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            NSApplication.shared.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationRequestError.permissionDenied))
        @unknown default:
            finish(.failure(LocationRequestError.permissionDenied))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationRequestError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(LocationRequestError.permissionDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else {
            finish(.failure(LocationRequestError.noLocation))
            return
        }
        finish(.success(Coordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Coordinate, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
}

private enum LocationRequestError: LocalizedError {
    case missingUsageDescription
    case servicesDisabled
    case permissionDenied
    case noLocation

    var errorDescription: String? {
        switch self {
        case .missingUsageDescription:
            "Location access needs the bundled FlyBy app. Launch it with sh .codex/run-app.sh."
        case .servicesDisabled:
            "Location Services are off in macOS System Settings. You can still enter coordinates manually."
        case .permissionDenied:
            "FlyBy does not have location permission. Enable it in Privacy & Security → Location Services, or enter coordinates manually."
        case .noLocation:
            "macOS could not determine a current location. Try again or enter coordinates manually."
        }
    }
}
