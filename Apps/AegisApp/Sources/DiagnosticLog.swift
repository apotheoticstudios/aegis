import AegisKit
import CryptoKit
import Darwin
import Foundation
import OSLog

/// Private, bounded diagnostics. The API cannot accept transcripts, paths, exception text or payloads.
final class DiagnosticLog: @unchecked Sendable {
    enum Code: String, Codable, CaseIterable, Sendable {
        case appStarted, appStopped, previousExitUnclean, uncaughtException, registrationFailed
        case wakeAcknowledged, captureStarted, captureEnded, captureTimedOut, acknowledgementTimedOut
        case permissionDenied, wakeModelMissing, microphoneFailed, microphoneFormat, echoUnavailable
        case speechReady, speechInputFormat, speechSetupFailed, speechResultFailed, speechFinalizeFailed
        case speechConversionFailed, transcriptEmpty, legacyRetry, legacyUnavailable
        case synthesisFailed, playbackFailed, coreRefused, coreUnavailable, coreTimedOut, coreStoreFailed
        case questionSubmitted, answerReady, modelInvalidDraft, modelUnknownCitation, modelUnsafeText, questionTooLong, coreBusy
        case cloudFailed, planFailed, sourceUnhealthy, unexpectedReply
    }

    struct Record: Codable {
        let schema: Int
        let code: Code
        let firstAt: Date
        var lastAt: Date
        var count: Int
        var number: Int?
        var detail: Int?
        let build: String
        let pid: Int32
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aegis", isDirectory: true)
    static let shared = DiagnosticLog(
        directory: directory,
        enabled: NSClassFromString("XCTestCase") == nil
            && !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") })
    )

    let directory: URL
    var isEnabled: Bool {
        enabled
    }

    private let enabled: Bool
    private let limit: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.aegis.diagnostics", qos: .utility)
    private var pending: [Code: Record] = [:]
    private var scheduled = false
    private let build: String
    private let system = Logger(subsystem: "dev.aegis.app", category: "diagnostics")

    init(directory: URL, enabled: Bool = true, limit: Int = 2 * 1024 * 1024) {
        self.directory = directory
        self.enabled = enabled
        self.limit = max(1024, limit)
        build = Bundle.main.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            .map { CryptoKit.SHA256.hash(data: $0).prefix(8).map { String(format: "%02x", $0) }.joined() } ?? "unavailable"
    }

    /// Repeated codes are counted in a bounded batch. Numeric details only, never NSError.userInfo.
    func record(_ code: Code, number: Int? = nil, detail: Int? = nil) {
        guard enabled else { return }
        system.notice("diagnostic: \(code.rawValue, privacy: .public), number \(number ?? 0, privacy: .public)")
        let shouldSchedule = lock.withLock {
            let now = Date()
            var row = pending[code] ?? Record(
                schema: 1, code: code, firstAt: now, lastAt: now, count: 0, number: nil, detail: nil, build: build, pid: getpid()
            )
            row.lastAt = now
            row.count = min(row.count, Int.max - 1) + 1
            row.number = number
            row.detail = detail
            pending[code] = row
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + 0.1) { self.drain() }
        }
    }

    func flush() {
        guard enabled else { return }
        queue.sync { drain() }
    }

    /// A marker detects unclean exit on the next launch without reading system crash-report contents.
    func startSession() {
        guard enabled else { return }
        queue.sync {
            do {
                try prepareDirectory()
                let marker = directory.appendingPathComponent("session.pid")
                if let old = markerPID(), old > 0, kill(old, 0) != 0 {
                    record(.previousExitUnclean)
                }
                try Data(String(getpid()).utf8).write(to: marker, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            } catch { writeFailed(error) }
        }
        record(.appStarted)
    }

    func stopSession() {
        guard enabled else { return }
        record(.appStopped)
        flush()
        queue.sync {
            let marker = directory.appendingPathComponent("session.pid")
            if markerPID() == getpid() {
                do { try FileManager.default.removeItem(at: marker) } catch { writeFailed(error) }
            }
        }
    }

    private func markerPID() -> Int32? {
        let marker = directory.appendingPathComponent("session.pid")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? 32) < 32,
              let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return Int32(text)
    }

    private func prepareDirectory() throws {
        let files = FileManager.default
        if files.fileExists(atPath: directory.path) {
            guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func drain() {
        let rows = lock.withLock {
            let rows = pending.values.sorted { $0.firstAt < $1.firstAt }
            pending = [:]
            scheduled = false
            return rows
        }
        guard !rows.isEmpty else { return }
        do {
            try prepareDirectory()
            let files = FileManager.default
            let active = directory.appendingPathComponent("diagnostics.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            for row in rows {
                var data = try encoder.encode(row)
                data.append(10)
                if let attributes = try? files.attributesOfItem(atPath: active.path) {
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteInvalidFileName) }
                    if (attributes[.size] as? Int ?? 0) + data.count > limit {
                        for index in stride(from: 3, through: 1, by: -1) {
                            let old = directory.appendingPathComponent("diagnostics.\(index).jsonl")
                            if files.fileExists(atPath: old.path) {
                                try files.removeItem(at: old)
                            }
                            let previous = index == 1 ? active : directory.appendingPathComponent("diagnostics.\(index - 1).jsonl")
                            if files.fileExists(atPath: previous.path) {
                                try files.moveItem(at: previous, to: old)
                            }
                        }
                    }
                }
                if !files.fileExists(atPath: active.path) {
                    guard files.createFile(atPath: active.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: active.path)
                let handle = try FileHandle(forWritingTo: active)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch { writeFailed(error) }
    }

    private func writeFailed(_ error: any Error) {
        system.error("diagnostics write failed: \((error as NSError).code, privacy: .public)")
    }
}

/// Covers technical failures returned by all Core/model/collector requests without copying payloads.
struct DiagnosticCoreService: CoreService {
    let base: any CoreService
    var log = DiagnosticLog.shared

    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case .ask, .converse, .prep: log.record(.questionSubmitted)
        default: break
        }
        let response = await base.handle(request)
        if case .answer = response {
            log.record(.answerReady)
        }
        if case let .status(status) = response {
            let failures = status.sources.filter { !$0.readable }.count
            if failures > 0 {
                log.record(.sourceUnhealthy, number: failures)
            }
        }
        if case let .refused(code) = response {
            let diagnostic: DiagnosticLog.Code? = switch code {
            case "cancelled", "no_match", "ambiguous", "not_a_rule", "not_a_command", "no_intent": nil
            case "unreachable", "unavailable": .coreUnavailable
            case "timedOut", "timed_out": .coreTimedOut
            case "store_unavailable": .coreStoreFailed
            case "invalid_draft": .modelInvalidDraft
            case "unknown_citation": .modelUnknownCitation
            case "unsafe_text": .modelUnsafeText
            case "too_long": .questionTooLong
            case "busy", "already_generating": .coreBusy
            default: .coreRefused
            }
            if let diagnostic {
                log.record(diagnostic)
            }
        }
        return response
    }
}
