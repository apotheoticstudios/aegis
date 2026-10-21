import Foundation

/// Filesystem indexes and a fixed-size external merge sort replace Python's SQLite scratch spool.
/// Only one record's observations and 256 timestamp/ID rows are resident during merging.
final class MergeSpool {
    let folder: URL
    let aliases: [String: String]
    let tolerance: TimeInterval
    var failure: (any Error)?
    private var hasNotes = false
    private var registry: FileHandle?

    init(aliases: [String: String], tolerance: TimeInterval) throws {
        self.aliases = Dictionary(aliases.map { (folded($0.key), folded($0.value)) }, uniquingKeysWith: { _, last in last })
        self.tolerance = tolerance
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-merge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for name in ["records", "notes", "bodies", "groups", "links", "suppressed", "runs"] {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            let created = path("created")
            guard FileManager.default.createFile(atPath: created.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PipelineError.scratchStorage
            }
            registry = try FileHandle(forUpdating: created)
        } catch {
            remove()
            throw error
        }
    }

    /// Delete registered files individually, avoiding recursive directory-sized native lists.
    func remove() {
        if let registry, var offset = try? registry.seekToEnd() {
            while offset >= 256 {
                offset -= 256
                pipelinePool {
                    do {
                        try registry.seek(toOffset: offset)
                        let bytes = try registry.read(upToCount: 256) ?? Data()
                        let relative = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                        if !relative.isEmpty {
                            try? FileManager.default.removeItem(at: path(relative))
                        }
                    } catch { /* Best-effort cleanup must not mask the original error. */ }
                }
            }
            try? registry.close()
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func register(_ url: URL) throws {
        let relative = String(url.path.dropFirst(folder.path.count + 1))
        var bytes = Data(relative.utf8)
        guard bytes.count < 256, let registry else { throw PipelineError.scratchStorage }
        bytes.append(Data(repeating: 0, count: 256 - bytes.count))
        try registry.seekToEnd()
        try registry.write(contentsOf: bytes)
    }

    private func path(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    private func hash(_ text: String) -> String {
        SHA256.hex(Array(text.utf8))
    }

    private func write(_ data: Data, _ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try register(url)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PipelineError.scratchStorage
        }
    }

    private func store(_ event: Event) throws {
        try write(JSONEncoder().encode(event), path("records/" + hash(event.id)))
    }

    private func load(_ key: String) throws -> Event {
        try JSONDecoder().decode(Event.self, from: Data(contentsOf: path("records/" + key)))
    }

    private func identity(_ text: String?) -> String {
        let name = folded(text ?? "")
        let value = aliases[name] ?? name
        if !value.isEmpty,
           value.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || "+ ()-.".unicodeScalars.contains($0) })
        {
            return String(String.UnicodeScalarView(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }))
        }
        return value
    }

    private func groupName(_ event: Event) -> String? {
        guard event.source == .imessage || event.source == .sms, let title = event.title, !title.isEmpty,
              !(event.threadID ?? "").contains(";-;"), identity(title) != identity(event.sender) else { return nil }
        return (event.threadID ?? "").contains(";+;") || !event.observations.contains(where: {
            $0.route == .notificationDB || $0.route == .accessibility
        }) ? folded(title) : nil
    }

    private func observationUnion(_ arrays: [[Event.Observation]]) throws -> [Event.Observation] {
        var values: [Data: Event.Observation] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for array in arrays {
            for observation in array {
                try values[encoder.encode(observation)] = observation
            }
        }
        return values.values.sorted {
            if $0.route != $1.route {
                return scalarLess($0.route.rawValue, $1.route.rawValue)
            }
            if !exactText($0.sourceRecordID, $1.sourceRecordID) {
                return scalarLess($0.sourceRecordID, $1.sourceRecordID)
            }
            return $0.captureTime < $1.captureTime
        }
    }

    func add(_ event: Event) throws {
        let key = hash(event.id)
        let previous = FileManager.default.fileExists(atPath: path("records/" + key).path) ? try load(key) : nil
        var selected = event
        if let previous {
            if previous.captureTime > event.captureTime {
                selected = previous
            } else if previous.captureTime == event.captureTime {
                if try !scalarLess(revisionKey(previous), revisionKey(event)) {
                    selected = previous
                }
            }
        }
        selected.observations = try observationUnion([previous?.observations ?? [], event.observations])
        if previous?.source == .notification, selected.source != .notification {
            try FileManager.default.removeItem(at: path("notes/" + key))
        }
        try store(selected)
        if previous == nil {
            try appendKey(key, to: path("records.index"))
        }
        if selected.source == .notification {
            hasNotes = true
            if previous?.source != .notification {
                try appendKey(key, to: path("notes.index"))
            }
            try write(Data(), path("notes/" + key))
        }
        if let group = groupName(event) {
            try write(Data(), path("groups/" + hash(group)))
        }
    }

    private func appendKey(_ key: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try write(Data(), url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((key + "\n").utf8))
    }

    /// Fixed-width indexes avoid directory enumerators' native child lists.
    private func eachKey(_ url: URL, until stop: () -> Bool = { false }, _ body: (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while !stop() {
            let key: String? = try pipelinePool {
                var bytes = Data()
                while bytes.count < 65 {
                    let chunk = try handle.read(upToCount: 65 - bytes.count) ?? Data()
                    if chunk.isEmpty {
                        if bytes.isEmpty {
                            return nil
                        }
                        throw PipelineError.scratchStorage
                    }
                    bytes.append(chunk)
                }
                guard bytes.last == 10 else { throw PipelineError.scratchStorage }
                return String(decoding: bytes.dropLast(), as: UTF8.self)
            }
            guard let key else { return }
            try pipelinePool { try body(key) }
        }
    }

    private func isTwin(_ note: Event, _ chat: Event) -> Bool {
        guard chat.source == .imessage || chat.source == .sms, MessagesApp.contains(chat.appID), !note.body.isEmpty, exactText(
            note.body,
            chat.body
        ), chat.sender != "me",
        abs(note.eventTime.timeIntervalSince(chat.eventTime)) <= tolerance else { return false }
        if let thread = note.threadID, !thread.isEmpty {
            return exactText(thread, chat.threadID)
        }
        let title = folded(note.title ?? "")
        if let group = groupName(chat) {
            return title == group
        }
        return !FileManager.default.fileExists(atPath: path("groups/" + hash(title)).path)
    }

    private func linkTwins() throws {
        guard hasNotes else { return }
        try eachKey(path("records.index")) { key in
            let chat = try load(key)
            guard chat.source == .imessage || chat.source == .sms else { return }
            try appendKey(key, to: path("bodies/" + hash(chat.body)))
        }
        try eachKey(path("notes.index")) { key in
            let note = try load(key)
            guard note.source == .notification, MessagesApp.contains(note.appID), !note.body.isEmpty else { return }
            var found: String?, ambiguous = false
            try eachKey(path("bodies/" + hash(note.body)), until: { ambiguous }) { candidate in
                guard try isTwin(note, load(candidate)) else { return }
                if found != nil {
                    ambiguous = true
                } else {
                    found = candidate
                }
            }
            if let found, !ambiguous {
                try appendKey(key, to: path("links/" + found))
                try write(Data(), path("suppressed/" + key))
            }
        }
    }

    private func canonical(_ key: String) throws -> Event {
        var event = try load(key)
        let links = path("links/" + key)
        if FileManager.default.fileExists(atPath: links.path) {
            var first: Event?
            try eachKey(links) { key in
                let note = try load(key)
                event.observations = try observationUnion([event.observations, note.observations])
                if first == nil || scalarLess(note.id, first?.id ?? "") {
                    first = note
                }
            }
            if event.title?.isEmpty != false {
                event.title = first?.title
            }
        }
        return event
    }

    func orderedEvents() throws -> (AnySequence<Event>, MergeRun) {
        try linkTwins()
        var buffer: [MergeIndex] = [], runs = 0
        func flush() throws {
            let url = path("runs/0-\(runs)")
            try register(url)
            let run = try MergeRun(url, create: true)
            defer { run.close() }
            for row in buffer.sorted(by: MergeIndex.less) {
                try run.append(row)
            }
            buffer.removeAll(keepingCapacity: true)
            runs += 1
        }
        try eachKey(path("records.index")) { key in
            guard !FileManager.default.fileExists(atPath: path("suppressed/" + key).path) else { return }
            let event = try load(key)
            buffer.append(MergeIndex(time: event.eventTime, id: event.id, key: key))
            if buffer.count == 256 {
                try flush()
            }
        }
        if !buffer.isEmpty || runs == 0 {
            try flush()
        }
        var round = 0
        while runs > 1 {
            var output = 0
            for index in stride(from: 0, to: runs, by: 2) {
                try pipelinePool {
                    let destination = path("runs/\(round + 1)-\(output)")
                    try register(destination)
                    if index + 1 == runs {
                        try FileManager.default.moveItem(at: path("runs/\(round)-\(index)"), to: destination)
                    } else {
                        try mergeRuns(path("runs/\(round)-\(index)"), path("runs/\(round)-\(index + 1)"), destination)
                    }
                }
                output += 1
            }
            runs = output
            round += 1
        }
        let sorted = try MergeRun(path("runs/\(round)-0"))
        let sequence = AnySequence<Event> {
            AnyIterator {
                do {
                    guard let row = try sorted.next() else { return nil }
                    return try pipelinePool { try self.canonical(row.key) }
                } catch {
                    self.failure = error
                    return nil
                }
            }
        }
        return (sequence, sorted)
    }

    private func mergeRuns(_ leftURL: URL, _ rightURL: URL, _ outputURL: URL) throws {
        let left = try MergeRun(leftURL), right = try MergeRun(rightURL), output = try MergeRun(outputURL, create: true)
        defer { left.close(); right.close(); output.close() }
        var lhs = try left.next(), rhs = try right.next()
        while lhs != nil || rhs != nil {
            if let value = lhs, rhs == nil || MergeIndex.less(value, rhs ?? value) {
                try output.append(value); lhs = try left.next()
            } else if let value = rhs {
                try output.append(value); rhs = try right.next()
            }
        }
        try FileManager.default.removeItem(at: leftURL)
        try FileManager.default.removeItem(at: rightURL)
    }
}

private struct MergeIndex: Codable {
    var time: Date
    var id: String
    var key: String
    static func less(_ lhs: MergeIndex, _ rhs: MergeIndex) -> Bool {
        lhs.time == rhs.time ? scalarLess(lhs.id, rhs.id) : lhs.time < rhs.time
    }
}

final class MergeRun {
    private let file: FileHandle
    init(_ url: URL, create: Bool = false) throws {
        if create, !FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw PipelineError.scratchStorage
        }
        file = try FileHandle(forUpdating: url)
    }

    func close() {
        try? file.close()
    }

    fileprivate func append(_ row: MergeIndex) throws {
        try pipelinePool {
            let data = try JSONEncoder().encode(row)
            var count = UInt64(data.count).bigEndian
            try file.write(contentsOf: withUnsafeBytes(of: &count) { Data($0) })
            try file.write(contentsOf: data)
        }
    }

    fileprivate func next() throws -> MergeIndex? {
        try pipelinePool {
            guard let header = try read(8) else { return nil }
            let count = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard count <= UInt64(Int.max), let data = try read(Int(count)) else { throw PipelineError.scratchStorage }
            return try JSONDecoder().decode(MergeIndex.self, from: data)
        }
    }

    private func read(_ count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            let chunk = try file.read(upToCount: count - result.count) ?? Data()
            if chunk.isEmpty {
                if result.isEmpty {
                    return nil
                }
                throw PipelineError.scratchStorage
            }
            result.append(chunk)
        }
        return result
    }
}
