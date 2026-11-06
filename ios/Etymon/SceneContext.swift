import CoreLocation
import MapKit
import Vision

/// Where the phone is, once, for a scene being saved: coordinates and a readable place.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    struct Place {
        let coordinate: CLLocationCoordinate2D
        let name: String?
    }

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    /// The current place, or nil if location is off, denied, or takes too long.
    func current(timeout: Duration = .seconds(10)) async -> Place? {
        guard CLLocationManager.locationServicesEnabled(), !isDenied else { return nil }
        let location = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { await self.locate() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            self.finish(nil)  // a timed-out request isn't left waiting
            return first
        }
        guard let location else { return nil }
        return Place(coordinate: location.coordinate, name: await Self.name(of: location))
    }

    private func locate() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()  // locationManagerDidChangeAuthorization goes on
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        let done = waiting
        waiting = []
        done.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard !waiting.isEmpty else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .notDetermined: break
            default: finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { finish(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    /// "Carrer de Verdi, Barcelona": street (or place) and town, else town and country.
    static func name(of location: CLLocation) async -> String? {
        if #available(iOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            let street = item.address?.shortAddress?.split(separator: ",").first.map(String.init)
            let town = item.addressRepresentations?.cityWithContext
            return [street, town].compactMap { $0 }.filter { !$0.isEmpty }.uniqued()
                .joined(separator: ", ").nilIfEmpty ?? item.name
        } else {
            guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            else { return nil }
            let street = mark.thoroughfare ?? mark.name
            return [street, mark.locality ?? mark.country].compactMap { $0 }.uniqued()
                .joined(separator: ", ").nilIfEmpty
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What the words were on, guessed from the picture: a few plain names, most likely
/// first ("sign", "menu", "book"), for the user to pick from or change.
enum ObjectGuess {
    /// Labels that say nothing about the object.
    static let vague: Set<String> = ["text", "document", "structure", "material", "indoor",
                                     "outdoor", "printed_page", "paper", "wood_processed",
                                     "liquid", "cloth", "textile", "art", "ink", "handwriting"]

    static func guesses(for image: CGImage, limit: Int = 4) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return [] }
        let labels = (request.results ?? [])
            .filter { $0.confidence > 0.15 }
            .sorted { $0.confidence > $1.confidence }
            .map(\.identifier)
        var out = labels.filter { !vague.contains($0) }.prefix(limit).map(readable)
        if out.isEmpty, let first = labels.first { out = [readable(first)] }
        return Array(out)
    }

    static func readable(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}
