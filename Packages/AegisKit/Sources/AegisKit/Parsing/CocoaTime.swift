import Foundation

/// Pure conversions for timestamps and UUID bytes used by the Stage 0 readers.
public enum CocoaTime {
    /// Converts seconds since 2001-01-01 UTC to a date in [2001-01-01, 2100-01-01).
    /// Returns nil for negative, non-finite, or out-of-range values; zero is the epoch.
    public static func date(fromSeconds seconds: Double) -> Date? {
        guard seconds.isFinite, seconds >= 0, seconds < 3_124_137_600 else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Formats exactly 16 bytes in UUID network byte order as an uppercase UUID string.
    /// Returns nil if the byte count is not 16.
    public static func uuidString(_ bytes: Data) -> String? {
        guard bytes.count == 16 else {
            return nil
        }
        let value = Array(bytes)
        return UUID(uuid: (
            value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]
        )).uuidString.uppercased()
    }
}
