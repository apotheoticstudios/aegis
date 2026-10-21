import AegisKit
import AegisStorage
import Foundation
import MacSources
import os

/// The notification recorder (steps 2.9 and 2.10, #138). Notification Center deletes a notification when
/// it's dismissed, so new ones are copied into the store about a second after the store changes (file
/// events, no polling), with a reconciliation scan every 5 minutes. One scan at a time: a change during
/// a scan runs one more scan after it. Event IDs are stable, so an overlapping scan stores nothing twice.
/// A failed scan keeps the checkpoint, logs its error code (never content) and is retried sooner.
actor NotificationRecorder {
    private let collector: ReaderCollector
    private let store: GRDBEventStore
    private let log = Logger(subsystem: "dev.aegis.core", category: "notifications")
    private var running = false
    private var again = false
    /// Consecutive failed scans; reset by a successful one.
    private(set) var failures = 0

    init(collector: ReaderCollector, store: GRDBEventStore) {
        self.collector = collector
        self.store = store
    }

    func record() async {
        if running {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            do {
                let batch = try await collector.collect(after: store.checkpoint(for: .notifications), now: Date())
                try await store.ingest(batch)
                failures = 0
            } catch {
                failures += 1
                let code = (error as NSError).code, domain = (error as NSError).domain, count = failures
                log.error("scan failed: \(domain, privacy: .public) \(code, privacy: .public) (\(count, privacy: .public) in a row)")
            }
        } while again
        running = false
    }

    /// The reconciliation interval: 5 minutes, or sooner after failures (30 s, 1, 2, 4 minutes).
    func nextDelay() -> Duration {
        failures == 0 ? .seconds(300) : .seconds(min(300, 30 << min(failures - 1, 4)))
    }
}
