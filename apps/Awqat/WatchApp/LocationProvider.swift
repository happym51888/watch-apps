import Foundation
import CoreLocation
import Observation

/// One-shot location, with the last fix cached forever.
///
/// Prayer times move by roughly one minute per 20 km of longitude, so a fix
/// from yesterday — or from the last city you were in — is far better than no
/// times at all. The failure mode this avoids is the one users complain about
/// most: opening the app underground or in aeroplane mode and being shown a
/// spinner instead of a timetable.
///
/// `requestLocation` rather than continuous updates: the app needs a position
/// once per launch, not a stream, and continuous updates on a watch are a
/// battery complaint waiting to happen.
@MainActor
@Observable
final class LocationProvider: NSObject {

    enum Status: Equatable {
        case idle
        case locating
        case fixed(CLLocation)
        case denied
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var placeName: String?

    private let manager = CLLocationManager()
    private var onFix: ((CLLocation, String?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // Prayer times do not need metres. Coarser accuracy resolves faster and
        // costs far less power, and the error it introduces is well under the
        // one-minute rounding the timetable displays anyway.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestFix(_ completion: @escaping (CLLocation, String?) -> Void) {
        onFix = completion

        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            status = .denied
        default:
            status = .locating
            manager.requestLocation()
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        // Best-effort only. A missing place name changes nothing about the
        // times; it just means the header shows coordinates.
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self else { return }
                let name = placemarks?.first?.locality
                    ?? placemarks?.first?.administrativeArea
                    ?? placemarks?.first?.country
                self.placeName = name
                self.onFix?(location, name)
            }
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor in
            switch authorization {
            case .authorizedWhenInUse, .authorizedAlways:
                self.status = .locating
                // `self.manager`, not the callback's parameter. `CLLocationManager`
                // is not Sendable, so capturing the argument here would send it
                // across isolation; the stored property is already main-actor
                // isolated and is the same object.
                self.manager.requestLocation()
            case .denied, .restricted:
                self.status = .denied
            default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.status = .fixed(location)
            // Hand the caller the position immediately; the place name follows
            // if and when geocoding succeeds.
            self.onFix?(location, self.placeName)
            self.reverseGeocode(location)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let description = error.localizedDescription
        Task { @MainActor in self.status = .failed(description) }
    }
}
