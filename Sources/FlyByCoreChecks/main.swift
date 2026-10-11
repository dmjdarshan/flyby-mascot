import FlyByCore
import Foundation

@main
struct FlyByCoreChecks {
    static func main() async throws {
        let engine = ProximityEngine()
        let center = Coordinate(latitude: 0, longitude: 0)
        let now = Date(timeIntervalSince1970: 1_000)
        let distance = engine.distanceKilometers(
            from: center,
            to: Coordinate(latitude: 0, longitude: 1)
        )
        precondition(abs(distance - 111.195) < 0.01, "Great-circle distance check failed")

        let approaching = AircraftObservation(
            id: "check01",
            callsign: "CHECK 1",
            coordinate: Coordinate(latitude: 0, longitude: -0.12),
            altitudeMeters: 2_000,
            groundSpeedMetersPerSecond: 250,
            trackDegrees: 90,
            observedAt: now,
            source: "Check"
        )
        let candidate = engine.candidate(
            for: approaching,
            around: center,
            configuration: ProximityConfiguration(
                radiusKilometers: 5,
                predictionHorizon: 120
            ),
            now: now
        )
        precondition(candidate != nil, "Predicted closest-pass check failed")
        precondition(
            candidate!.predictedClosestApproachKilometers < 0.1,
            "Closest-approach distance check failed"
        )

        let tracker = EligibilityTracker()
        let configuration = ProximityConfiguration(radiusKilometers: 20, cooldown: 60)
        let first = await tracker.nextEligible(
            observations: [approaching],
            around: center,
            configuration: configuration,
            now: now
        )
        let duplicate = await tracker.nextEligible(
            observations: [approaching],
            around: center,
            configuration: configuration,
            now: now.addingTimeInterval(1)
        )
        precondition(first != nil && duplicate == nil, "Entry deduplication check failed")

        let paused = PresentationState(manualPauseUntil: now.addingTimeInterval(60))
        precondition(
            paused.overlayDecision(now: now) == .suppress(.manualPause),
            "Presentation guard check failed"
        )

        let fixture = """
        {"time": 1700000000, "states": [
          ["abc123", " TEST42 ", "India", 1699999995, 1699999998,
           77.60, 12.98, 3200.0, false, 210.0, 82.0, 0.0, null,
           3300.0, "1234", false, 0, 4],
          ["missing", null, "India", 1699999995, 1699999998,
           null, null, null, false, null, null, null, null,
           null, null, false, 0, 0]
        ]}
        """
        let decoded = try OpenSkyProvider.parseResponse(Data(fixture.utf8))
        precondition(decoded.count == 1, "OpenSky partial-row filtering check failed")
        precondition(decoded[0].callsign == "TEST42", "OpenSky callsign normalization check failed")
        precondition(decoded[0].category == "Large aircraft", "OpenSky category mapping check failed")
        precondition(decoded[0].originCountry == "India", "OpenSky origin-country mapping check failed")
        precondition(decoded[0].barometricAltitudeMeters == 3200, "OpenSky barometric-altitude mapping check failed")
        precondition(decoded[0].geometricAltitudeMeters == 3300, "OpenSky geometric-altitude mapping check failed")
        precondition(decoded[0].squawk == "1234", "OpenSky squawk mapping check failed")
        precondition(decoded[0].positionSource == "ADS-B", "OpenSky position-source mapping check failed")
        precondition(
            PollingCadence.fiveMinutes.maximumDailyRequests == 288,
            "Polling credit estimate check failed"
        )

        let routeFixture = """
        {"response":{"flightroute":{"callsign":"IGO123",
          "origin":{"name":"Bengaluru Airport","iata_code":"BLR"},
          "destination":{"name":"Mumbai Airport","iata_code":"BOM"}}}}
        """
        let route = try ADSBDBRouteProvider.parseResponse(Data(routeFixture.utf8), expectedCallsign: "IGO123")
        precondition(route?.origin.code == "BLR" && route?.destination.code == "BOM", "Route mapping check failed")

        do {
            _ = try OpenSkyProvider().requestURL(
                center: Coordinate(latitude: 100, longitude: 77),
                radiusKilometers: 10
            )
            preconditionFailure("OpenSky coordinate validation check failed")
        } catch AircraftProviderError.unavailable {
            // Expected: an invalid location must never become a provider query.
        }

        print("FlyByCore checks passed")
    }
}
