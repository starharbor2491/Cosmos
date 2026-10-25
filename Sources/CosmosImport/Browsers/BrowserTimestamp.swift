import Foundation

/// The three epochs browsers store times in.
public enum BrowserTimestamp {
    /// Seconds between 1601-01-01 (Chromium/WebKit/Windows FILETIME) and 1970-01-01.
    public static let chromiumEpochOffsetSeconds: Int64 = 11_644_473_600

    /// Chromium and Arc: microseconds since 1601-01-01 UTC. The epoch shift is done in integers, so whole seconds are exact.
    public static func chromium(microseconds: Int64) -> Date {
        let (unixMicros, overflow) = microseconds.subtractingReportingOverflow(chromiumEpochOffsetSeconds * 1_000_000)
        return overflow ? .distantPast : Date(timeIntervalSince1970: Double(unixMicros) / 1_000_000)
    }

    /// The inverse of `chromium(microseconds:)`, for `since` filters.
    public static func chromiumMicroseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) + chromiumEpochOffsetSeconds * 1_000_000
    }

    /// Firefox: microseconds since 1970-01-01 UTC.
    public static func unix(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    public static func unixMicroseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// Safari (Core Data): seconds since 2001-01-01 UTC.
    public static func coreData(seconds: Double) -> Date {
        seconds.isFinite ? Date(timeIntervalSinceReferenceDate: seconds) : .distantPast
    }

    /// Dates before this are treated as "unknown": browsers write 0 or garbage for never-visited rows.
    static let earliestPlausible = Date(timeIntervalSince1970: 631_152_000)   // 1990-01-01

    /// `nil` for implausibly old dates; dates in the future are clamped to `now`.
    static func sanitized(_ date: Date?, now: Date) -> Date? {
        guard let date, date >= earliestPlausible else { return nil }
        return min(date, now)
    }
}
