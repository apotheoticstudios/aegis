import Foundation

/// Advances the pure scheduler using only persisted state, an event timestamp and an injected calendar.
/// Empty actions mean no work. Late wake/ticks catch up today's opening, never every missed day.
/// A completed civil date is remembered across zone changes (last twenty dates) to avoid duplicate mornings.
public func step(_ schedule: inout BriefSchedule, _ event: ScheduleEvent, calendar: Calendar) -> [ScheduleAction] {
    var local = calendar
    local.timeZone = schedule.timeZone
    if let actions = handle(&schedule, event, calendar: local) {
        return actions
    }
    local.timeZone = schedule.timeZone
    let now = event.time
    if let job = schedule.job {
        guard now >= job.deadline, schedule.state != .cancelling else { return [] }
        schedule.state = .cancelling
        return [.keepPreviousBrief, .cancelJob(jobID: job.id)]
    }
    guard schedule.isAwake else { return [] }
    if case let .backoff(until) = schedule.state, now < until {
        return []
    }
    guard let opening = target(schedule, at: now, calendar: local) else { return [] }
    schedule.pendingOpening = opening
    if let actions = deferForConditions(&schedule) {
        return actions
    }
    schedule.sequence += 1
    schedule.job = ScheduledBriefJob(
        id: "brief-\(schedule.sequence)", opening: opening, day: dayKey(opening, calendar: local),
        deadline: now.addingTimeInterval(schedule.jobTimeout), inputTime: nil
    )
    schedule.state = .refreshing
    return [.refreshSources]
}

private func handle(_ schedule: inout BriefSchedule, _ event: ScheduleEvent, calendar: Calendar) -> [ScheduleAction]? {
    switch event {
    case .sleep:
        return sleep(&schedule)
    case .wake:
        schedule.isAwake = true
    case .resume:
        return resume(&schedule, at: event.time)
    case let .timeZoneChanged(zone, now):
        travel(&schedule, to: zone, at: now, calendar: calendar)
    case let .conditions(thermal, power, _):
        schedule.thermalSerious = thermal
        schedule.lowPower = power
    case let .sourcesRefreshed(id, inputTime, now):
        return refreshed(&schedule, id: id, inputTime: inputTime, at: now)
    case let .jobFinished(id, outcome, duration, now):
        return finished(&schedule, id: id, outcome: outcome, duration: duration, at: now)
    case .userRefresh:
        return manual(&schedule, at: event.time, calendar: calendar)
    case .tick:
        break
    }
    return nil
}

private func sleep(_ schedule: inout BriefSchedule) -> [ScheduleAction] {
    schedule.isAwake = false
    guard let job = schedule.job, schedule.state != .cancelling else { return [.keepPreviousBrief] }
    schedule.state = .cancelling
    return [.keepPreviousBrief, .cancelJob(jobID: job.id)]
}

private func resume(_ schedule: inout BriefSchedule, at now: Date) -> [ScheduleAction]? {
    schedule.isAwake = true
    return schedule.job == nil ? nil : fail(&schedule, at: now)
}

private func manual(_ schedule: inout BriefSchedule, at now: Date, calendar: Calendar) -> [ScheduleAction]? {
    guard schedule.job == nil else { return [.refused(code: "already_generating")] }
    schedule.pendingOpening = schedule.opening(on: now, calendar: calendar)
    schedule.state = .idle // An explicit user command may bypass retry delay.
    return nil
}

private func travel(_ schedule: inout BriefSchedule, to zone: TimeZone, at now: Date, calendar: Calendar) {
    guard schedule.timeZonePolicy == .followLocal else { return }
    schedule.timeZone = zone
    if schedule.job == nil, schedule.pendingOpening != nil {
        schedule.pendingOpening = schedule.opening(on: now, calendar: calendar)
    }
}

private func refreshed(_ schedule: inout BriefSchedule, id: String, inputTime: Date, at now: Date) -> [ScheduleAction] {
    guard let job = schedule.job, job.id == id, schedule.state == .refreshing else { return [] }
    guard now < job.deadline, fresh(inputTime, at: now, window: schedule.inputWindow) else {
        return fail(&schedule, at: now)
    }
    // Refresh has terminated, so releasing its reservation under new power conditions is safe.
    if let actions = deferForConditions(&schedule) {
        schedule.job = nil
        return actions
    }
    schedule.job?.inputTime = inputTime
    schedule.state = .generating
    return [.startGeneration(jobID: id)]
}

private func finished(
    _ schedule: inout BriefSchedule, id: String, outcome: ModelJobResult.Status, duration: TimeInterval, at now: Date
) -> [ScheduleAction] {
    guard let job = schedule.job, job.id == id else { return [] }
    guard schedule.state == .generating, outcome == .completed, now < job.deadline,
          let input = job.inputTime, fresh(input, at: now, window: schedule.inputWindow)
    else { return fail(&schedule, at: now) }
    if duration.isFinite, duration >= 0 {
        schedule.durations = Array((schedule.durations + [duration]).suffix(20))
    }
    schedule.lastBriefAt = now
    schedule.completedDays = Array((schedule.completedDays.filter { $0 != job.day } + [job.day]).suffix(20))
    schedule.job = nil
    schedule.pendingOpening = nil
    schedule.failures = 0
    schedule.state = .idle
    return [.publishBrief(jobID: id)]
}

private func deferForConditions(_ schedule: inout BriefSchedule) -> [ScheduleAction]? {
    guard schedule.thermalSerious || schedule.lowPower else { return nil }
    let reason = schedule.thermalSerious ? "thermal_serious" : "low_power"
    let deferred = ScheduleState.deferred(reason: reason)
    guard schedule.state != deferred else { return [] }
    schedule.state = deferred
    return [.keepPreviousBrief, .publishDeferred(reason: reason)]
}

private func fresh(_ input: Date, at now: Date, window: TimeInterval) -> Bool {
    let age = now.timeIntervalSince(input)
    return age >= 0 && age <= window
}

private func dayKey(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
    return "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
}

private func target(_ schedule: BriefSchedule, at now: Date, calendar: Calendar) -> Date? {
    guard let today = schedule.opening(on: now, calendar: calendar) else { return nil }
    if !schedule.completedDays.contains(dayKey(today, calendar: calendar)), now >= today.addingTimeInterval(-schedule.lead) {
        return today
    }
    // Calendar addition, not 86400 seconds: DST days may be shorter or longer.
    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    if let nextDay, let tomorrow = schedule.opening(on: nextDay, calendar: calendar) {
        let isPending = !schedule.completedDays.contains(dayKey(tomorrow, calendar: calendar))
        if isPending, now >= tomorrow.addingTimeInterval(-schedule.lead) {
            return tomorrow
        }
    }
    if let pending = schedule.pendingOpening {
        // Expired deferred/retrying work coalesces to today instead of generating historical windows.
        return pending < calendar.startOfDay(for: now) ? today : pending
    }
    return nil
}

private func fail(_ schedule: inout BriefSchedule, at now: Date) -> [ScheduleAction] {
    schedule.pendingOpening = schedule.job?.opening ?? schedule.pendingOpening
    schedule.job = nil
    schedule.failures = min(schedule.failures + 1, 7)
    let delay = min(3600, 60 * pow(2, Double(schedule.failures - 1)))
    schedule.state = .backoff(until: now.addingTimeInterval(delay))
    return [.keepPreviousBrief]
}

private extension ScheduleEvent {
    var time: Date {
        switch self {
        case let .tick(time), let .wake(time), let .sleep(time), let .userRefresh(time), let .resume(time),
             let .timeZoneChanged(_, time), let .conditions(_, _, time),
             let .sourcesRefreshed(_, _, time), let .jobFinished(_, _, _, time):
            time
        }
    }
}
