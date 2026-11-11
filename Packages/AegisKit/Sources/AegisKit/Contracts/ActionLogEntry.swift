import Foundation

/// Execution lifecycle codes reserved for future executors; policy-only groundwork executes nothing.
public enum ActionOutcomeCode: String, Codable, Sendable, CaseIterable {
    case proposed, rejected, awaitingConfirmation, cancelled, succeeded, failed, undone, undoUnavailable
}

/// Audit metadata only. Its type deliberately cannot carry payload text or free-form errors.
public struct ActionLogEntry: Codable, Sendable, Hashable {
    public let time: Date
    public let requestID: UUID
    public let domain: ActionDomain
    public let decision: ActionDecision
    public let outcomeCode: ActionOutcomeCode
    /// Who asked (ADR-0038, additive): the owner or Claude. Nil in entries written before it was recorded.
    public let origin: ActionOrigin?

    public init(
        time: Date, requestID: UUID, domain: ActionDomain, decision: ActionDecision, outcomeCode: ActionOutcomeCode,
        origin: ActionOrigin? = nil
    ) {
        self.time = time
        self.requestID = requestID
        self.domain = domain
        self.decision = decision
        self.outcomeCode = outcomeCode
        self.origin = origin
    }

    /// Copies only the opaque identifier, domain and origin from a request, never its arguments.
    public init(time: Date, request: ActionRequest, decision: ActionDecision, outcomeCode: ActionOutcomeCode) {
        self.init(
            time: time, requestID: request.id, domain: request.domain, decision: decision, outcomeCode: outcomeCode, origin: request.origin
        )
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case time, requestID, domain, decision, outcomeCode, origin
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(Date.self, forKey: .time)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        domain = try container.decode(ActionDomain.self, forKey: .domain)
        decision = try container.decode(ActionDecision.self, forKey: .decision)
        outcomeCode = try container.decode(ActionOutcomeCode.self, forKey: .outcomeCode)
        origin = try container.decodeIfPresent(ActionOrigin.self, forKey: .origin)
    }
}
