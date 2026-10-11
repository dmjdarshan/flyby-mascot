import Foundation

public struct DemoAircraftProvider: AircraftProvider {
    public let name = "FlyBy Demo"
    public let attribution = "Synthetic data generated locally"

    public init() {}

    public func nearbyAircraft(
        center: Coordinate,
        radiusKilometers: Double
    ) async throws -> [AircraftObservation] {
        let longitudeOffset = max(0.01, min(radiusKilometers * 0.55 / 111, 0.25))
        return [
            AircraftObservation(
                id: "demo01",
                callsign: "FLYBY 01",
                category: "Demo airliner",
                coordinate: Coordinate(
                    latitude: center.latitude + 0.008,
                    longitude: center.longitude - longitudeOffset
                ),
                altitudeMeters: 3_200,
                groundSpeedMetersPerSecond: 215,
                trackDegrees: 82,
                observedAt: .now,
                source: name
            )
        ]
    }
}
