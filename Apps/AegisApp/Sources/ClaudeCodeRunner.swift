import AegisKit
import Darwin
import Foundation
import OSLog

/// Claude Code with the owner's Claude plan (ADR-0038). It runs as its own launchd job, not as Aegis's child, so it
/// doesn't run as Aegis's code identity. The prompt goes in and the reply comes out through named pipes, read in
/// memory: no text reaches disk, and the job's plist holds only Aegis's own instructions. Logs carry codes only.
actor ClaudeCodeRunner {
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

    /// Stops the running job: launchd ends its whole process group.
    func cancel() {
        guard let label else { return }
        cancelled = true
        PlanRunner.launchctl(["bootout", PlanRunner.domain + "/" + label])
    }

    func run(
        system: String, prompt: String?, choice: ClaudeCode.Choice, timeout: Double, typed: @Sendable (String) -> Void
    ) async -> Ending {
        guard let executable else { return .unavailable }
        guard choice.isValid else { return .failed(-4) }
        guard label == nil else { return .busy }
        guard !Task.isCancelled else { return .cancelled }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-claude-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let pipes = Pipes(scratch: scratch) else { return .failed(-1) }
        defer { pipes.close() }
        let label = "dev.aegis.claude." + UUID().uuidString.lowercased()
        let plist = scratch.appendingPathComponent(label + ".plist")
        let job = Self.job(label: label, executable: executable, choice: choice, system: system, scratch: scratch)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: plist)) != nil
        else { return .failed(-1) }
        self.label = label
        cancelled = false
        defer {
            PlanRunner.launchctl(["bootout", PlanRunner.domain + "/" + label])
            self.label = nil
        }
        guard PlanRunner.launchctl(["bootstrap", PlanRunner.domain, plist.path]) == 0 else {
            log.notice("claude: bootstrap failed")
            return .unavailable
        }
        guard Self.write(ClaudeCode.handshake, to: pipes.writer) else { return .failed(-5) }
        return await pump(pipes, label: label, prompt: prompt, timeout: timeout, typed: typed)
    }

    /// The job's plist: only Aegis's own instructions, never the prompt.
    private static func job(label: String, executable: String, choice: ClaudeCode.Choice, system: String, scratch: URL) -> [String: Any] {
        let language = "\(Locale.current.language.languageCode?.identifier ?? "en")_\(Locale.current.region?.identifier ?? "US").UTF-8"
        return [
            "Label": label,
            "ProgramArguments": ClaudeCode.arguments(executable: executable, choice: choice, system: system),
            "WorkingDirectory": scratch.appendingPathComponent("work").path,
            "EnvironmentVariables": ClaudeCode.environment(
                home: NSHomeDirectory(), user: NSUserName(), temporary: scratch.appendingPathComponent("tmp").path, language: language
            ),
            "StandardInPath": scratch.appendingPathComponent("in").path,
            "StandardOutPath": scratch.appendingPathComponent("out").path,
            "StandardErrorPath": "/dev/null",
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
    }

    /// Reads the job's output until it ends, sending the prompt once the handshake passes.
    private func pump(
        _ pipes: Pipes, label: String, prompt: String?, timeout: Double, typed: @Sendable (String) -> Void
    ) async -> Ending {
        var session = ClaudeCode.Session()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let began = Date()
        var checked = Date()
        var seenRunning = false
        while true {
            let count = read(pipes.reader, &buffer, buffer.count)
            if count > 0 {
                for event in session.feed(Data(buffer[0 ..< count])) {
                    if let ending = Self.handle(event, pipes: pipes, prompt: prompt, typed: typed) {
                        return ending
                    }
                }
                continue
            }
            if cancelled || Task.isCancelled {
                return .cancelled
            }
            if Date().timeIntervalSince(began) > timeout {
                return .timedOut
            }
            // Only when the pipe is empty: a job that has ended with nothing more to read has failed.
            if Date().timeIntervalSince(checked) > 1 {
                checked = Date()
                switch PlanRunner.state(of: label) {
                case .running: seenRunning = true
                case .pending: break
                case .gone: return .failed(-2)
                case let .finished(status) where seenRunning || status != 0: return .failed(Int(status))
                case .finished: break
                }
            }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return .cancelled }
        }
    }

    private static func handle(
        _ event: ClaudeCode.Session.Event, pipes: Pipes, prompt: String?, typed: @Sendable (String) -> Void
    ) -> Ending? {
        switch event {
        case let .ready(models):
            remember(models: models, signedIn: true)
            guard let prompt else { return .ready(models) }
            guard write(ClaudeCode.prompt(prompt), to: pipes.writer) else { return .failed(-5) }
            // End of input: Claude Code finishes this turn and exits.
            pipes.endInput()
            return nil
        case let .text(piece):
            typed(piece)
            return nil
        case let .finished(outcome):
            switch outcome {
            case .signedOut, .refused: remember(models: models, signedIn: false)
            default: break
            }
            return .outcome(outcome)
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
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
    private(set) var writer: Int32

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
        writer = open(input, O_RDWR)
        guard reader >= 0, writer >= 0 else {
            close()
            return nil
        }
    }

    func endInput() {
        if writer >= 0 {
            Darwin.close(writer)
        }
        writer = -1
    }

    func close() {
        endInput()
        if reader >= 0 {
            Darwin.close(reader)
        }
    }
}
