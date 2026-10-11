import Foundation

public struct ProximityConfiguration: Sendable, Equatable {
    public var radiusKilometers: Double
    public var maximumObservationAge: TimeInterval
    public var cooldown: TimeInterval
    public var predictionHorizon: TimeInterval
    public var minimumAltitudeMeters: Double?

    public init(
        radiusKilometers: Double = 10,
        maximumObservationAge: TimeInterval = 90,
        cooldown: TimeInterval = 30 * 60,
        predictionHorizon: TimeInterval = 5 * 60,
        minimumAltitudeMeters: Double? = nil
    ) {
        self.radiusKilometers = max(0.1, radiusKilometers)
        self.maximumObservationAge = max(1, maximumObservationAge)
        self.cooldown = max(0, cooldown)
        self.predictionHorizon = max(0, predictionHorizon)
        self.minimumAltitudeMeters = minimumAltitudeMeters
    }
}

public struct AircraftCandidate: Sendable, Equatable {
    public let observation: AircraftObservation
    public let distanceKilometers: Double
    public let predictedClosestApproachKilometers: Double
    public let secondsUntilClosestApproach: TimeInterval

    public init(
        observation: AircraftObservation,
        distanceKilometers: Double,
        predictedClosestApproachKilometers: Double,
        secondsUntilClosestApproach: TimeInterval
    ) {
        self.observation = observation
        self.distanceKilometers = distanceKilometers
        self.predictedClosestApproachKilometers = predictedClosestApproachKilometers
        self.secondsUntilClosestApproach = secondsUntilClosestApproach
    }
}

public struct ProximityEngine: Sendable {
    private static let earthRadiusKilometers = 6_371.0088

    public init() {}

    public func distanceKilometers(from: Coordinate, to: Coordinate) -> Double {
        let latitude1 = from.latitude.radians
        let latitude2 = to.latitude.radians
        let latitudeDelta = (to.latitude - from.latitude).radians
        let longitudeDelta = (to.longitude - from.longitude).radians

        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        let angularDistance = 2 * atan2(sqrt(a), sqrt(1 - a))
        return Self.earthRadiusKilometers * angularDistance
    }

    public func candidate(
        for observation: AircraftObservation,
        around center: Coordinate,
        configuration: ProximityConfiguration,
        now: Date
    ) -> AircraftCandidate? {
        guard !observation.isOnGround,
              now.timeIntervalSince(observation.observedAt) >= 0,
              now.timeIntervalSince(observation.observedAt) <= configuration.maximumObservationAge,
              observation.altitudeMeters.map({ $0 >= (configuration.minimumAltitudeMeters ?? 0) }) ?? true
        else { return nil }

        let distance = distanceKilometers(from: center, to: observation.coordinate)
        let prediction = closestApproach(
            observation: observation,
            center: center,
            horizon: configuration.predictionHorizon
        )
        guard distance <= configuration.radiusKilometers
                || prediction.distanceKilometers <= configuration.radiusKilometers
        else { return nil }

        return AircraftCandidate(
            observation: observation,
            distanceKilometers: distance,
            predictedClosestApproachKilometers: prediction.distanceKilometers,
            secondsUntilClosestApproach: prediction.time
        )
    }

    public func rankedCandidates(
        observations: [AircraftObservation],
        around center: Coordinate,
        configuration: ProximityConfiguration,
        now: Date
    ) -> [AircraftCandidate] {
        observations.compactMap {
            candidate(for: $0, around: center, configuration: configuration, now: now)
        }.sorted {
            if $0.predictedClosestApproachKilometers == $1.predictedClosestApproachKilometers {
                return $0.distanceKilometers < $1.distanceKilometers
            }
            return $0.predictedClosestApproachKilometers < $1.predictedClosestApproachKilometers
        }
    }

    private func closestApproach(
        observation: AircraftObservation,
        center: Coordinate,
        horizon: TimeInterval
    ) -> (distanceKilometers: Double, time: TimeInterval) {
        guard let speed = observation.groundSpeedMetersPerSecond,
              speed > 0,
              let track = observation.trackDegrees,
              horizon > 0
        else {
            return (distanceKilometers(from: center, to: observation.coordinate), 0)
        }

        let latitudeScale = 111.32
        let longitudeScale = max(0.001, latitudeScale * cos(center.latitude.radians))
        let eastKilometers = (observation.coordinate.longitude - center.longitude) * longitudeScale
        let northKilometers = (observation.coordinate.latitude - center.latitude) * latitudeScale
        let speedKilometersPerSecond = speed / 1_000
        let eastVelocity = speedKilometersPerSecond * sin(track.radians)
        let northVelocity = speedKilometersPerSecond * cos(track.radians)
        let velocitySquared = eastVelocity * eastVelocity + northVelocity * northVelocity
        let unconstrainedTime = -(eastKilometers * eastVelocity + northKilometers * northVelocity) / velocitySquared
        let time = min(max(0, unconstrainedTime), horizon)
        let closestEast = eastKilometers + eastVelocity * time
        let closestNorth = northKilometers + northVelocity * time
        return (hypot(closestEast, closestNorth), time)
    }
}

public actor EligibilityTracker {
    private var lastTriggeredAt: [String: Date] = [:]
    private var previouslyInside: Set<String> = []

    public init() {}

    public func nextEligible(
        observations: [AircraftObservation],
        around center: Coordinate,
        configuration: ProximityConfiguration,
        now: Date = .now
    ) -> AircraftCandidate? {
        let engine = ProximityEngine()
        let candidates = engine.rankedCandidates(
            observations: observations,
            around: center,
            configuration: configuration,
            now: now
        )
        let currentlyInside = Set(candidates.map(\.observation.id))
        defer { previouslyInside = currentlyInside }

        guard let selected = candidates.first(where: { candidate in
            let id = candidate.observation.id
            let isNewEntry = !previouslyInside.contains(id)
            let cooldownElapsed = lastTriggeredAt[id].map {
                now.timeIntervalSince($0) >= configuration.cooldown
            } ?? true
            return isNewEntry && cooldownElapsed
        }) else { return nil }

        lastTriggeredAt[selected.observation.id] = now
        return selected
    }

    public func reset() {
        lastTriggeredAt.removeAll()
        previouslyInside.removeAll()
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
}
