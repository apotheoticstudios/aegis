import Foundation

/// The app → AegisCore interface. Bytes are a AegisKit `CoreRequest` in and a `CoreResponse` out, both
/// encoded with `IPCCoding`, so the contract lives in AegisKit and this file only carries it.
@objc public protocol CoreXPCProtocol {
    func handle(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
}

/// The AegisCore → ModelService interface: a AegisKit `ModelJob` in, a `ModelJobResult` out (`IPCCoding`).
@objc public protocol ModelXPCProtocol {
    func run(_ job: Data, reply: @escaping @Sendable (Data?) -> Void)
    func cancel(jobID: String)
    /// A running job's text so far (#263), or nil.
    func partial(jobID: String, reply: @escaping @Sendable (String?) -> Void)
    /// Meaning vectors for memory recall (#309): JSON [String] in, JSON [[Float]] out, nil when unavailable.
    func embed(_ texts: Data, reply: @escaping @Sendable (Data?) -> Void)
}
