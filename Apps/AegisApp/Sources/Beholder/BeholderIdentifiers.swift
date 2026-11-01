import Foundation

/// A conservative comparison key, not a claim about an identifier's owner or validity.
struct BeholderIdentifier: Codable, Hashable, Sendable, Comparable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case email, phone
    }

    let kind: Kind
    let value: String

    /// Email domains fold case; local parts and plus-addresses remain distinct.
    /// National phone numbers require an explicit region; short codes are not identity evidence.
    init?(input: String, kind: Kind, region: BeholderQueryPlanner.PhoneRegion = .international) {
        guard input.utf8.count <= 512, input.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && $0.properties.generalCategory != .format
        }) else { return nil }
        var raw = input
        if kind == .phone {
            raw = raw.trimmingCharacters(in: .whitespaces)
            if raw.lowercased().hasPrefix("tel:") {
                raw = String(raw.dropFirst(4))
            }
        }
        if kind == .phone, region == .australia {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let digits = trimmed.filter { $0.isASCII && $0.isNumber }
            if digits.count == 11, digits.hasPrefix("61"), !trimmed.hasPrefix("+") {
                raw = "+" + trimmed
            }
        }
        guard case let .success(plan) = BeholderQueryPlanner.build(
            input: raw, kind: kind == .phone ? .phone : .email, region: region
        ) else { return nil }
        self.kind = kind
        value = plan.seed
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.kind.rawValue, lhs.value) < (rhs.kind.rawValue, rhs.value)
    }

    private enum CodingKeys: CodingKey { case kind, value }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try fields.decode(Kind.self, forKey: .kind)
        let value = try fields.decode(String.self, forKey: .value)
        guard let identifier = Self(input: value, kind: kind), identifier.value == value else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: fields, debugDescription: "Invalid identifier")
        }
        self = identifier
    }
}
