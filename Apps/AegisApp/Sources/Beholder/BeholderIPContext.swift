import Darwin
import Foundation

/// Offline context for an IP address the owner already has. Parsing is local and numeric (`inet_pton`/`inet_ntop`):
/// no DNS, registry lookup or request is made. An address never identifies a person, account or email address.
enum BeholderIPContext {
    struct Info: Equatable, Sendable {
        /// RFC 5952 / dotted-decimal form.
        let canonical: String
        /// "IPv4" or "IPv6".
        let version: String
        /// One of `Category`'s raw values.
        let category: String
        let explanation: String
    }

    /// Fixed category labels. `potentialPublicUnicast` means only "not in a special-purpose block".
    enum Category: String, CaseIterable, Sendable {
        case privateUse = "private"
        case linkLocal = "link-local"
        case loopback
        case sharedCarrier = "shared-carrier"
        case documentation
        case benchmark
        case multicast
        case reserved
        case specialPurpose = "special-purpose"
        case potentialPublicUnicast = "potential-public-unicast"

        var meaning: String {
            switch self {
            case .privateUse: "Used only inside private networks; many unrelated networks reuse the same addresses."
            case .linkLocal: "Valid only on one local network link and never routed on the internet."
            case .loopback: "Refers to the device itself."
            case .sharedCarrier: "Used inside carrier-grade NAT, where many subscribers share public addresses."
            case .documentation: "Reserved for examples and documentation; real hosts do not use it."
            case .benchmark: "Reserved for network test labs."
            case .multicast: "Addresses a group of receivers, not one host."
            case .reserved: "Reserved and not assigned for ordinary use."
            case .specialPurpose: "Assigned to a protocol or infrastructure function, not an ordinary host."
            case .potentialPublicUnicast:
                "Possibly a public unicast address. Beholder has not checked whether it is allocated, routed or in use."
            }
        }
    }

    /// Longest accepted input, in UTF-8 bytes.
    static let maxLength = 64

    /// Appended to every explanation.
    static let caveat = "An IP address does not identify a person, account or email address, and gives no precise location. "
        + "Registry contacts are network operators, not subscribers, and shared, dynamic, carrier-NAT and VPN addresses serve many people."

    /// Accepts one bare IPv4 or IPv6 address. Rejects URLs, brackets, ports, CIDR prefixes, zone IDs, credentials,
    /// hidden characters, IPv4 leading zeros and shorthand forms such as `127.1`.
    static func inspect(_ input: String) -> Info? {
        guard input.utf8.count <= maxLength,
              !input.unicodeScalars
              .contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
        else { return nil }
        let text = input.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        if !text.contains(":") {
            guard dottedQuad(text), let bytes = parse(text, family: AF_INET), let canonical = format(bytes) else { return nil }
            return info(bytes, canonical: canonical, version: "IPv4")
        }
        // An embedded dotted tail (`::ffff:192.0.2.1`) gets the same leading-zero rule as plain IPv4.
        if text.contains("."), !dottedQuad(String(text.split(separator: ":", omittingEmptySubsequences: false).last ?? "")) {
            return nil
        }
        guard let bytes = parse(text, family: AF_INET6), let canonical = format(bytes) else { return nil }
        return info(bytes, canonical: canonical, version: "IPv6")
    }

    private static let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")

    /// Exactly four decimal parts, each 0 or without a leading zero; range is checked by `inet_pton`.
    private static func dottedQuad(_ text: String) -> Bool {
        text.range(of: #"\A(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}\z"#, options: .regularExpression) != nil
    }

    private static func info(_ bytes: [UInt8], canonical: String, version: String) -> Info {
        let (category, name) = classify(bytes)
        let explanation = (name.map { $0 + ". " } ?? "") + category.meaning + " " + caveat
        return Info(canonical: canonical, version: version, category: category.rawValue, explanation: explanation)
    }

    /// A fixed block from the IANA special-purpose registries (both updated 2025-10-09).
    private struct Block {
        let prefix: [UInt8]
        let length: Int
        let category: Category
        let name: String

        func contains(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == prefix.count else { return false }
            for bit in 0 ..< length where (bytes[bit / 8] >> (7 - bit % 8)) & 1 != (prefix[bit / 8] >> (7 - bit % 8)) & 1 {
                return false
            }
            return true
        }
    }

    private static func v4(_ prefix: [UInt8], _ length: Int, _ category: Category, _ name: String) -> Block {
        Block(prefix: prefix, length: length, category: category, name: name)
    }

    private static func v6(_ head: [UInt16], _ length: Int, _ category: Category, _ name: String) -> Block {
        let words = head + Array(repeating: 0, count: 8 - head.count)
        return Block(prefix: words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }, length: length, category: category, name: name)
    }

    /// Most specific first. Source: IANA IPv4 Special-Purpose Address Registry (iana.org/assignments/iana-ipv4-special-registry), RFC 5771.
    private static let ipv4Blocks: [Block] = [
        v4([0, 0, 0, 0], 8, .specialPurpose, "\"This network\" (RFC 791)"),
        v4([10, 0, 0, 0], 8, .privateUse, "Private-Use (RFC 1918)"),
        v4([100, 64, 0, 0], 10, .sharedCarrier, "Shared Address Space (RFC 6598)"),
        v4([127, 0, 0, 0], 8, .loopback, "Loopback (RFC 1122)"),
        v4([169, 254, 0, 0], 16, .linkLocal, "Link Local (RFC 3927)"),
        v4([172, 16, 0, 0], 12, .privateUse, "Private-Use (RFC 1918)"),
        v4([192, 0, 0, 0], 24, .specialPurpose, "IETF Protocol Assignments (RFC 6890)"),
        v4([192, 0, 2, 0], 24, .documentation, "Documentation TEST-NET-1 (RFC 5737)"),
        v4([192, 31, 196, 0], 24, .specialPurpose, "AS112-v4 (RFC 7535)"),
        v4([192, 52, 193, 0], 24, .specialPurpose, "AMT (RFC 7450)"),
        v4([192, 88, 99, 0], 24, .specialPurpose, "Deprecated 6to4 Relay Anycast (RFC 7526)"),
        v4([192, 168, 0, 0], 16, .privateUse, "Private-Use (RFC 1918)"),
        v4([192, 175, 48, 0], 24, .specialPurpose, "Direct Delegation AS112 Service (RFC 7534)"),
        v4([198, 18, 0, 0], 15, .benchmark, "Benchmarking (RFC 2544)"),
        v4([198, 51, 100, 0], 24, .documentation, "Documentation TEST-NET-2 (RFC 5737)"),
        v4([203, 0, 113, 0], 24, .documentation, "Documentation TEST-NET-3 (RFC 5737)"),
        v4([224, 0, 0, 0], 4, .multicast, "Multicast (RFC 5771)"),
        v4([255, 255, 255, 255], 32, .specialPurpose, "Limited Broadcast (RFC 919)"),
        v4([240, 0, 0, 0], 4, .reserved, "Reserved (RFC 1112)"),
    ]

    /// Most specific first. Source: IANA IPv6 Special-Purpose Address Registry (iana.org/assignments/iana-ipv6-special-registry), RFC 4291.
    /// IPv4-embedding blocks are handled separately so an embedded special address cannot hide behind them.
    private static let ipv6Blocks: [Block] = [
        v6([], 128, .specialPurpose, "Unspecified Address (RFC 4291)"),
        v6([0, 0, 0, 0, 0, 0, 0, 1], 128, .loopback, "Loopback Address (RFC 4291)"),
        v6([], 96, .reserved, "Deprecated IPv4-compatible address (RFC 4291)"),
        v6([0x64, 0xFF9B, 1], 48, .specialPurpose, "Local-use IPv4/IPv6 Translation (RFC 8215)"),
        v6([0x100, 0, 0, 0], 64, .specialPurpose, "Discard-Only Address Block (RFC 6666)"),
        v6([0x100, 0, 0, 1], 64, .specialPurpose, "Dummy IPv6 Prefix (RFC 9780)"),
        v6([0x2001, 2, 0], 48, .benchmark, "Benchmarking (RFC 5180)"),
        v6([0x2001, 0], 32, .specialPurpose, "Teredo (RFC 4380)"),
        v6([0x2001], 23, .specialPurpose, "IETF Protocol Assignments (RFC 2928)"),
        v6([0x2001, 0xDB8], 32, .documentation, "Documentation (RFC 3849)"),
        v6([0x2620, 0x4F, 0x8000], 48, .specialPurpose, "Direct Delegation AS112 Service (RFC 7534)"),
        v6([0x3FFF], 20, .documentation, "Documentation (RFC 9637)"),
        v6([0x5F00], 16, .specialPurpose, "Segment Routing (SRv6) SIDs (RFC 9602)"),
        v6([0xFC00], 7, .privateUse, "Unique-Local (RFC 4193)"),
        v6([0xFE80], 10, .linkLocal, "Link-Local Unicast (RFC 4291)"),
        v6([0xFF00], 8, .multicast, "Multicast (RFC 4291)"),
    ]

    private static let mapped = v6([0, 0, 0, 0, 0, 0xFFFF], 96, .specialPurpose, "IPv4-mapped")
    private static let nat64 = v6([0x64, 0xFF9B, 0, 0, 0, 0], 96, .specialPurpose, "IPv4/IPv6 Translation (RFC 6052)")
    private static let sixToFour = v6([0x2002], 16, .specialPurpose, "6to4 (RFC 3056)")
    /// IANA global unicast space; everything else outside the registries is reserved by the IETF.
    private static let globalUnicast = v6([0x2000], 3, .potentialPublicUnicast, "")

    private static func classify(_ bytes: [UInt8]) -> (Category, String?) {
        if bytes.count == 4 {
            return ipv4Blocks.first { $0.contains(bytes) }.map { ($0.category, $0.name) } ?? (.potentialPublicUnicast, nil)
        }
        if mapped.contains(bytes) {
            let embedded = Array(bytes[12 ..< 16])
            let (category, name) = classify(embedded)
            return (category, "IPv4-mapped form of " + (format(embedded) ?? "an IPv4 address") + (name.map { ", " + $0 } ?? ""))
        }
        for (block, embedded) in [(nat64, Array(bytes[12 ..< 16])), (sixToFour, Array(bytes[2 ..< 6]))] where block.contains(bytes) {
            let (category, name) = classify(embedded)
            let base = block.name + " embedding " + (format(embedded) ?? "an IPv4 address")
            // A transition prefix never upgrades a special embedded address to an ordinary one.
            return category == .potentialPublicUnicast ? (.specialPurpose, base) : (category, base + ", " + (name ?? ""))
        }
        if let block = ipv6Blocks.first(where: { $0.contains(bytes) }) {
            return (block.category, block.name)
        }
        return globalUnicast.contains(bytes) ? (.potentialPublicUnicast, nil)
            : (.reserved, "Outside the IANA global unicast space 2000::/3")
    }

    private static func parse(_ text: String, family: Int32) -> [UInt8]? {
        var storage = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let parsed = storage.withUnsafeMutableBytes { inet_pton(family, text, $0.baseAddress) }
        return parsed == 1 ? storage : nil
    }

    private static func format(_ bytes: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let written = bytes.withUnsafeBytes { raw in
            buffer.withUnsafeMutableBufferPointer { inet_ntop(family, raw.baseAddress, $0.baseAddress, socklen_t($0.count)) }
        }
        return written == nil ? nil : String(cString: buffer)
    }
}
