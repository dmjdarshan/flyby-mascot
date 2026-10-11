import Foundation

public struct RouteAirport: Sendable, Equatable {
    public let name: String
    public let municipality: String?
    public let iataCode: String?
    public let icaoCode: String?

    public init(name: String, municipality: String?, iataCode: String?, icaoCode: String?) {
        self.name = name
        self.municipality = municipality
        self.iataCode = iataCode
        self.icaoCode = icaoCode
    }

    public var code: String? { iataCode ?? icaoCode }
}

public struct FlightRoute: Sendable, Equatable {
    public let callsign: String
    public let origin: RouteAirport
    public let destination: RouteAirport
    public let airline: String?

    public init(callsign: String, origin: RouteAirport, destination: RouteAirport, airline: String?) {
        self.callsign = callsign
        self.origin = origin
        self.destination = destination
        self.airline = airline
    }
}

public struct ADSBDBRouteProvider: Sendable {
    private let session: URLSession
    private let baseURL: URL?

    public init(session: URLSession = .shared, baseURL: URL? = URL(string: "https://api.adsbdb.com/v0/callsign")) {
        self.session = session
        self.baseURL = baseURL
    }

    public func route(for callsign: String) async throws -> FlightRoute? {
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 16,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else {
            throw AircraftProviderError.unavailable("This aircraft has no lookup-ready callsign.")
        }

        guard let baseURL else { throw AircraftProviderError.invalidResponse }
        let url = baseURL.appendingPathComponent(normalized)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AircraftProviderError.invalidResponse
        }
        switch response.statusCode {
        case 200: return try Self.parseResponse(data, expectedCallsign: normalized)
        case 404: return nil
        case 429: throw AircraftProviderError.rateLimited(retryAfter: nil)
        default: throw AircraftProviderError.unavailable("Route lookup returned HTTP \(response.statusCode).")
        }
    }

    public static func parseResponse(_ data: Data, expectedCallsign: String) throws -> FlightRoute? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let route = response["flightroute"] as? [String: Any],
              let callsign = cleaned(route["callsign"])
        else { throw AircraftProviderError.invalidResponse }
        guard callsign.caseInsensitiveCompare(expectedCallsign) == .orderedSame else { return nil }

        guard let origin = airport(route["origin"]),
              let destination = airport(route["destination"])
        else { return nil }
        let airline = (route["airline"] as? [String: Any]).flatMap { cleaned($0["name"]) }
        return FlightRoute(callsign: callsign, origin: origin, destination: destination, airline: airline)
    }

    private static func airport(_ value: Any?) -> RouteAirport? {
        guard let object = value as? [String: Any], let name = cleaned(object["name"]) else { return nil }
        return RouteAirport(
            name: name,
            municipality: cleaned(object["municipality"]),
            iataCode: cleaned(object["iata_code"]),
            icaoCode: cleaned(object["icao_code"])
        )
    }

    private static func cleaned(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
