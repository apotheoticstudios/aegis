import Foundation

/// Only direct owner input in the open panel may originate a request. There is no collected-content origin.
/// This tag is not proof of provenance: future adapters must create requests only from trusted panel input.
public enum ActionOrigin: String, Codable, Sendable, CaseIterable {
    case ownerTyped, ownerSpoken
}

/// Proposed work, with no execution capability or IPC dispatch route (#189, additive contract).
public struct ActionRequest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let payload: ActionPayload
    public let origin: ActionOrigin
    public var domain: ActionDomain {
        payload.domain
    }

    public init(id: UUID = UUID(), payload: ActionPayload, origin: ActionOrigin) {
        self.id = id
        self.payload = payload
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, domain, payload, origin
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, known: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        payload = try container.decode(ActionPayload.self, forKey: .payload)
        origin = try container.decode(ActionOrigin.self, forKey: .origin)
        guard try container.decode(ActionDomain.self, forKey: .domain) == payload.domain else {
            throw DecodingError.dataCorruptedError(forKey: .domain, in: container, debugDescription: "domain_mismatch")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(domain, forKey: .domain)
        try container.encode(payload, forKey: .payload)
        try container.encode(origin, forKey: .origin)
    }
}
