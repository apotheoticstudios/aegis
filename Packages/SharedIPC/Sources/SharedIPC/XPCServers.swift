import AegisKit
import Foundation

/// Serves a AegisKit `CoreService` over `CoreXPCProtocol`.
public final class CoreXPCExporter: NSObject, CoreXPCProtocol, @unchecked Sendable {
    private let service: any CoreService

    public init(service: any CoreService) {
        self.service = service
    }

    public func handle(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let decoded = try? IPCCoding.decode(CoreRequest.self, from: request) else {
            reply(try? IPCCoding.encode(CoreResponse.refused(code: "bad_request")))
            return
        }
        let service = service
        Task {
            await reply(try? IPCCoding.encode(service.handle(decoded)))
        }
    }
}

/// Serves a AegisKit `ModelClient` (the real model, in ModelService) over `ModelXPCProtocol`, and tells
/// `activity` when jobs start and end so the process can exit when idle.
public final class ModelXPCExporter: NSObject, ModelXPCProtocol, @unchecked Sendable {
    private let model: any ModelClient
    private let activity: IdleExit?

    public init(model: any ModelClient, activity: IdleExit? = nil) {
        self.model = model
        self.activity = activity
    }

    public func run(_ job: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let decoded = try? IPCCoding.decode(ModelJob.self, from: job), decoded.validate().isEmpty else {
            reply(nil)
            return
        }
        activity?.begin()
        let model = model, activity = activity
        Task {
            let result: ModelJobResult
            do {
                result = try await model.run(decoded)
            } catch {
                result = ModelJobResult(jobID: decoded.id, status: .failed, failure: .internalError)
            }
            reply(try? IPCCoding.encode(result))
            activity?.end()
        }
    }

    public func cancel(jobID: String) {
        let model = model
        Task { await model.cancel(jobID: jobID) }
    }

    public func partial(jobID: String, reply: @escaping @Sendable (String?) -> Void) {
        let model = model
        Task { await reply(model.partial(jobID: jobID)) }
    }

    public func embed(_ texts: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let decoded = try? JSONDecoder().decode([String].self, from: texts), decoded.count <= 2000 else {
            reply(nil)
            return
        }
        activity?.begin()
        let model = model, activity = activity
        Task {
            let vectors = await model.embed(decoded)
            reply(vectors.flatMap { try? JSONEncoder().encode($0) })
            activity?.end()
        }
    }
}

/// Accepts connections for one exported object, after checking the caller's code signature.
public final class XPCListenerHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let interface: Protocol
    private let exported: AnyObject
    private let requirement: String?

    /// A launchd Mach service (AegisCore, ModelService). `clients` are the signing identifiers allowed in.
    public init(machServiceName: String, interface: Protocol, exported: AnyObject, clients: [String]) {
        listener = NSXPCListener(machServiceName: machServiceName)
        self.interface = interface
        self.exported = exported
        requirement = CodeSigning.requirement(identifiers: clients)
    }

    /// An in-process anonymous listener, for tests.
    public init(anonymousFor interface: Protocol, exported: AnyObject) {
        listener = NSXPCListener.anonymous()
        self.interface = interface
        self.exported = exported
        requirement = nil
    }

    public var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    public func resume() {
        if let requirement {
            listener.setConnectionCodeSigningRequirement(requirement)
        }
        listener.delegate = self
        listener.resume()
    }

    public func invalidate() {
        listener.invalidate()
    }

    public func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: interface)
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}

/// Exits the process after `seconds` with no job running (ADR-0013: launchd never stops an idle agent).
public final class IdleExit: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.aegis.idle-exit")
    private let seconds: Double
    private let exit: @Sendable () -> Void
    private var running = 0
    private var pending: DispatchWorkItem?

    public init(seconds: Double, exit: @escaping @Sendable () -> Void = { Foundation.exit(0) }) {
        self.seconds = seconds
        self.exit = exit
    }

    /// Starts the idle clock; call once after the listener resumes.
    public func arm() {
        queue.async { self.schedule() }
    }

    public func begin() {
        queue.sync {
            running += 1
            pending?.cancel()
            pending = nil
        }
    }

    public func end() {
        queue.async {
            self.running = max(0, self.running - 1)
            self.schedule()
        }
    }

    private func schedule() {
        guard running == 0 else {
            return
        }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, running == 0 else {
                return
            }
            exit()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
