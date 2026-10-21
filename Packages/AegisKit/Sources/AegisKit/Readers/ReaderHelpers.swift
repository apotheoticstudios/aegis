import Foundation

public extension ReaderBase {
    /// Seconds since 2001-01-01 to a date, or nil outside the half-open 2001–2100 interval.
    static func cocoa(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds >= 0, seconds < 3_124_137_600 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Seconds since the Cocoa epoch, including fractional seconds.
    static func cocoaSeconds(_ moment: Date) -> Double {
        moment.timeIntervalSinceReferenceDate
    }

    /// A stored number; NULL, text and blobs are not coerced to numbers.
    static func number(_ value: SQLiteValue?) -> Double? {
        switch value {
        case let .integer(value): Double(value)
        case let .real(value): value
        default: nil
        }
    }

    /// Keeps future timestamps but flags those more than ten minutes ahead of capture.
    static func skewFlags(_ moment: Date, now: Date) -> [Event.Flag] {
        moment > now.addingTimeInterval(clockSkewAllowance) ? [.clockSkew] : []
    }

    // Mirrors the contract fields rather than introducing another event fields type.
    // swiftlint:disable function_parameter_count
    /// Builds a contract event and its single route observation. Event's initializer uses EventID.make.
    static func makeEvent(
        source: Event.Source, sourceRecordID: String, eventTime: Date, eventTimeSource: Event.TimeSource,
        captureTime: Date, body: String, content: Event.Content, route: Event.Observation.Route,
        appID: String? = nil, sender: String? = nil, threadID: String? = nil, title: String? = nil,
        flags: [Event.Flag] = []
    ) -> Event {
        // Stage 0's iso(event_time) writes whole seconds; capture_time is passed through.
        let eventTime = Date(timeIntervalSince1970: eventTime.timeIntervalSince1970.rounded(.down))
        return Event(
            source: source, sourceRecordID: sourceRecordID, appID: appID, sender: sender, threadID: threadID,
            eventTime: eventTime, eventTimeSource: eventTimeSource, captureTime: captureTime, title: title,
            body: body, content: content, flags: flags,
            observations: [.init(route: route, sourceRecordID: sourceRecordID, captureTime: captureTime)]
        )
    }
    // swiftlint:enable function_parameter_count
}
