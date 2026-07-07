import Foundation

public struct TerminalHardwareKeyRepeatConfiguration: Equatable, Sendable {
    public static let defaultEnabled = true
    public static let defaultDelayMilliseconds = 500.0
    public static let defaultIntervalMilliseconds = 50.0
    public static let delayRange = 150.0...1200.0
    public static let intervalRange = 20.0...250.0

    public var enabled: Bool
    public var delayMilliseconds: Double
    public var intervalMilliseconds: Double

    public init(
        enabled: Bool = Self.defaultEnabled,
        delayMilliseconds: Double = Self.defaultDelayMilliseconds,
        intervalMilliseconds: Double = Self.defaultIntervalMilliseconds
    ) {
        self.enabled = enabled
        self.delayMilliseconds = Self.clampedDelay(delayMilliseconds)
        self.intervalMilliseconds = Self.clampedInterval(intervalMilliseconds)
    }

    public static var `default`: TerminalHardwareKeyRepeatConfiguration {
        TerminalHardwareKeyRepeatConfiguration()
    }

    public static func clampedDelay(_ milliseconds: Double) -> Double {
        min(max(milliseconds, delayRange.lowerBound), delayRange.upperBound)
    }

    public static func clampedInterval(_ milliseconds: Double) -> Double {
        min(max(milliseconds, intervalRange.lowerBound), intervalRange.upperBound)
    }

    var delayNanoseconds: UInt64 {
        Self.nanoseconds(forMilliseconds: delayMilliseconds)
    }

    var intervalNanoseconds: UInt64 {
        Self.nanoseconds(forMilliseconds: intervalMilliseconds)
    }

    private static func nanoseconds(forMilliseconds milliseconds: Double) -> UInt64 {
        UInt64((max(milliseconds, 1.0) * 1_000_000).rounded())
    }
}
