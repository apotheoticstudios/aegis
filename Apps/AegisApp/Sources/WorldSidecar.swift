import Foundation
import OSLog

/// God's Eye View's local server for the World view (#265, ADR-0024): started only while the World view is open,
/// on 127.0.0.1, as its own launchd job (so it doesn't inherit Aegis's privacy permissions), and stopped when the
/// window closes or Aegis quits. It fetches public data only; nothing personal is given to it.
@MainActor
final class WorldSidecar {
    enum Problem: Error {
        case setupFailed(String), noNode, failedToStart
    }

    nonisolated static let label = "dev.aegis.world"
    /// Where `scripts/world-setup.sh` installs the pinned God's Eye View.
    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aegis/World", isDirectory: true)
    }

    /// The app tests run inside Aegis itself: they must never start or stop the owner's real server.
    nonisolated static let isTestHost = NSClassFromString("XCTestCase") != nil

    private(set) var address: URL?
    private let log = Logger(subsystem: "dev.aegis.app", category: "world")

    /// The setup script bundled with Aegis, and the God's Eye View commit it pins.
    private static var setupScript: URL? {
        Bundle.main.url(forResource: "world-setup", withExtension: "sh", subdirectory: "World")
    }

    private static var pinnedCommit: String? {
        guard let script = setupScript, let text = try? String(contentsOf: script, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("commit=") })
        else { return nil }
        return String(line.dropFirst("commit=".count))
    }

    /// Set up at the commit this Aegis pins, with its own Node.
    static var isInstalled: Bool {
        let app = folder.appendingPathComponent("gods-eye-view")
        let built = (try? String(contentsOf: app.appendingPathComponent(".aegis-commit"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: app.appendingPathComponent("dist/index.html").path)
            && built != nil && built == pinnedCommit && node != nil
    }

    /// Aegis's own Node from the setup, or Homebrew's.
    private static var node: String? {
        [folder.appendingPathComponent("node/bin/node").path, "/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .first(where: FileManager.default.isExecutableFile)
    }

    /// The one-time setup (about a minute): Node and God's Eye View downloaded, checked and built, as its own
    /// launchd job. `progress` gets each step's words.
    func setUp(progress: @escaping @MainActor (String) -> Void) async throws {
        guard let script = Self.setupScript else { throw Problem.setupFailed("missing script") }
        let home = Self.folder.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let status = Self.folder.appendingPathComponent("setup-status")
        try? FileManager.default.removeItem(at: status)
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let step = try? String(contentsOf: status, encoding: .utf8) {
                    progress(step.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { watcher.cancel() }
        let finished = await Self.runToEnd(
            label: Self.label + ".setup", program: ["/bin/bash", script.path], directory: Self.folder,
            environment: [
                "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "AEGIS_WORLD_DIR": Self.folder.path,
                "CESIUM_ION_TOKEN": WorldKeys.environment["CESIUM_ION_TOKEN"] ?? "",
            ],
            minutes: 15
        )
        let step = (try? String(contentsOf: status, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard finished, step == "done", Self.isInstalled else { throw Problem.setupFailed(step) }
        UserDefaults.aegis.set(false, forKey: WorldKeys.rebuildKey)
        log.notice("world: setup done")
    }

    /// Starts the server (or reuses a running one) and returns its address once it answers.
    func start() async throws -> URL {
        guard !Self.isTestHost else { throw Problem.failedToStart }
        if let address, await Self.answers(address) {
            return address
        }
        let app = Self.folder.appendingPathComponent("gods-eye-view", isDirectory: true)
        guard let node = Self.node else { throw Problem.noNode }
        Self.stopJob()
        let home = Self.folder.appendingPathComponent("home", isDirectory: true)
        let keys = WorldKeys.environment
        // The Cesium token is built into the globe's page: rebuild once after it changes (about 3 seconds).
        if UserDefaults.aegis.bool(forKey: WorldKeys.rebuildKey) {
            let built = await Self.runToEnd(
                label: Self.label + ".build",
                program: [node, app.appendingPathComponent("node_modules/vite/bin/vite.js").path, "build", "--logLevel", "silent"],
                directory: app, environment: Self.environment(home: home, node: node, keys: keys), minutes: 2
            )
            if built {
                UserDefaults.aegis.set(false, forKey: WorldKeys.rebuildKey)
            }
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for port in [4173, 41730, 41731] {
            let job: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": [
                    node, app.appendingPathComponent("node_modules/vite/bin/vite.js").path, "preview",
                    "--host", "127.0.0.1", "--port", String(port), "--strictPort",
                ],
                "WorkingDirectory": app.path,
                "EnvironmentVariables": Self.environment(home: home, node: node, keys: keys),
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            // The plist can hold keys: private to the owner, and removed once launchd has read it.
            let plist = FileManager.default.temporaryDirectory.appendingPathComponent(Self.label + ".plist")
            try? FileManager.default.removeItem(at: plist)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
                  FileManager.default.createFile(atPath: plist.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw Problem.failedToStart }
            defer { try? FileManager.default.removeItem(at: plist) }
            guard Self.launchctl(["bootstrap", Self.domain, plist.path]) == 0 else { throw Problem.failedToStart }
            let link = "http://127.0.0.1:\(port)/" // privacy-guard: allow-network World view on this Mac only
            guard let url = URL(string: link) else { continue }
            for _ in 0 ..< 40 {
                try? await Task.sleep(for: .milliseconds(250))
                if await Self.answers(url) {
                    address = url
                    log.notice("world: server up on port \(port, privacy: .public)")
                    return url
                }
            }
            // That port may be taken (the owner running God's Eye View themselves): try the next.
            Self.stopJob()
        }
        throw Problem.failedToStart
    }

    private static func environment(home: URL, node: String, keys: [String: String]) -> [String: String] {
        keys.merging([
            "HOME": home.path, "PATH": "/usr/bin:/bin:" + (node as NSString).deletingLastPathComponent, "NODE_ENV": "production",
        ]) { _, fixed in fixed }
    }

    /// Runs a one-off job (the setup, the globe's build) as its own launchd job and waits for it.
    private static func runToEnd(
        label: String, program: [String], directory: URL, environment: [String: String], minutes: Int
    ) async -> Bool {
        _ = launchctl(["bootout", "gui/\(getuid())/" + label])
        let job: [String: Any] = [
            "Label": label, "ProgramArguments": program, "WorkingDirectory": directory.path,
            "EnvironmentVariables": environment,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null", "RunAtLoad": true, "KeepAlive": false,
        ]
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent(label + ".plist")
        try? FileManager.default.removeItem(at: plist)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              FileManager.default.createFile(atPath: plist.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return false }
        defer {
            try? FileManager.default.removeItem(at: plist)
            _ = launchctl(["bootout", "gui/\(getuid())/" + label])
        }
        guard launchctl(["bootstrap", "gui/\(getuid())", plist.path]) == 0 else { return false }
        for _ in 0 ..< minutes * 120 {
            try? await Task.sleep(for: .milliseconds(500))
            if let status = lastExit(label) {
                return status == 0
            }
        }
        return false
    }

    /// The job's exit status once it has finished; nil while it runs or before it starts.
    private nonisolated static func lastExit(_ label: String) -> Int32? {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, !text.contains("\"PID\""),
              let range = text.range(of: #""LastExitStatus" = (-?\d+);"#, options: .regularExpression)
        else { return nil }
        return Int32(text[range].filter { $0.isNumber || $0 == "-" })
    }

    /// Stops the server; the globe's memory goes with it.
    func stop() {
        address = nil
        Self.stopJob()
    }

    private static var domain: String {
        "gui/\(getuid())"
    }

    nonisolated static func stopJob() {
        guard !isTestHost else { return }
        _ = launchctl(["bootout", "gui/\(getuid())/" + label])
    }

    private static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 1) // privacy-guard: allow-network World view on this Mac only
        request.httpMethod = "HEAD"
        let response = try? await URLSession.shared.data(for: request) // privacy-guard: allow-network World view on this Mac only
        return (response?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    private nonisolated static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
