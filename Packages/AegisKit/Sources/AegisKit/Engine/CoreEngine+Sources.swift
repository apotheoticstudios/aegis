import Foundation

/// Source-local retry state. The final delay repeats until a committed scan succeeds.
struct SourceRetry {
    var failures = 0
    var nextAttempt = Date.distantPast

    mutating func failed(at now: Date) {
        let delays: [TimeInterval] = [60, 5 * 60, 15 * 60]
        failures = min(failures + 1, delays.count)
        nextAttempt = now.addingTimeInterval(delays[failures - 1])
    }
}

extension CoreEngine {
    /// Called inside the engine's serial lane. Each source owns its scan, transaction and retry state.
    func collectSources(retriesOnly: Bool = false) async {
        for collector in collectors {
            let retry = sourceRetries[collector.source]
            if let retry, clock() < retry.nextAttempt {
                continue
            }
            if retriesOnly, retry == nil {
                continue
            }
            await collectSource(collector)
        }
    }

    private func collectSource(_ collector: any EventCollector) async {
        let source = collector.source
        let started = clock()
        if sourceFirstAttempt[source] == nil {
            sourceFirstAttempt[source] = started
        }
        do {
            let checkpoint = try await store.checkpoint(for: source)
            if coverage[source] == nil, let checkpoint {
                coverage[source] = SourceCoverage(source: source, status: .ok, events: 0, lastSuccess: checkpoint.scannedAt)
            }
            let batch = try await collector.collect(after: checkpoint, now: started)
            guard batch.source == source, batch.checkpoint.map({ $0.source == source }) ?? true else {
                sourceFailed(source, code: .unreadable)
                return
            }
            guard batch.status.ok else {
                sourceFailed(source, code: batch.status.code)
                return // A failed scan must never advance its checkpoint or reconcile records away.
            }
            try await store.ingest(batch)
            sourceRetries[source] = nil
            coverage[source] = SourceCoverage(source: source, status: batch.status.code, events: batch.events.count, lastSuccess: clock())
        } catch let error as StoreUnavailable {
            sourceFailed(source, code: error.code)
        } catch is UnknownSchemaError {
            sourceFailed(source, code: .formatChanged)
        } catch {
            sourceFailed(source, code: .unreadable)
        }
    }

    private func sourceFailed(_ source: SourceKind, code: SourceStatus.Code) {
        coverage[source] = SourceCoverage(source: source, status: code, events: 0, lastSuccess: coverage[source]?.lastSuccess)
        var retry = sourceRetries[source] ?? SourceRetry()
        retry.failed(at: clock())
        sourceRetries[source] = retry
    }

    /// Project health at read time so `.status` can report staleness even during a retry delay.
    func sourceCoverage(at now: Date) -> [SourceCoverage] {
        let items = Array(coverage.values)
        return items.map { item in
            var result = item
            if SourceHealth.isStale(item, among: items, since: sourceFirstAttempt[item.source], now: now) {
                result.status = .stale
            }
            return result
        }.sorted { $0.source.rawValue < $1.source.rawValue }
    }
}
