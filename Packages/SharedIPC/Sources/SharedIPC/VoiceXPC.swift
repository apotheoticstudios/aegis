import Foundation

/// AegisApp → its bundled speech service. Text and in-memory WAV bytes never leave this Mac.
@objc public protocol VoiceXPCProtocol {
    /// Loads the bundled model without speaking.
    func prepare(reply: @escaping @Sendable (Bool) -> Void)
    /// Produces one short passage, or nil for the system-voice fallback.
    func synthesize(_ text: String, reply: @escaping @Sendable (Data?) -> Void)
}

/// A lazy connection to Aegis's own XPC service. Closing the panel stops only this service.
public actor VoiceXPCClient {
    /// Bundle/signing identifier of the embedded service.
    public static let serviceName = "dev.aegis.voice"
    private let target: XPCTarget?
    private let timeout: TimeInterval
    private var connection: NSXPCConnection?
    private var revision = 0

    /// `target` is injectable for synthetic anonymous-listener tests; production uses the bundled service.
    public init(target: XPCTarget? = nil, timeout: TimeInterval = 30) {
        self.target = target
        self.timeout = timeout
    }

    /// Prepares the voice while the panel is open. Failures select the system voice.
    public func prepare() async -> Bool {
        await request(fallback: false) { proxy, reply in proxy.prepare(reply: reply) }
    }

    /// Synthesizes a passage, with cancellation and a bounded reply wait.
    public func audio(for text: String) async -> Data? {
        guard !text.isEmpty, text.count <= 1200 else { return nil }
        return await request(fallback: nil) { proxy, reply in proxy.synthesize(text, reply: reply) }
    }

    /// Terminates the owned service and discards its connection. A later request starts it afresh.
    public func stop() {
        revision += 1
        let old = connection
        connection = nil
        old?.invalidate()
    }

    private func stop(ifRevision current: Int) {
        if revision == current {
            stop()
        }
    }

    private func connected() -> NSXPCConnection {
        if let connection {
            return connection
        }
        let made = switch target {
        case let .endpoint(endpoint): NSXPCConnection(listenerEndpoint: endpoint)
        case let .machService(name): NSXPCConnection(machServiceName: name)
        case nil: NSXPCConnection(serviceName: Self.serviceName)
        }
        made.remoteObjectInterface = NSXPCInterface(with: VoiceXPCProtocol.self)
        if target == nil, let requirement = CodeSigning.requirement(identifiers: [Self.serviceName]) {
            made.setCodeSigningRequirement(requirement)
        }
        let current = revision
        made.interruptionHandler = { [weak self] in Task { await self?.stop(ifRevision: current) } }
        made.invalidationHandler = { [weak self] in Task { await self?.stop(ifRevision: current) } }
        made.resume()
        connection = made
        return made
    }

    private func request<Value: Sendable>(
        fallback: Value,
        send: (any VoiceXPCProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        guard !Task.isCancelled else { return fallback }
        let current = revision
        let connection = connected()
        let once = VoiceReply<Value>()
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.install(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    if once.finish(fallback) {
                        Task { await self?.stop(ifRevision: current) }
                    }
                } as? VoiceXPCProtocol
                guard let proxy else { once.finish(fallback); return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if once.finish(fallback) {
                        Task { await self?.stop(ifRevision: current) }
                    }
                }
                send(proxy) { once.finish($0) }
            }
        } onCancel: {
            once.finish(fallback)
            Task { await self.stop(ifRevision: current) }
        }
        return current == revision && !Task.isCancelled ? value : fallback
    }
}

/// Cancellation may arrive before the continuation is installed; preserve that result and resume once.
private final class VoiceReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var completed = false
    private var earlyResult: Result<Value, Never>?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let completed = lock.withLock { () -> Result<Value, Never>? in
            if let earlyResult {
                self.earlyResult = nil
                return earlyResult
            }
            self.continuation = continuation
            return nil as Result<Value, Never>?
        }
        if case let .success(value) = completed {
            continuation.resume(returning: value)
        }
    }

    @discardableResult func finish(_ value: Value) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        let pending = continuation
        if pending == nil {
            earlyResult = .success(value)
        }
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return true
    }
}

extension VoiceXPCClient {
    /// Internal visibility for synthetic lifecycle tests: verifies the bundled process actually exits.
    var processIdentifier: Int32? {
        connection?.processIdentifier
    }
}
