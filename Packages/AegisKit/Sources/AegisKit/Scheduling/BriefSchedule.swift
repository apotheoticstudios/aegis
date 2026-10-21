import Foundation

/// Persisted scheduler state, separate from the last checked `StoredBrief` kept by AegisCore.
/// Persist transitions before executing work; persist publication and its final state atomically.
/// Dates on events are the injected clock. The caller serializes all events.
public struct BriefSchedule: Codable, Sendable, Equatable {
    /// Whether travel changes the opening's local time zone.
    public enum TimeZonePolicy: String, Codable, Sendable {
        /// Follow explicit `timeZoneChanged` events; never consult the host's zone.
        case followLocal
        /// Keep the initial time zone even when travelling.
        case fixed
    }

    /// The owner's local opening hour, in 0...23.
    public let openingHour: Int
    /// The owner's local opening minute, in 0...59.
    public let openingMinute: Int
    /// How explicit travel events affect the opening time.
    public let timeZonePolicy: TimeZonePolicy
    /// The effective time zone, also restored after a crash.
    public internal(set) var timeZone: TimeZone
    /// Maximum snapshot age, checked before generation and publication.
    public let inputWindow: TimeInterval
    /// Deadline for the entire refresh and generation attempt.
    public let jobTimeout: TimeInterval
    /// Last twenty finite, nonnegative durations of successfully published jobs.
    public internal(set) var durations: [TimeInterval]
    /// Current phase, suitable for presentation by the panel.
    public internal(set) var state: ScheduleState = .idle
    /// The reserved job, including during refresh and cancellation.
    public internal(set) var job: ScheduledBriefJob?
    /// Timestamp of the last complete, validated result; failure never changes it.
    public internal(set) var lastBriefAt: Date?

    var isAwake = true
    var thermalSerious = false
    var lowPower = false
    var sequence: UInt64 = 0
    var failures = 0
    var pendingOpening: Date?
    var completedDays: [String] = []

    /// Creates a schedule with explicit zone and optional previously stored brief timestamp.
    /// Requires valid wall-clock components and finite positive window and timeout values.
    public init(
        openingHour: Int, openingMinute: Int, timeZone: TimeZone,
        timeZonePolicy: TimeZonePolicy = .followLocal, durations: [TimeInterval] = [],
        inputWindow: TimeInterval = 900, jobTimeout: TimeInterval = 600, lastBriefAt: Date? = nil
    ) {
        precondition((0 ... 23).contains(openingHour) && (0 ... 59).contains(openingMinute))
        precondition(inputWindow.isFinite && inputWindow > 0 && jobTimeout.isFinite && jobTimeout > 0)
        self.openingHour = openingHour
        self.openingMinute = openingMinute
        self.timeZone = timeZone
        self.timeZonePolicy = timeZonePolicy
        self.durations = Array(durations.filter { $0.isFinite && $0 >= 0 }.suffix(20))
        self.inputWindow = inputWindow
        self.jobTimeout = jobTimeout
        self.lastBriefAt = lastBriefAt
    }

    /// Nearest-rank p95 plus one minute, with a minimum lead of two minutes.
    public var lead: TimeInterval {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return 120 }
        return max(120, sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] + 60)
    }

    /// Opening on the supplied civil day. Gaps use the next valid time and folds the first occurrence.
    /// The injected calendar's rules are used with this schedule's explicit time zone.
    public func opening(on date: Date, calendar: Calendar) -> Date? {
        var local = calendar
        local.timeZone = timeZone
        return local.nextDate(
            after: local.startOfDay(for: date).addingTimeInterval(-1),
            matching: DateComponents(hour: openingHour, minute: openingMinute, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first
        )
    }
}

/// A scheduler-owned reservation. AegisCore uses its ID and deadline for the `ModelJob`.
public struct ScheduledBriefJob: Codable, Sendable, Equatable {
    /// Deterministic monotonically numbered ID within this persisted schedule.
    public let id: String
    /// The opening this attempt satisfies, possibly on the next day when lead crosses midnight.
    public let opening: Date
    /// Civil date in the zone where the job was reserved, for deduplication across travel.
    public let day: String
    /// Absolute deadline, preserved across crashes.
    public let deadline: Date
    /// Snapshot timestamp supplied by refresh completion; nil until a fresh snapshot arrives.
    public internal(set) var inputTime: Date?
}

/// Persisted phases. A reserved refresh is busy just like generation.
public enum ScheduleState: Codable, Sendable, Equatable {
    /// No pending or running work.
    case idle
    /// Waiting for a fresh source snapshot.
    case refreshing
    /// Model work is running.
    case generating
    /// Cancellation requested; the slot stays occupied until termination is acknowledged.
    case cancelling
    /// Work is pending under heat or low power; reasons are `thermal_serious` or `low_power`.
    case deferred(reason: String)
    /// Retry after the supplied absolute time; exponential delay starts at 60 seconds, capped at one hour.
    case backoff(until: Date)
}

/// Inputs from AegisCore. No event reads the system clock or performs any work itself.
public enum ScheduleEvent: Sendable {
    /// Reevaluate the schedule and active deadline at the injected time.
    case tick(Date)
    /// Mark the Mac awake and catch up the current civil day once.
    case wake(Date)
    /// Mark the Mac asleep, retaining the cached brief and requesting cancellation of active work.
    case sleep(Date)
    /// Request a fresh brief; an occupied slot returns `already_generating`.
    case userRefresh(Date)
    /// Follow travel under the local policy, without altering a running job's target.
    case timeZoneChanged(TimeZone, Date)
    /// Complete a refresh for this reservation; timestamps outside the input window cause backoff.
    case sourcesRefreshed(jobID: String, inputTime: Date, at: Date)
    /// Report termination. `completed` means AegisCore has validated the entire result for publication.
    /// Partial, invalid and cancelled results must use a non-completed status.
    case jobFinished(jobID: String, outcome: ModelJobResult.Status, duration: TimeInterval, at: Date)
    /// Update power conditions. Clearing both automatically resumes pending work.
    /// Running generation may finish; new generation waits until both conditions clear.
    case conditions(thermalSerious: Bool, lowPower: Bool, at: Date)
    /// Resume decoded state AFTER AegisCore confirms previous workers have terminated.
    /// An interrupted reservation keeps the previous brief and enters retry backoff.
    case resume(Date)
}

/// Effects for AegisCore to execute in order. Persist before starting work; publication is atomic with state.
public enum ScheduleAction: Sendable, Equatable {
    /// Refresh sources for the reservation in `schedule.job`, then send `sourcesRefreshed`.
    case refreshSources
    /// Start the reserved model job using only the acknowledged fresh snapshot.
    case startGeneration(jobID: String)
    /// Atomically persist the complete, checked result and the resulting scheduler state.
    case publishBrief(jobID: String)
    /// Terminate this worker; acknowledge termination with `jobFinished` before another job starts.
    case cancelJob(jobID: String)
    /// Retain the previous brief and its timestamp.
    case keepPreviousBrief
    /// Make the pending deferral reason visible in the panel's state.
    case publishDeferred(reason: String)
    /// Map directly to `CoreResponse.refused(code:)`.
    case refused(code: String)
}
