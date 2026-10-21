import Foundation
@testable import SharedIPC
import XCTest

@MainActor
final class VoiceXPCTests: XCTestCase {
    func testVoiceRoundTripAndReconnect() async {
        let fixture = FixtureVoice()
        let host = XPCListenerHost(anonymousFor: VoiceXPCProtocol.self, exported: fixture)
        host.resume()
        defer { host.invalidate() }
        let client = VoiceXPCClient(target: .endpoint(host.endpoint), timeout: 1)
        let prepared = await client.prepare()
        XCTAssertTrue(prepared)
        let audio = await client.audio(for: "Synthetic example.")
        XCTAssertEqual(audio, Data("synthetic WAV".utf8))
        await client.stop()
        let reopened = await client.prepare()
        XCTAssertTrue(reopened)
        await client.stop()
    }

    func testTimeoutAndLateReplyResumeOnlyOnce() async {
        let fixture = FixtureVoice(holdsAudio: true)
        let host = XPCListenerHost(anonymousFor: VoiceXPCProtocol.self, exported: fixture)
        host.resume()
        defer { host.invalidate() }
        let client = VoiceXPCClient(target: .endpoint(host.endpoint), timeout: 0.1)
        let start = ContinuousClock.now
        let result = await client.audio(for: "Synthetic example.")
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        fixture.replyLate()
        await client.stop()
    }

    func testCancellationReturnsPromptlyAndDiscardsLateAudio() async {
        let fixture = FixtureVoice(holdsAudio: true)
        let host = XPCListenerHost(anonymousFor: VoiceXPCProtocol.self, exported: fixture)
        host.resume()
        defer { host.invalidate() }
        let client = VoiceXPCClient(target: .endpoint(host.endpoint), timeout: 5)
        let pending = Task { await client.audio(for: "Synthetic example.") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !fixture.received, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(fixture.received)
        let start = ContinuousClock.now
        pending.cancel()
        let result = await pending.value
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        fixture.replyLate()
        await client.stop()
    }
}

private final class FixtureVoice: NSObject, VoiceXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let holdsAudio: Bool
    private var pending: (@Sendable (Data?) -> Void)?
    var received: Bool {
        lock.withLock { pending != nil }
    }

    init(holdsAudio: Bool = false) {
        self.holdsAudio = holdsAudio
    }

    func prepare(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }

    func synthesize(_: String, reply: @escaping @Sendable (Data?) -> Void) {
        if holdsAudio {
            lock.withLock { pending = reply }
        } else {
            reply(Data("synthetic WAV".utf8))
        }
    }

    func replyLate() {
        let reply = lock.withLock { let reply = pending; pending = nil; return reply }
        reply?(Data("late synthetic WAV".utf8))
    }
}
