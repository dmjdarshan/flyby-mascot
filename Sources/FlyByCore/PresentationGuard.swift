import Foundation

public enum PresentationSafetyMode: String, CaseIterable, Sendable {
    case balanced
    case strict
    case manualOnly
}

public struct PresentationState: Sendable, Equatable {
    public var manualPauseUntil: Date?
    public var captureDetected: Bool
    public var strictAppDetected: Bool
    public var isQuietHours: Bool
    public var safetyMode: PresentationSafetyMode

    public init(
        manualPauseUntil: Date? = nil,
        captureDetected: Bool = false,
        strictAppDetected: Bool = false,
        isQuietHours: Bool = false,
        safetyMode: PresentationSafetyMode = .balanced
    ) {
        self.manualPauseUntil = manualPauseUntil
        self.captureDetected = captureDetected
        self.strictAppDetected = strictAppDetected
        self.isQuietHours = isQuietHours
        self.safetyMode = safetyMode
    }

    public func overlayDecision(now: Date = .now) -> OverlayDecision {
        if let pause = manualPauseUntil, pause > now { return .suppress(.manualPause) }
        if isQuietHours { return .suppress(.quietHours) }
        if safetyMode != .manualOnly, captureDetected { return .suppress(.captureDetected) }
        if safetyMode == .strict, strictAppDetected { return .suppress(.strictAppRunning) }
        return .allow
    }
}

public enum SuppressionReason: String, Sendable, Equatable {
    case manualPause
    case quietHours
    case captureDetected
    case strictAppRunning
}

public enum OverlayDecision: Sendable, Equatable {
    case allow
    case suppress(SuppressionReason)
}
