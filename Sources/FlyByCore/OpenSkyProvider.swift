import Foundation

public struct OpenSkyCredentials: Sendable, Codable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct OpenSkyUsage: Sendable, Equatable {
    public let remainingCredits: Int?
    public let isAuthenticated: Bool

    public init(remainingCredits: Int?, isAuthenticated: Bool) {
        self.remainingCredits = remainingCredits
        self.isAuthenticated = isAuthenticated
    }
}

public struct OpenSkyFetchResult: Sendable, Equatable {
    public let observations: [AircraftObservation]
    public let usage: OpenSkyUsage

    public init(observations: [AircraftObservation], usage: OpenSkyUsage) {
        self.observations = observations
        self.usage = usage
    }
}

public struct OpenSkyProvider: AircraftProvider {
    public let name = "OpenSky Network"
    public let attribution = "OpenSky Network — live data for research and non-commercial use"

    private let session: URLSession
    private let endpoint: URL?
    private let tokenManager: OpenSkyTokenManager?

    public init(
        session: URLSession = .shared,
        endpoint: URL? = URL(string: "https://opensky-network.org/api/states/all"),
        credentials: OpenSkyCredentials? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        tokenManager = credentials.map(OpenSkyTokenManager.init)
    }

    public func nearbyAircraft(
        center: Coordinate,
        radiusKilometers: Double
    ) async throws -> [AircraftObservation] {
        try await fetchNearbyAircraft(
            center: center,
            radiusKilometers: radiusKilometers
        ).observations
    }

    public func fetchNearbyAircraft(
        center: Coordinate,
        radiusKilometers: Double
    ) async throws -> OpenSkyFetchResult {
        let url = try requestURL(center: center, radiusKilometers: radiusKilometers)
        var request = URLRequest(url: url)
        if let tokenManager {
            let token = try await tokenManager.accessToken(using: session)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AircraftProviderError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return OpenSkyFetchResult(
                observations: try Self.parseResponse(data, source: attribution),
                usage: OpenSkyUsage(
                    remainingCredits: httpResponse.value(forHTTPHeaderField: "X-Rate-Limit-Remaining")
                        .flatMap(Int.init),
                    isAuthenticated: tokenManager != nil
                )
            )
        case 401, 403:
            await tokenManager?.invalidate()
            throw AircraftProviderError.unavailable(
                tokenManager == nil
                    ? "OpenSky rejected anonymous access from this network."
                    : "OpenSky rejected these API client credentials. Check the client ID and secret."
            )
        case 429:
            let seconds = httpResponse.value(forHTTPHeaderField: "X-Rate-Limit-Retry-After-Seconds")
                .flatMap(Int.init)
            throw AircraftProviderError.rateLimited(
                retryAfter: seconds.map { .seconds($0) }
            )
        default:
            throw AircraftProviderError.unavailable(
                "OpenSky returned HTTP \(httpResponse.statusCode)."
            )
        }
    }

    public func requestURL(
        center: Coordinate,
        radiusKilometers: Double
    ) throws -> URL {
        guard (-90...90).contains(center.latitude),
              (-180...180).contains(center.longitude)
        else {
            throw AircraftProviderError.unavailable(
                "Enter a valid latitude from −90 to 90 and longitude from −180 to 180."
            )
        }
        let radius = max(0.1, radiusKilometers)
        let latitudeDelta = radius / 111.32
        let longitudeScale = max(0.01, cos(center.latitude * .pi / 180))
        let longitudeDelta = radius / (111.32 * longitudeScale)

        guard let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            throw AircraftProviderError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "lamin", value: String(max(-90, center.latitude - latitudeDelta))),
            URLQueryItem(name: "lomin", value: String(max(-180, center.longitude - longitudeDelta))),
            URLQueryItem(name: "lamax", value: String(min(90, center.latitude + latitudeDelta))),
            URLQueryItem(name: "lomax", value: String(min(180, center.longitude + longitudeDelta))),
            URLQueryItem(name: "extended", value: "1"),
        ]
        guard let url = components.url else {
            throw AircraftProviderError.invalidResponse
        }
        return url
    }

    public static func parseResponse(
        _ data: Data,
        source: String = "OpenSky Network"
    ) throws -> [AircraftObservation] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AircraftProviderError.invalidResponse
        }

        let responseTime = (object["time"] as? NSNumber)?.doubleValue
        guard let rows = object["states"] as? [[Any]] else {
            if object["states"] is NSNull || object["states"] == nil { return [] }
            throw AircraftProviderError.invalidResponse
        }

        return rows.compactMap { row in
            guard let id = string(in: row, at: 0),
                  let longitude = number(in: row, at: 5),
                  let latitude = number(in: row, at: 6),
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude)
            else { return nil }

            let timestamp = number(in: row, at: 3)
                ?? number(in: row, at: 4)
                ?? responseTime
            guard let timestamp else { return nil }

            return AircraftObservation(
                id: id.lowercased(),
                callsign: string(in: row, at: 1),
                category: number(in: row, at: 17).map { categoryName(Int($0)) },
                originCountry: string(in: row, at: 2),
                coordinate: Coordinate(latitude: latitude, longitude: longitude),
                altitudeMeters: number(in: row, at: 7) ?? number(in: row, at: 13),
                barometricAltitudeMeters: number(in: row, at: 7),
                geometricAltitudeMeters: number(in: row, at: 13),
                groundSpeedMetersPerSecond: number(in: row, at: 9),
                trackDegrees: number(in: row, at: 10),
                verticalRateMetersPerSecond: number(in: row, at: 11),
                squawk: string(in: row, at: 14),
                specialPurposeIndicator: bool(in: row, at: 15),
                positionSource: number(in: row, at: 16).map { positionSourceName(Int($0)) },
                isOnGround: bool(in: row, at: 8) ?? false,
                observedAt: Date(timeIntervalSince1970: timestamp),
                lastContactAt: number(in: row, at: 4).map(Date.init(timeIntervalSince1970:)),
                source: source
            )
        }
    }

    private static func string(in row: [Any], at index: Int) -> String? {
        guard row.indices.contains(index), !(row[index] is NSNull) else { return nil }
        return row[index] as? String
    }

    private static func number(in row: [Any], at index: Int) -> Double? {
        guard row.indices.contains(index), !(row[index] is NSNull) else { return nil }
        return (row[index] as? NSNumber)?.doubleValue
    }

    private static func bool(in row: [Any], at index: Int) -> Bool? {
        guard row.indices.contains(index), !(row[index] is NSNull) else { return nil }
        return row[index] as? Bool
    }

    private static func categoryName(_ category: Int) -> String {
        switch category {
        case 2: "Light aircraft"
        case 3: "Small aircraft"
        case 4: "Large aircraft"
        case 5: "High-vortex aircraft"
        case 6: "Heavy aircraft"
        case 7: "High-performance aircraft"
        case 8: "Rotorcraft"
        case 9: "Glider"
        case 10: "Lighter-than-air"
        case 11: "Parachutist"
        case 12: "Ultralight"
        case 14: "Unmanned aircraft"
        case 15: "Space vehicle"
        case 16, 17: "Surface vehicle"
        default: "Aircraft"
        }
    }

    private static func positionSourceName(_ source: Int) -> String {
        switch source {
        case 0: "ADS-B"
        case 1: "ASTERIX"
        case 2: "MLAT"
        case 3: "FLARM"
        default: "Unknown (\(source))"
        }
    }
}

private actor OpenSkyTokenManager {
    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private let credentials: OpenSkyCredentials
    private var cachedToken: String?
    private var expiresAt = Date.distantPast

    init(credentials: OpenSkyCredentials) {
        self.credentials = credentials
    }

    func accessToken(using session: URLSession, now: Date = .now) async throws -> String {
        if let cachedToken, now < expiresAt {
            return cachedToken
        }
        guard let url = URL(string: "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token") else {
            throw AircraftProviderError.invalidResponse
        }

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
        ]
        guard let body = form.percentEncodedQuery.map({ Data($0.utf8) }) else {
            throw AircraftProviderError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw AircraftProviderError.unavailable(
                "OpenSky could not authenticate this API client."
            )
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = token.accessToken
        expiresAt = now.addingTimeInterval(max(60, token.expiresIn - 60))
        return token.accessToken
    }

    func invalidate() {
        cachedToken = nil
        expiresAt = .distantPast
    }
}
