import AegisKit
import Darwin
import Foundation
import OSLog

/// Claude Code with the owner's Claude plan (ADR-0038). It runs as its own launchd job, not as Aegis's child, so it
/// doesn't run as Aegis's code identity. The prompt goes in and the reply comes out through named pipes, read in
/// memory: no text reaches disk, and the job's plist holds only Aegis's own instructions. Logs carry codes only.
/// With `reads`, Aegis serves its read tools to Claude over the same pipes (ADR-0038 §5): no connector process.
actor ClaudeCodeRunner {
    /// Where Claude's read tools get their data, and which categories the owner has left on.
    struct Reads: Sendable {
        let source: any ClaudeToolSource
        let enabled: Set<ClaudeTools.Category>
        /// Claude may also ask Aegis to act (ADR-0038 stage 3): one action, or one plan card, per run.
        var acts = false
    }

    /// How a run ended. A run without a prompt (`check`) ends at `ready`.
    enum Ending: Equatable, Sendable {
        case ready([ClaudeCode.Model])
        case outcome(ClaudeCode.Outcome)
        case unavailable, busy, timedOut, cancelled
        case failed(Int)
    }

    /// Where Claude Code's installers put it.
    static var executable: String? {
        let home = NSHomeDirectory()
        return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let choiceKey = "claudeCodeChoice"
    private static let modelsKey = "claudeCodeModels"
    private static let signedInKey = "claudeCodeSignedIn"

    /// The owner's model and effort.
    static var choice: ClaudeCode.Choice {
        get {
            UserDefaults.aegis.data(forKey: choiceKey).flatMap { try? JSONDecoder().decode(ClaudeCode.Choice.self, from: $0) }
                .flatMap { $0.isValid ? $0 : nil } ?? .standard
        }
        set { UserDefaults.aegis.set(try? JSONEncoder().encode(newValue), forKey: choiceKey) }
    }

    /// The models Claude Code last listed, kept for when it can't be asked.
    static var models: [ClaudeCode.Model] {
        UserDefaults.aegis.data(forKey: modelsKey).flatMap { try? JSONDecoder().decode([ClaudeCode.Model].self, from: $0) } ?? []
    }

    /// The last handshake found Claude Code signed in with no API key, provider switch or extra configuration.
    static var signedIn: Bool {
        UserDefaults.aegis.bool(forKey: signedInKey)
    }

    private let executable: String?
    private var label: String?
    /// The job number the running job was started for.
    private var runToken = 0
    /// Items the last run sent Claude, by category: counts only.
    private(set) var lastReads: [ClaudeTools.Category: Int] = [:]
    /// Action calls the last run accepted: a run that acted is never replayed on another brain (ADR-0038 §2).
    private(set) var lastActions = 0
    /// The items the last run sent Claude in full, for the answer's sources.
    private(set) var lastReadIDs: [String] = []
    private var cancelled = false
    private let log = Logger(subsystem: "dev.aegis.app", category: "claude")

    /// `executable`: Claude Code, or a stand-in in tests.
    init(executable: String? = ClaudeCodeRunner.executable) {
        self.executable = executable
    }

    /// The handshake alone: whether Claude Code is signed in and set up as Aegis needs, and the models on offer.
    func check() async -> Ending {
        await run(system: "Aegis setup check.", prompt: nil, choice: Self.choice, timeout: 30) { _ in }
    }

    /// Stops the running job: launchd ends its whole process group. With `below`, only a job started for an
    /// older job number than it, so a stop sent for the last job can't end the one that replaced it.
    func cancel(below token: Int? = nil) {
        guard let label, token.map({ runToken < $0 }) ?? true else { return }
        cancelled = true
        PlanRunner.launchctl(["bootout", PlanRunner.domain + "/" + label])
    }

    /// One run's own result: how it ended, the actions it accepted and the items it sent in full. Never another
    /// run's, as the "last run" properties may be by the time a caller reads them.
    struct Report: Sendable {
        let ending: Ending
        var actions = 0
        var readIDs: [String] = []
    }

    func run(
        system: String, prompt: String?, choice: ClaudeCode.Choice, timeout: Double, reads: Reads? = nil,
        typed: @Sendable (String) -> Void
    ) async -> Ending {
        await report(system: system, prompt: prompt, choice: choice, timeout: timeout, reads: reads, typed: typed).ending
    }

    func report(
        system: String, prompt: String?, choice: ClaudeCode.Choice, timeout: Double, reads: Reads? = nil, token: Int = 0,
        typed: @Sendable (String) -> Void
    ) async -> Report {
        guard let executable else { return Report(ending: .unavailable) }
        guard choice.isValid else { return Report(ending: .failed(-4)) }
        guard label == nil else { return Report(ending: .busy) }
        guard !Task.isCancelled else { return Report(ending: .cancelled) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-claude-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let pipes = Pipes(scratch: scratch) else { return Report(ending: .failed(-1)) }
        defer { pipes.close() }
        let label = "dev.aegis.claude." + UUID().uuidString.lowercased()
        let plist = scratch.appendingPathComponent(label + ".plist")
        let server = reads.map { ClaudeTools.Server(enabled: $0.enabled, acts: $0.acts) }.flatMap { $0.toolNames.isEmpty ? nil : $0 }
        let tools = server?.toolNames ?? []
        let job = Self.job(label: label, executable: executable, choice: choice, system: system, tools: tools, scratch: scratch)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: plist)) != nil
        else { return Report(ending: .failed(-1)) }
        self.label = label
        runToken = token
        cancelled = false
        lastReads = [:]
        lastActions = 0
        lastReadIDs = []
        defer {
            PlanRunner.launchctl(["bootout", PlanRunner.domain + "/" + label])
            self.label = nil
        }
        guard PlanRunner.launchctl(["bootstrap", PlanRunner.domain, plist.path]) == 0 else {
            log.notice("claude: bootstrap failed")
            return Report(ending: .unavailable)
        }
        let deadline = Date().addingTimeInterval(timeout)
        if let failed = await send(ClaudeCode.handshake(served: server != nil), to: pipes, until: deadline) {
            return Report(ending: failed)
        }
        var session = ClaudeCode.Session(servers: server == nil ? [] : [ClaudeTools.server], tools: Set(tools))
        var link = Link(pipes: pipes, label: label, deadline: deadline, server: server, source: reads?.source)
        let ending = await pump(&link, &session, prompt: prompt, typed: typed)
        record(link.server)
        return Report(ending: ending, actions: link.server?.actions ?? 0, readIDs: link.server?.readIDs ?? [])
    }

    /// The job's plist: only Aegis's own instructions, never the prompt.
    private static func job(
        label: String, executable: String, choice: ClaudeCode.Choice, system: String, tools: [String], scratch: URL
    ) -> [String: Any] {
        let language = "\(Locale.current.language.languageCode?.identifier ?? "en")_\(Locale.current.region?.identifier ?? "US").UTF-8"
        return [
            "Label": label,
            "ProgramArguments": ClaudeCode.command(
                executable: executable, choice: choice, system: system, tools: tools,
                environment: ClaudeCode.environment(
                    home: NSHomeDirectory(), user: NSUserName(), temporary: scratch.appendingPathComponent("tmp").path, language: language
                )
            ),
            "WorkingDirectory": scratch.appendingPathComponent("work").path,
            "StandardInPath": scratch.appendingPathComponent("in").path,
            "StandardOutPath": scratch.appendingPathComponent("out").path,
            "StandardErrorPath": "/dev/null",
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
    }

    /// One run's pipes, job, deadline and read tools.
    private struct Link {
        let pipes: Pipes
        let label: String
        let deadline: Date
        var server: ClaudeTools.Server?
        let source: (any ClaudeToolSource)?
    }

    /// Reads the job's output until it ends, sending the prompt once the handshake passes and answering Claude's
    /// tool calls. Stop and the deadline are checked before every read, so nothing is sent after either. Input stays
    /// open for the tools' answers; the run ends with Claude Code's result.
    private func pump(
        _ link: inout Link, _ session: inout ClaudeCode.Session, prompt: String?, typed: @Sendable (String) -> Void
    ) async -> Ending {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let began = Date()
        var checked = Date()
        var seenRunning = false
        while true {
            if let stopped = stopped(link.deadline) {
                return stopped
            }
            let count = read(link.pipes.reader, &buffer, buffer.count)
            if count > 0 {
                for event in session.feed(Data(buffer[0 ..< count])) {
                    if let ending = await handle(event, &link, prompt: prompt, typed: typed) {
                        return ending
                    }
                }
                await Task.yield()
                continue
            }
            if Date().timeIntervalSince(checked) > 1 {
                checked = Date()
                if let ended = Self.ended(link.label, since: began, seenRunning: &seenRunning) {
                    return ended
                }
            }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return .cancelled }
        }
    }

    private func handle(
        _ event: ClaudeCode.Session.Event, _ link: inout Link, prompt: String?, typed: @Sendable (String) -> Void
    ) async -> Ending? {
        switch event {
        case let .ready(models):
            Self.remember(models: models, signedIn: true)
            guard let prompt else { return .ready(models) }
            return await send(ClaudeCode.prompt(prompt), to: link.pipes, until: link.deadline)
        case let .text(piece):
            typed(piece)
            return nil
        case let .mcp(requestID, message):
            guard var server = link.server, let source = link.source else {
                return await send(ClaudeCode.controlError(requestID: requestID), to: link.pipes, until: link.deadline)
            }
            let reply: ClaudeTools.Server.Reply
            let step = server.handle(message)
            // Kept at once: an accepted action counts even if its run stops before it answers (ADR-0038 §2).
            link.server = server
            switch step {
            case let .reply(message):
                reply = .init(message: message, counts: [:])
            case let .call(id, call):
                guard let payload = await fetch(call, from: source, enabled: server.enabled, until: link.deadline) else {
                    return stopped(link.deadline) ?? .cancelled
                }
                reply = server.result(id: id, payload)
            }
            if let failed = await send(ClaudeCode.mcpResponse(requestID: requestID, reply.message), to: link.pipes, until: link.deadline) {
                link.server = server
                return failed
            }
            server.sent(reply)
            link.server = server
            return nil
        case let .denied(requestID):
            return await send(ClaudeCode.controlError(requestID: requestID), to: link.pipes, until: link.deadline)
        case let .finished(outcome):
            switch outcome {
            case .signedOut, .refused: Self.remember(models: [], signedIn: false)
            default: break
            }
            return .outcome(outcome)
        }
    }

    /// A tool's data, or nil once Stop or the deadline comes first: a fetch that never returns can't hold the run.
    /// Claude Code may cancel a tool request it no longer needs; its late answer is dropped by Claude Code, and the
    /// fetch is bounded by the run's deadline.
    private func fetch(
        _ call: ClaudeTools.Call, from source: any ClaudeToolSource, enabled: Set<ClaudeTools.Category>, until deadline: Date
    ) async -> ClaudeTools.Payload? {
        let box = PayloadBox()
        let work = Task { await box.set(source.fetch(call, enabled: enabled)) }
        defer { work.cancel() }
        while stopped(deadline) == nil {
            if let payload = await box.value {
                return payload
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
        }
        return nil
    }

    /// The read log: what the run sent Claude, as counts by category, never content.
    private func record(_ server: ClaudeTools.Server?) {
        lastReads = server?.counts ?? [:]
        lastActions = server?.actions ?? 0
        lastReadIDs = server?.readIDs ?? []
        for (category, count) in lastReads {
            DiagnosticLog.shared.record(.claudeRead, number: count, detail: ClaudeTools.Category.allCases.firstIndex(of: category))
        }
    }

    private func stopped(_ deadline: Date) -> Ending? {
        if cancelled || Task.isCancelled {
            return .cancelled
        }
        return Date() > deadline ? .timedOut : nil
    }

    /// Polled only while the output pipe is empty: a job that has ended with nothing left to read has failed. launchd
    /// can report a zero exit before a job's first launch, so a zero from a job never seen running counts after 3 s.
    private static func ended(_ label: String, since began: Date, seenRunning: inout Bool) -> Ending? {
        switch PlanRunner.state(of: label) {
        case .running:
            seenRunning = true
            return nil
        case .pending:
            return nil
        case .gone:
            return .failed(-2)
        case let .finished(status):
            return seenRunning || status != 0 || Date().timeIntervalSince(began) > 3 ? .failed(Int(status)) : nil
        }
    }

    /// Writes without ever blocking: a job that stops reading can't hold the runner past Stop or the deadline.
    private func send(_ data: Data, to pipes: Pipes, until deadline: Date) async -> Ending? {
        var offset = 0
        while offset < data.count {
            if let stopped = stopped(deadline) {
                return stopped
            }
            let written = data.withUnsafeBytes { bytes in
                bytes.baseAddress.map { Darwin.write(pipes.writer, $0 + offset, bytes.count - offset) } ?? 0
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return .cancelled }
            } else {
                return .failed(-5)
            }
        }
        return nil
    }

    private static func remember(models: [ClaudeCode.Model], signedIn: Bool) {
        if !models.isEmpty {
            UserDefaults.aegis.set(try? JSONEncoder().encode(models), forKey: modelsKey)
        }
        UserDefaults.aegis.set(signedIn, forKey: signedInKey)
    }
}

/// The job's input and output: named pipes in the private scratch folder. Aegis holds both ends of each, so opening
/// never waits for the job and nothing written is lost before the job opens its end.
private final class Pipes {
    let reader: Int32
    let writer: Int32

    init?(scratch: URL) {
        let files = FileManager.default
        do {
            for folder in [scratch, scratch.appendingPathComponent("work"), scratch.appendingPathComponent("tmp")] {
                try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            return nil
        }
        let input = scratch.appendingPathComponent("in").path
        let output = scratch.appendingPathComponent("out").path
        guard mkfifo(input, 0o600) == 0, mkfifo(output, 0o600) == 0 else { return nil }
        reader = open(output, O_RDWR | O_NONBLOCK)
        writer = open(input, O_RDWR | O_NONBLOCK)
        guard reader >= 0, writer >= 0 else {
            close()
            return nil
        }
    }

    func close() {
        if writer >= 0 {
            Darwin.close(writer)
        }
        if reader >= 0 {
            Darwin.close(reader)
        }
    }
}

/// Answers Claude's read tools: the app fetches from AegisCore, and `ClaudeTools` decides what may go.
protocol ClaudeToolSource: Sendable {
    func fetch(_ call: ClaudeTools.Call, enabled: Set<ClaudeTools.Category>) async -> ClaudeTools.Payload
}

private actor PayloadBox {
    private(set) var value: ClaudeTools.Payload?

    func set(_ payload: ClaudeTools.Payload) {
        value = payload
    }
}
