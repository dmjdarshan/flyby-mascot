import Foundation

public enum PollingCadence: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15

    public var id: Int { rawValue }
    public var interval: Duration { .seconds(rawValue * 60) }
    public var label: String { "Every \(rawValue) min" }
    public var maximumDailyRequests: Int { (24 * 60) / rawValue }
}
