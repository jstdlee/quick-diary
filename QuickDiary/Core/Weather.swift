import CoreLocation
import Foundation

/// Current weather from Open-Meteo (free, no key). Only a rounded location (~1 km) is sent,
/// and only when the user taps Weather.
enum Weather {
    struct Now {
        var temperature: Double
        var code: Int
        var place: String?

        var line: String {
            let (emoji, text) = Weather.describe(code)
            let temp = "\(Int(temperature.rounded()))°C"
            return "- \(emoji) Weather: \(temp) · \(text)" + (place.map { " · \($0)" } ?? "")
        }
    }

    /// Demo and UI tests: no location, no network.
    static let demo = Now(temperature: 18, code: 2, place: "Demo City")

    /// Main actor: CLLocationManager needs a thread with a run loop.
    @MainActor
    static func current() async throws -> Now {
        let fetcher = LocationFetcher()
        let location = try await fetcher.fetch()
        withExtendedLifetime(fetcher) {}
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
            }
            let current: Current
        }
        let current = try JSONDecoder().decode(Response.self, from: data).current
        let place = try? await CLGeocoder().reverseGeocodeLocation(location).first?.locality
        return Now(temperature: current.temperature_2m, code: current.weather_code, place: place)
    }

    /// WMO weather codes.
    static func describe(_ code: Int) -> (String, String) {
        switch code {
        case 0: ("☀️", "Clear")
        case 1, 2: ("⛅", "Partly cloudy")
        case 3: ("☁️", "Cloudy")
        case 45, 48: ("🌫️", "Fog")
        case 51...57: ("🌦️", "Drizzle")
        case 61...67, 80...82: ("🌧️", "Rain")
        case 71...77, 85, 86: ("🌨️", "Snow")
        case 95...99: ("⛈️", "Thunderstorm")
        default: ("🌡️", "Weather")
        }
    }
}

/// One location fix, asking for permission the first time.
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    struct Denied: LocalizedError {
        var errorDescription: String? {
            String(localized: "Location is off for Quick Diary. Turn it on in the Settings app to add the weather.")
        }
    }

    @MainActor
    func fetch() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(Denied()))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: finish(.failure(Denied()))
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { finish(.success(location)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}
