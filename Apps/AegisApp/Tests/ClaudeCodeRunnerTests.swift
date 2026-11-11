@testable import Aegis
import AegisKit
import XCTest

/// ADR-0038 stage 1: a stand-in for Claude Code runs as a real launchd job, talking through the named pipes.
final class ClaudeCodeRunnerTests: XCTestCase {
    private static let canary = "CANARY-7f3a"

    /// Answers the handshake and one prompt like Claude Code 2.1, from synthetic data, and refuses to start without
    /// the rebuilt environment and locked-down flags.
    private static let standIn = #"""
    #!/bin/sh
    [ -z "$ANTHROPIC_API_KEY" ] && [ "$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" = 1 ] || exit 3
    case " $* " in *" --safe-mode --restricted "*) ;; *) exit 4 ;; esac
    reply() { printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\n' "$1" "$2"; }
    delta() { printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$1"; }
    while IFS= read -r line; do
      case "$line" in
        *aegis-init*) reply aegis-init '{"account":{"tokenSource":"oauth","apiProvider":"firstParty"},"commands":[],"models":[{"value":"opus","displayName":"Opus"}]}' ;;
        *aegis-mcp*) reply aegis-mcp '{"mcpServers":[]}' ;;
        *aegis-settings*) reply aegis-settings '{"effective":{},"sources":[]}' ;;
        *'"type":"user"'*)
          case "$line" in *CANARY-7f3a*) word=CANARY-7f3a ;; *) word=missing ;; esac
          echo '{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"plugins":[],"skills":[],"slash_commands":[],"apiKeySource":"none","model":"claude-opus-5-5"}'
          delta "Hello "
          sleep 0.5
          delta "$word"
          printf '{"type":"result","subtype":"success","is_error":false,"result":"Hello %s","stop_reason":"end_turn"}\n' "$word"
          ;;
      esac
    done
    """#

    private var folder: URL!
    private var executable: String!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-stand-in-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        try Self.standIn.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        executable = script.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testHandshakeAloneListsModelsAndRecordsTheSignIn() async {
        let ending = await ClaudeCodeRunner(executable: executable).check()
        XCTAssertEqual(ending, .ready([ClaudeCode.Model(value: "opus", name: "Opus")]))
        XCTAssertTrue(ClaudeCodeRunner.signedIn)
        XCTAssertEqual(ClaudeCodeRunner.models.map(\.value), ["opus"])
    }

    /// The reply types as it arrives, and while it does no file Aegis made holds the prompt's text.
    func testReplyStreamsThroughThePipesWithNothingOnDisk() async {
        let pieces = Pieces()
        let ending = await ClaudeCodeRunner(executable: executable).run(
            system: "Synthetic system prompt.", prompt: "Say hello to " + Self.canary, choice: .standard, timeout: 30
        ) { piece in
            pieces.append(piece, onDisk: Self.canaryOnDisk())
        }
        XCTAssertEqual(ending, .outcome(.answer(text: "Hello " + Self.canary, model: "claude-opus-5-5")))
        XCTAssertEqual(pieces.text, ["Hello ", Self.canary])
        XCTAssertEqual(pieces.onDisk, [false, false])
    }

    /// A job that ends without a result fails at once rather than waiting out the timeout.
    func testAJobThatDiesEarlyFailsQuickly() async throws {
        let dying = folder.appendingPathComponent("dying")
        try "#!/bin/sh\nexit 7\n".write(to: dying, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dying.path)
        let began = Date()
        let ending = await ClaudeCodeRunner(executable: dying.path).check()
        guard case .failed = ending else { return XCTFail("\(ending)") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }

    func testMissingClaudeCodeIsUnavailable() async {
        let ending = await ClaudeCodeRunner(executable: nil).check()
        XCTAssertEqual(ending, .unavailable)
    }

    /// Regular files in the runner's scratch folders (never the pipes themselves, which would block).
    private static func canaryOnDisk() -> Bool {
        let files = FileManager.default
        let scratch = (try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        return scratch.filter { $0.lastPathComponent.hasPrefix("aegis-claude-") }.contains { folder in
            let items = files.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
            return items.contains { item in
                (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && (try? String(contentsOf: item, encoding: .utf8))?.contains(canary) == true
            }
        }
    }
}

private final class Pieces: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var text: [String] = []
    private(set) var onDisk: [Bool] = []

    func append(_ piece: String, onDisk found: Bool) {
        lock.withLock {
            text.append(piece)
            onDisk.append(found)
        }
    }
}
