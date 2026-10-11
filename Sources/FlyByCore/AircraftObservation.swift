import Foundation

public struct Coordinate: Sendable, Equatable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct AircraftObservation: Identifiable, Sendable, Equatable {
    public let id: String
    public let callsign: String?
    public let category: String?
    public let originCountry: String?
    public let coordinate: Coordinate
    public let altitudeMeters: Double?
    public let barometricAltitudeMeters: Double?
    public let geometricAltitudeMeters: Double?
    public let groundSpeedMetersPerSecond: Double?
    public let trackDegrees: Double?
    public let verticalRateMetersPerSecond: Double?
    public let squawk: String?
    public let specialPurposeIndicator: Bool?
    public let positionSource: String?
    public let isOnGround: Bool
    public let observedAt: Date
    public let lastContactAt: Date?
    public let source: String

    public init(
        id: String,
        callsign: String? = nil,
        category: String? = nil,
        originCountry: String? = nil,
        coordinate: Coordinate,
        altitudeMeters: Double? = nil,
        barometricAltitudeMeters: Double? = nil,
        geometricAltitudeMeters: Double? = nil,
        groundSpeedMetersPerSecond: Double? = nil,
        trackDegrees: Double? = nil,
        verticalRateMetersPerSecond: Double? = nil,
        squawk: String? = nil,
        specialPurposeIndicator: Bool? = nil,
        positionSource: String? = nil,
        isOnGround: Bool = false,
        observedAt: Date,
        lastContactAt: Date? = nil,
        source: String
    ) {
        self.id = id
        self.callsign = callsign?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.category = category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.originCountry = originCountry?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.coordinate = coordinate
        self.altitudeMeters = altitudeMeters
        self.barometricAltitudeMeters = barometricAltitudeMeters
        self.geometricAltitudeMeters = geometricAltitudeMeters
        self.groundSpeedMetersPerSecond = groundSpeedMetersPerSecond
        self.trackDegrees = trackDegrees.map { $0.normalizedHeading }
        self.verticalRateMetersPerSecond = verticalRateMetersPerSecond
        self.squawk = squawk?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.specialPurposeIndicator = specialPurposeIndicator
        self.positionSource = positionSource
        self.isOnGround = isOnGround
        self.observedAt = observedAt
        self.lastContactAt = lastContactAt
        self.source = source
    }

    public var displayName: String { callsign ?? id.uppercased() }
}

public protocol AircraftProvider: Sendable {
    var name: String { get }
    var attribution: String { get }

    func nearbyAircraft(
        center: Coordinate,
        radiusKilometers: Double
    ) async throws -> [AircraftObservation]
}

public enum AircraftProviderError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case rateLimited(retryAfter: Duration?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .rateLimited: "The aircraft provider is rate limiting requests."
        case .invalidResponse: "The aircraft provider returned an invalid response."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Double {
    var normalizedHeading: Double {
        let value = truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }
}
