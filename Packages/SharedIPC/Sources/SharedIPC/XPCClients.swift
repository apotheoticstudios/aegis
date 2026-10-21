import AegisKit
import Foundation

/// Resumes a continuation exactly once, whichever of reply, error handler or timeout comes first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Resumes with `value` unless something else already did; returns whether this call won.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

/// Where a client connects: a launchd Mach service, or an anonymous listener's endpoint in tests.
public enum XPCTarget: Sendable {
    case machService(String)
    case endpoint(NSXPCListenerEndpoint)
}

extension NSXPCListenerEndpoint: @unchecked @retroactive Sendable {}

/// One lazily created connection, recreated after it is invalidated. Interruptions keep it: the next
/// message makes launchd start the service again.
final class ConnectionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let target: XPCTarget
    private let interface: Protocol
    private let peers: [String]

    init(target: XPCTarget, interface: Protocol, peers: [String]) {
        self.target = target
        self.interface = interface
        self.peers = peers
    }

    func current() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            return connection
        }
        let made = switch target {
        case let .machService(name): NSXPCConnection(machServiceName: name, options: [])
        case let .endpoint(endpoint): NSXPCConnection(listenerEndpoint: endpoint)
        }
        made.remoteObjectInterface = NSXPCInterface(with: interface)
        if let requirement = CodeSigning.requirement(identifiers: peers) {
            made.setCodeSigningRequirement(requirement)
        }
        made.invalidationHandler = { [weak self] in self?.reset() }
        made.resume()
        connection = made
        return made
    }

    func invalidate() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }

    private func reset() {
        lock.lock()
        connection = nil
        lock.unlock()
    }
}

/// The app's view of AegisCore. Failures become `.refused` codes, never thrown text.
public final class CoreXPCClient: CoreService, @unchecked Sendable {
    private let slot: ConnectionSlot

    public init(target: XPCTarget = .machService(ServiceNames.core)) {
        slot = ConnectionSlot(target: target, interface: CoreXPCProtocol.self, peers: [ServiceNames.core])
    }

    public func handle(_ request: CoreRequest) async -> CoreResponse {
        guard let data = try? IPCCoding.encode(request) else {
            return .refused(code: "encoding")
        }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = slot.current().remoteObjectProxyWithErrorHandler { _ in
                once.resume(.refused(code: "unreachable"))
            } as? CoreXPCProtocol
            guard let proxy else {
                once.resume(.refused(code: "unreachable"))
                return
            }
            proxy.handle(data) { reply in
                once.resume(reply.flatMap { try? IPCCoding.decode(CoreResponse.self, from: $0) } ?? .refused(code: "bad_reply"))
            }
        }
    }

    public func embed(_ texts: [String]) async -> [[Float]]? {
        guard let data = try? JSONEncoder().encode(texts) else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce<[[Float]]?>(continuation)
            let proxy = slot.current().remoteObjectProxyWithErrorHandler { _ in
                once.resume(nil)
            } as? ModelXPCProtocol
            guard let proxy else {
                once.resume(nil)
                return
            }
            // Recall must never hold up an answer: without vectors in time, memory falls back to words.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { once.resume(nil) }
            proxy.embed(data) { reply in
                once.resume(reply.flatMap { try? JSONDecoder().decode([[Float]].self, from: $0) })
            }
        }
    }

    public func invalidate() {
        slot.invalidate()
    }
}

/// AegisCore's view of ModelService. An interruption (ModelService crashed or was killed) comes back as
/// `failed(.interrupted)`; AegisCore decides whether to retry. A reply missing 5 s after the job's
/// deadline comes back as `timedOut`.
public final class ModelXPCClient: ModelClient, @unchecked Sendable {
    private let slot: ConnectionSlot

    public init(target: XPCTarget = .machService(ServiceNames.model)) {
        slot = ConnectionSlot(target: target, interface: ModelXPCProtocol.self, peers: [ServiceNames.model])
    }

    public func run(_ job: ModelJob) async throws -> ModelJobResult {
        let data = try IPCCoding.encode(job)
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let interrupted = ModelJobResult(jobID: job.id, status: .failed, failure: .interrupted)
            let proxy = slot.current().remoteObjectProxyWithErrorHandler { _ in
                once.resume(interrupted)
            } as? ModelXPCProtocol
            guard let proxy else {
                once.resume(interrupted)
                return
            }
            let wait = max(0, job.deadline.timeIntervalSinceNow) + 5
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [slot] in
                // Past the deadline: tell ModelService to stop, so the model doesn't keep its memory for
                // nothing. Only when the timeout won, so a finished job never relaunches ModelService.
                if once.resume(ModelJobResult(jobID: job.id, status: .timedOut)) {
                    (slot.current().remoteObjectProxy as? ModelXPCProtocol)?.cancel(jobID: job.id)
                }
            }
            proxy.run(data) { reply in
                let result = reply.flatMap { try? IPCCoding.decode(ModelJobResult.self, from: $0) }
                once.resume(result ?? ModelJobResult(jobID: job.id, status: .failed, failure: .internalError))
            }
        }
    }

    public func cancel(jobID: String) async {
        (slot.current().remoteObjectProxy as? ModelXPCProtocol)?.cancel(jobID: jobID)
    }

    public func partial(jobID: String) async -> String? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<String?>(continuation)
            let proxy = slot.current().remoteObjectProxyWithErrorHandler { _ in
                once.resume(nil)
            } as? ModelXPCProtocol
            guard let proxy else {
                once.resume(nil)
                return
            }
            proxy.partial(jobID: jobID) { once.resume($0) }
        }
    }

    public func invalidate() {
        slot.invalidate()
    }
}
