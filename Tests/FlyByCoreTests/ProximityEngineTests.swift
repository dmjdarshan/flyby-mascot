import Foundation
import XCTest
@testable import FlyByCore

final class ProximityEngineTests: XCTestCase {
    private let center = Coordinate(latitude: 0, longitude: 0)
    private let now = Date(timeIntervalSince1970: 1_000)

    func testGreatCircleDistanceAtTheEquator() {
        let result = ProximityEngine().distanceKilometers(
            from: center,
            to: Coordinate(latitude: 0, longitude: 1)
        )
        XCTAssertEqual(result, 111.195, accuracy: 0.01)
    }

    func testApproachingAircraftQualifiesByPredictedClosestPass() {
        let observation = makeObservation(
            longitude: -0.12,
            speed: 250,
            track: 90
        )
        let configuration = ProximityConfiguration(
            radiusKilometers: 5,
            predictionHorizon: 120
        )
        let candidate = ProximityEngine().candidate(
            for: observation,
            around: center,
            configuration: configuration,
            now: now
        )

        XCTAssertNotNil(candidate)
        XCTAssertGreaterThan(candidate?.distanceKilometers ?? 0, 10)
        XCTAssertLessThan(candidate?.predictedClosestApproachKilometers ?? 100, 0.1)
    }

    func testStaleAndOnGroundObservationsAreRejected() {
        let configuration = ProximityConfiguration(maximumObservationAge: 30)
        let stale = makeObservation(observedAt: now.addingTimeInterval(-31))
        let grounded = makeObservation(isOnGround: true)
        let engine = ProximityEngine()

        XCTAssertNil(engine.candidate(for: stale, around: center, configuration: configuration, now: now))
        XCTAssertNil(engine.candidate(for: grounded, around: center, configuration: configuration, now: now))
    }

    func testEligibilityTriggersOnceAndHonorsCooldown() async {
        let tracker = EligibilityTracker()
        let observation = makeObservation()
        let configuration = ProximityConfiguration(radiusKilometers: 10, cooldown: 60)

        let first = await tracker.nextEligible(
            observations: [observation],
            around: center,
            configuration: configuration,
            now: now
        )
        let repeated = await tracker.nextEligible(
            observations: [observation],
            around: center,
            configuration: configuration,
            now: now.addingTimeInterval(5)
        )
        _ = await tracker.nextEligible(
            observations: [],
            around: center,
            configuration: configuration,
            now: now.addingTimeInterval(10)
        )
        let beforeCooldown = await tracker.nextEligible(
            observations: [observation],
            around: center,
            configuration: configuration,
            now: now.addingTimeInterval(30)
        )

        XCTAssertNotNil(first)
        XCTAssertNil(repeated)
        XCTAssertNil(beforeCooldown)
    }

    func testPresentationGuardAppliesManualAndStrictSuppression() {
        let paused = PresentationState(manualPauseUntil: now.addingTimeInterval(60))
        XCTAssertEqual(paused.overlayDecision(now: now), .suppress(.manualPause))

        let strict = PresentationState(
            strictAppDetected: true,
            safetyMode: .strict
        )
        XCTAssertEqual(strict.overlayDecision(now: now), .suppress(.strictAppRunning))

        let balanced = PresentationState(
            strictAppDetected: true,
            safetyMode: .balanced
        )
        XCTAssertEqual(balanced.overlayDecision(now: now), .allow)
    }

    func testOpenSkyResponseNormalizesAndSkipsRowsWithoutPosition() throws {
        let fixture = """
        {"time": 1700000000, "states": [
          ["abc123", " TEST42 ", "India", 1699999995, 1699999998,
           77.60, 12.98, 3200.0, false, 210.0, 82.0, 0.0, null,
           3300.0, "1234", false, 0, 8],
          ["missing", null, "India", 1699999995, 1699999998,
           null, null, null, false, null, null, null, null,
           null, null, false, 0, 0]
        ]}
        """

        let observations = try OpenSkyProvider.parseResponse(Data(fixture.utf8))

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].id, "abc123")
        XCTAssertEqual(observations[0].callsign, "TEST42")
        XCTAssertEqual(observations[0].category, "Rotorcraft")
        XCTAssertEqual(observations[0].trackDegrees, 82)
        XCTAssertEqual(observations[0].originCountry, "India")
        XCTAssertEqual(observations[0].barometricAltitudeMeters, 3200)
        XCTAssertEqual(observations[0].geometricAltitudeMeters, 3300)
        XCTAssertEqual(observations[0].squawk, "1234")
        XCTAssertEqual(observations[0].specialPurposeIndicator, false)
        XCTAssertEqual(observations[0].positionSource, "ADS-B")
        XCTAssertEqual(observations[0].lastContactAt, Date(timeIntervalSince1970: 1699999998))
    }

    func testOpenSkyPartialDetailsRemainUnknown() throws {
        let fixture = """
        {"time": 1700000000, "states": [
          ["abc123", null, null, 1699999995, 1699999998,
           77.60, 12.98, null, false, null, null, null, null,
           null, null, null, null, null]
        ]}
        """
        let observation = try XCTUnwrap(OpenSkyProvider.parseResponse(Data(fixture.utf8)).first)
        XCTAssertNil(observation.callsign)
        XCTAssertNil(observation.originCountry)
        XCTAssertNil(observation.barometricAltitudeMeters)
        XCTAssertNil(observation.geometricAltitudeMeters)
        XCTAssertNil(observation.squawk)
        XCTAssertNil(observation.positionSource)
    }

    func testOpenSkyRejectsInvalidCoordinatesBeforeNetworking() {
        XCTAssertThrowsError(
            try OpenSkyProvider().requestURL(
                center: Coordinate(latitude: 100, longitude: 77),
                radiusKilometers: 10
            )
        )
    }

    func testPollingCadenceExposesDailyRequestCeiling() {
        XCTAssertEqual(PollingCadence.fiveMinutes.maximumDailyRequests, 288)
        XCTAssertEqual(PollingCadence.tenMinutes.maximumDailyRequests, 144)
        XCTAssertEqual(PollingCadence.fifteenMinutes.maximumDailyRequests, 96)
    }

    func testADSBDBRouteNormalizesAirportsAndAirline() throws {
        let fixture = """
        {"response":{"flightroute":{"callsign":"IGO123","airline":{"name":"IndiGo"},
          "origin":{"name":"Kempegowda International Airport","municipality":"Bengaluru","iata_code":"BLR","icao_code":"VOBL"},
          "destination":{"name":"Chhatrapati Shivaji Maharaj International Airport","municipality":"Mumbai","iata_code":"BOM","icao_code":"VABB"}}}}
        """
        let route = try XCTUnwrap(ADSBDBRouteProvider.parseResponse(Data(fixture.utf8), expectedCallsign: "igo123"))
        XCTAssertEqual(route.origin.code, "BLR")
        XCTAssertEqual(route.destination.code, "BOM")
        XCTAssertEqual(route.airline, "IndiGo")
    }

    func testADSBDBRouteDoesNotInventPartialOrMismatchedRoute() throws {
        let partial = """
        {"response":{"flightroute":{"callsign":"IGO123","origin":{"name":"Bengaluru"}}}}
        """
        XCTAssertNil(try ADSBDBRouteProvider.parseResponse(Data(partial.utf8), expectedCallsign: "IGO123"))
        XCTAssertNil(try ADSBDBRouteProvider.parseResponse(Data(partial.utf8), expectedCallsign: "OTHER"))
    }

    private func makeObservation(
        longitude: Double = 0.02,
        speed: Double? = 200,
        track: Double? = 90,
        isOnGround: Bool = false,
        observedAt: Date? = nil
    ) -> AircraftObservation {
        AircraftObservation(
            id: "abc123",
            callsign: " TEST 1 ",
            coordinate: Coordinate(latitude: 0, longitude: longitude),
            altitudeMeters: 2_000,
            groundSpeedMetersPerSecond: speed,
            trackDegrees: track,
            isOnGround: isOnGround,
            observedAt: observedAt ?? now,
            source: "Test"
        )
    }
}
