import Foundation

/// Length-framed records avoid loading the spool into RAM, even for a single-use Sequence.
final class InputScratch {
    let folder: URL
    let file: FileHandle
    private var replies: FileHandle?

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let path = folder.appendingPathComponent("rows").path
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PipelineError.scratchStorage
            }
            file = try FileHandle(forUpdating: URL(fileURLWithPath: path))
            let index = folder.appendingPathComponent("reply-keys")
            guard FileManager.default.createFile(atPath: index.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PipelineError.scratchStorage
            }
            replies = try FileHandle(forUpdating: index)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func remove() {
        try? file.close()
        if let replies {
            try? replies.seek(toOffset: 0)
            while true {
                let key: String?
                do {
                    key = try pipelinePool {
                        guard let bytes = try read(65, from: replies) else { return nil }
                        return String(decoding: bytes.dropLast(), as: UTF8.self)
                    }
                } catch { break }
                guard let key else { break }
                pipelinePool { try? FileManager.default.removeItem(at: folder.appendingPathComponent(key)) }
            }
            try? replies.close()
        }
        try? FileManager.default.removeItem(at: folder)
    }

    func append(_ row: InputRow) throws {
        try pipelinePool {
            let data = try JSONEncoder().encode(row)
            var size = UInt64(data.count).bigEndian
            try file.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
            try file.write(contentsOf: data)
        }
    }

    func rewind() throws {
        try file.seek(toOffset: 0)
    }

    func next() throws -> InputRow? {
        try pipelinePool {
            guard let header = try read(8, from: file) else { return nil }
            let size = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard size <= UInt64(Int.max), let data = try read(Int(size), from: file) else { throw PipelineError.scratchStorage }
            return try JSONDecoder().decode(InputRow.self, from: data)
        }
    }

    private func read(_ size: Int, from handle: FileHandle) throws -> Data? {
        var result = Data()
        while result.count < size {
            let chunk = try handle.read(upToCount: size - result.count) ?? Data()
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

    func replyTime(thread: String) throws -> Date? {
        let path = folder.appendingPathComponent(thread)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let date = try ContractTime.parse(String(contentsOf: path, encoding: .utf8)) else { throw PipelineError.scratchStorage }
        return date
    }

    func noteReply(thread: String, time: Date) throws {
        if let previous = try replyTime(thread: thread), previous >= time {
            return
        }
        let path = folder.appendingPathComponent(thread).path
        if !FileManager.default.fileExists(atPath: path) {
            guard let replies else { throw PipelineError.scratchStorage }
            try replies.seekToEnd()
            try replies.write(contentsOf: Data((thread + "\n").utf8))
        }
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(ContractTime.format(time).utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PipelineError.scratchStorage
        }
    }
}
