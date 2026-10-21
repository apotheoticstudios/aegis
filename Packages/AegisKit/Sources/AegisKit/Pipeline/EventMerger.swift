import Foundation

/// Deterministic disk-spooled notification/Messages merging. Chat records retain the canonical ID and body.
public enum EventMerger {
    /// Array convenience API. For large streams, use `withMergedEvents` to avoid materializing the output.
    public static func merge(
        _ events: some Sequence<Event>, aliases: [String: String] = [:], toleranceSeconds: TimeInterval = 5
    ) throws -> [Event] {
        try withMergedEvents(events, aliases: aliases, toleranceSeconds: toleranceSeconds) { Array($0) }
    }

    /// Consume canonical events oldest first while private scratch storage is alive; cleanup runs on return or error.
    /// Unique twins need no aliases, groups use chat GUIDs, and ambiguous same-text messages stay separate.
    /// All observations survive, including distinct capture times and exact source-record bytes.
    /// Scratch indexes and external sorting keep memory independent of corpus length (apart from one event's observations).
    public static func withMergedEvents<Result>(
        _ events: some Sequence<Event>, aliases: [String: String] = [:], toleranceSeconds: TimeInterval = 5,
        _ consume: (AnySequence<Event>) throws -> Result
    ) throws -> Result {
        guard toleranceSeconds >= 0, toleranceSeconds.isFinite else { throw PipelineError.invalidPolicy }
        let spool = try MergeSpool(aliases: aliases, tolerance: toleranceSeconds)
        defer { spool.remove() }
        for event in events {
            try pipelinePool { try spool.add(event) }
        }
        let (ordered, run) = try spool.orderedEvents()
        defer { run.close() }
        let result = try consume(ordered)
        if let failure = spool.failure {
            throw failure
        }
        return result
    }
}
