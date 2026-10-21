import AegisKit
import Foundation
import OSLog

/// The owner's ChatGPT plan through the Codex app inside ChatGPT.app (#235, ADR-0017): questions run read-only
/// in an empty temporary folder; tasks may write only inside their own folder. Codex runs as its own launchd job,
/// not as Aegis's child, so it doesn't inherit Aegis's privacy permissions. Only what AegisCore's gate
/// approved goes in, no session is saved, and the transcript is deleted at once. Logs carry codes only.
actor PlanRunner {
    enum Failure: Error, Sendable {
        case unavailable, busy, limit(String?), timedOut, cancelled, failed(Int32)

        func message(_ provider: CloudHandOff.Provider) -> String {
            let name = provider.name
            return switch self {
            case .unavailable: "I can't find the \(name) app's command-line tool on this Mac."
            case .busy: "\(name) is still working on the last one."
            case let .limit(until):
                "Your \(name) plan's limit is used up" + (until.map { " until \($0)" } ?? " for now")
                    + ". An API key under Claude and ChatGPT in Aegis's menu would keep it working."
            case .timedOut: "\(name) took too long, so I stopped it."
            case .cancelled: "Stopped."
            case .failed: "\(name) didn't finish that. Could you try again?"
            }
        }
    }

    /// Where the ChatGPT app keeps its Codex tool.
    static var codex: String? {
        ["/Applications", NSHomeDirectory() + "/Applications"]
            .map { $0 + "/ChatGPT.app/Contents/Resources/codex-cli/bin/codex" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where tasks make their files: a folder of their own in Aegis Tasks, in the owner's home folder.
    static var tasksFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Aegis Tasks", isDirectory: true)
    }

    /// A fresh private folder: existing folders and symlinks must never be reused for a task.
    static func createTaskFolder(_ folder: URL, base: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL,
              try (FileManager.default.attributesOfItem(atPath: base.path))[.type] as? FileAttributeType == .typeDirectory,
              mkdir(folder.path, 0o700) == 0, validFolder(folder, base: base)
        else { throw CocoaError(.fileWriteFileExists) }
    }

    /// The running job, so Stop can end it.
    private final class Run {
        let label: String
        var cancelled = false

        init(label: String) {
            self.label = label
        }
    }

    private var current: Run?
    private let log = Logger(subsystem: "dev.aegis.app", category: "plan")

    /// A question: read-only, in a new empty folder that's removed afterwards.
    func answer(_ request: CloudHandOff.Request) async -> Result<String, Failure> {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-ask-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            DiagnosticLog.shared.record(.planFailed, number: (error as NSError).code)
            return .failure(.failed(-1))
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        return await run(request, in: folder, sandbox: "read-only", effort: "low", timeout: 180)
    }

    /// A task: it may write only inside `folder`, which must be a real folder inside `base`.
    func task(_ request: CloudHandOff.Request, in folder: URL, base: URL) async -> Result<String, Failure> {
        guard Self.validFolder(folder, base: base) else {
            DiagnosticLog.shared.record(.planFailed, number: -3)
            return .failure(.failed(-3))
        }
        return await run(request, in: folder.resolvingSymlinksInPath(), sandbox: "workspace-write", effort: "medium", timeout: 20 * 60)
    }

    static func validFolder(_ folder: URL, base: URL) -> Bool {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let kind = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType
        let baseKind = (try? FileManager.default.attributesOfItem(atPath: base.path))?[.type] as? FileAttributeType
        return real.hasPrefix(root) && kind == .typeDirectory && baseKind == .typeDirectory
            && folder.standardizedFileURL.path == real
    }

    /// Stops the running question or task: launchd ends its whole process group.
    func cancel() {
        guard let current else { return }
        current.cancelled = true
        _ = Self.launchctl(["bootout", Self.domain + "/" + current.label])
    }

    /// Runs Codex as its own launchd job rather than a child of Aegis, so it doesn't inherit Aegis's privacy
    /// permissions (DeepSeek's review), with a fresh home and temporary folder; only its sign-in comes from ~/.codex.
    private func run(
        _ request: CloudHandOff.Request, in folder: URL, sandbox: String, effort: String, timeout: Double
    ) async -> Result<String, Failure> {
        let result = await execute(request, in: folder, sandbox: sandbox, effort: effort, timeout: timeout)
        if case let .failure(failure) = result {
            if case let .failed(number) = failure {
                DiagnosticLog.shared.record(.planFailed, number: Int(number))
            } else if case .cancelled = failure {} else {
                DiagnosticLog.shared.record(.planFailed)
            }
        }
        return result
    }

    private func execute(
        _ request: CloudHandOff.Request, in folder: URL, sandbox: String, effort: String, timeout: Double
    ) async -> Result<String, Failure> {
        guard let codex = Self.codex else { return .failure(.unavailable) }
        guard current == nil else { return .failure(.busy) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("aegis-plan-" + UUID().uuidString, isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
        for path in [scratch, home, temporary] {
            do {
                try files.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch {
                try? files.removeItem(at: scratch)
                return .failure(.failed(-1))
            }
        }
        defer { try? files.removeItem(at: scratch) }
        let reply = scratch.appendingPathComponent("reply.txt")
        let transcript = scratch.appendingPathComponent("transcript.log")
        let label = "dev.aegis.plan." + UUID().uuidString.lowercased()
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": Self.arguments(
                codex: codex,
                request: request,
                folder: folder,
                reply: reply,
                sandbox: sandbox,
                effort: effort
            ),
            "WorkingDirectory": folder.path,
            "EnvironmentVariables": [
                "HOME": home.path, "CODEX_HOME": NSHomeDirectory() + "/.codex", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "\(Locale.current.language.languageCode?.identifier ?? "en")_\(Locale.current.region?.identifier ?? "US").UTF-8",
                "TMPDIR": temporary.path,
            ],
            "StandardOutPath": transcript.path,
            "StandardErrorPath": transcript.path,
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let plist = scratch.appendingPathComponent(label + ".plist")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: plist)) != nil
        else { return .failure(.failed(-1)) }
        let run = Run(label: label)
        current = run
        defer {
            _ = Self.launchctl(["bootout", Self.domain + "/" + label])
            current = nil
        }
        guard Self.launchctl(["bootstrap", Self.domain, plist.path]) == 0 else {
            log.notice("plan: bootstrap failed")
            return .failure(.unavailable)
        }
        let began = Date()
        var exitCode: Int32 = -2
        var seenRunning = false
        while true {
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return .failure(.cancelled) }
            if run.cancelled || Task.isCancelled {
                return .failure(.cancelled)
            }
            if Date().timeIntervalSince(began) > timeout {
                return .failure(.timedOut)
            }
            switch Self.state(of: label) {
            case .running:
                seenRunning = true
                continue
            case .pending:
                continue
            case .gone:
                return .failure(.failed(-2))
            case let .finished(status):
                // Some launchd versions report zero even before the first launch.
                if status == 0, !seenRunning, !files.fileExists(atPath: reply.path) {
                    continue
                }
                exitCode = status
            }
            break
        }
        let tail = (try? String(contentsOf: transcript, encoding: .utf8)).map { String($0.suffix(4000)) } ?? ""
        if tail.localizedCaseInsensitiveContains("usage limit") {
            log.notice("plan: usage limit")
            return .failure(.limit(Self.retryTime(tail)))
        }
        guard exitCode == 0 else { return .failure(.failed(exitCode)) }
        guard let text = try? String(contentsOf: reply, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            log.notice("plan: no reply")
            return .failure(.failed(-2))
        }
        return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    enum JobState: Equatable {
        case running, pending, finished(Int32), gone
    }

    static func arguments(
        codex: String, request: CloudHandOff.Request, folder: URL, reply: URL, sandbox: String, effort: String
    ) -> [String] {
        [
            codex, "--no-daemon", "-a", "never", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
            "--color", "never", "-s", sandbox, "-C", folder.path, "-c", "model_reasoning_effort=\"\(effort)\"",
            "-c", "project_doc_max_bytes=0", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
            "-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-o", reply.path, "--", CloudHandOff.planPrompt(request),
        ]
    }

    private static var domain: String {
        "gui/\(getuid())"
    }

    /// Running while launchd lists a PID for the job.
    private static func state(of label: String) -> JobState {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .gone }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .gone }
        return state(from: String(decoding: data, as: UTF8.self))
    }

    /// A loaded job with neither a PID nor an exit status has not run yet.
    static func state(from output: String) -> JobState {
        if let range = output.range(of: #""PID"\s*=\s*\d+"#, options: .regularExpression),
           let pid = Int(output[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""), pid > 0
        {
            return .running
        }
        if let range = output.range(of: #""LastExitStatus"\s*=\s*-?\d+"#, options: .regularExpression),
           let status = Int32(output[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        {
            return .finished(status)
        }
        return .pending
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// "try again at 7:26 PM" → "7:26 PM".
    static func retryTime(_ text: String) -> String? {
        guard let range = text.range(of: #"try again at [0-9:]+\s?(?:AM|PM|am|pm)?"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("try again at ".count)).trimmingCharacters(in: .whitespaces)
    }
}
