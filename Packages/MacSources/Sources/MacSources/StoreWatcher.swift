import Foundation

/// Calls `changed` soon after a SQLite store or its write-ahead log changes (Stage 1 step 2.9, #138).
///
/// It uses kqueue file events only: nothing runs while the files are quiet, and nothing is read. It watches
/// the store's folder (files appearing or being replaced) and the store and `-wal` files (writes), and re-arms
/// when SQLite deletes or replaces a file. Bursts are coalesced: `changed` runs `delay` after the first event,
/// and at most once per `minimumGap`.
public final class StoreWatcher: @unchecked Sendable {
    // All mutable state is touched only on `queue`.
    private let queue = DispatchQueue(label: "dev.aegis.store-watcher", qos: .utility)
    private let store: URL
    private let delay: TimeInterval
    private let minimumGap: TimeInterval
    private let changed: @Sendable () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var scheduled = false
    private var lastCall = Date.distantPast

    public init(
        store: URL, delay: TimeInterval = 1, minimumGap: TimeInterval = 5, changed: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.delay = delay
        self.minimumGap = minimumGap
        self.changed = changed
    }

    deinit {
        for source in sources {
            source.cancel()
        }
    }

    public func start() {
        queue.async { self.arm() }
    }

    /// Re-opens every watch, for files or a folder replaced while nothing was watching them. Cheap: three
    /// file descriptors. AegisCore calls it with each reconciliation scan.
    public func rearm() {
        queue.async { self.arm() }
    }

    public func stop() {
        queue.sync { self.cancelAll() }
    }

    private func arm() {
        cancelAll()
        watch(store.deletingLastPathComponent(), events: .write, rearm: true)
        watch(store, events: [.write, .extend, .delete, .rename, .revoke], rearm: false)
        watch(URL(fileURLWithPath: store.path + "-wal"), events: [.write, .extend, .delete, .rename, .revoke], rearm: false)
    }

    /// A missing file is skipped: the folder's events re-arm the watch when SQLite creates it.
    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent, rearm: Bool) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if rearm || !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                arm()
            }
            schedule()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        let wait = max(delay, minimumGap - Date().timeIntervalSince(lastCall))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            scheduled = false
            lastCall = Date()
            changed()
        }
    }

    private func cancelAll() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }
}
