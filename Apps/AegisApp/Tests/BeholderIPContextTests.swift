@testable import Aegis
import XCTest

/// Documentation, private and other special-purpose ranges only, plus the decommissioned 6bone block (RFC 3701)
/// for the ordinary-address path. Nothing is resolved or contacted.
final class BeholderIPContextTests: XCTestCase {
    private typealias Context = BeholderIPContext

    private func category(_ input: String) -> String? {
        Context.inspect(input)?.category
    }

    func testCanonicalNumericForms() throws {
        let checks: [(String, String)] = [
            ("192.0.2.1", "192.0.2.1"),
            ("  198.51.100.0  ", "198.51.100.0"),
            ("2001:DB8:0:0:0:0:0:1", "2001:db8::1"),
            ("2001:0db8:0000:0000:0001:0000:0000:0001", "2001:db8::1:0:0:1"),
            ("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"),
            ("::FFFF:192.0.2.1", "::ffff:192.0.2.1"),
            ("::ffff:c000:201", "::ffff:192.0.2.1"),
            ("::", "::"),
        ]
        for (input, canonical) in checks {
            let info = try XCTUnwrap(Context.inspect(input), input)
            XCTAssertEqual(info.canonical, canonical, input)
            XCTAssertEqual(info.version, input.contains(":") ? "IPv6" : "IPv4", input)
            XCTAssertNotNil(Context.Category(rawValue: info.category))
        }
    }

    func testRejectsEverythingButOneBareAddress() {
        let rejected = [
            "", "   ", "localhost", "example.com", "http://192.0.2.1/", "192.0.2.1:80", "[2001:db8::1]", "[2001:db8::1]:443",
            "192.0.2.0/24", "2001:db8::/32", "fe80::1%en0", "user@192.0.2.1", "user:pass@192.0.2.1", "192.0.2.1\n", "\t192.0.2.1",
            "192.0.2.\u{200B}1", "\u{202E}192.0.2.1", "\u{00A0}192.0.2.1", "192.0.2.1 198.51.100.1", "010.0.0.1", "192.0.2.01",
            "192.0.02.1", "192.0.2", "127.1", "192.0.2.256", "0x7f.0.0.1", "3221225985", "192.0.2.1.", "::ffff:192.0.2.01",
            "::ffff:192.0.2", "1::2::3", "12345::1", "2001:db8:::1", "2001:db8::g", "2001:db8:1:2:3:4:5:6:7",
            String(repeating: " ", count: 60) + "192.0.2.1",
        ]
        for input in rejected {
            XCTAssertNil(Context.inspect(input), input.debugDescription)
        }
    }

    func testIPv4SpecialPurposeBlocks() {
        let expected: [(String, Context.Category)] = [
            ("10.1.2.3", .privateUse), ("172.16.0.1", .privateUse), ("172.31.255.255", .privateUse), ("192.168.1.1", .privateUse),
            ("100.64.0.1", .sharedCarrier), ("100.127.255.255", .sharedCarrier), ("127.0.0.1", .loopback), ("169.254.1.1", .linkLocal),
            ("192.0.2.10", .documentation), ("198.51.100.7", .documentation), ("203.0.113.200", .documentation),
            ("198.18.0.1", .benchmark), ("198.19.255.255", .benchmark), ("224.0.0.1", .multicast), ("239.255.255.255", .multicast),
            ("240.0.0.1", .reserved), ("255.255.255.254", .reserved), ("255.255.255.255", .specialPurpose), ("0.0.0.0", .specialPurpose),
            ("0.1.2.3", .specialPurpose), ("192.0.0.9", .specialPurpose), ("192.88.99.1", .specialPurpose),
            ("192.31.196.1", .specialPurpose), ("192.175.48.1", .specialPurpose),
        ]
        for (input, category) in expected {
            XCTAssertEqual(self.category(input), category.rawValue, input)
        }
    }

    func testIPv6SpecialPurposeBlocks() {
        let expected: [(String, Context.Category)] = [
            ("::1", .loopback), ("::", .specialPurpose), ("fe80::1", .linkLocal), ("febf:ffff::1", .linkLocal), ("fd00::1", .privateUse),
            ("fc00::1", .privateUse), ("ff02::1", .multicast), ("2001:db8::1", .documentation), ("3fff:fff::1", .documentation),
            ("2001:2::1", .benchmark), ("2001::1", .specialPurpose), ("2001:1::1", .specialPurpose), ("2001:1ff::1", .specialPurpose),
            ("64:ff9b:1::1", .specialPurpose), ("100::1", .specialPurpose), ("100:0:0:1::1", .specialPurpose), ("5f00::1", .specialPurpose),
            ("2620:4f:8000::1", .specialPurpose), ("::0.0.0.2", .reserved), ("fec0::1", .reserved), ("4000::1", .reserved), (
                "1::1",
                .reserved
            ),
            ("3ffe::1", .potentialPublicUnicast),
        ]
        for (input, category) in expected {
            XCTAssertEqual(self.category(input), category.rawValue, input)
        }
    }

    func testEmbeddedIPv4CannotBypassClassification() throws {
        let expected: [(String, Context.Category)] = [
            ("::ffff:10.0.0.1", .privateUse), ("::ffff:a00:1", .privateUse), ("::ffff:127.0.0.1", .loopback),
            ("::ffff:192.0.2.1", .documentation), ("::ffff:100.64.0.1", .sharedCarrier), ("::ffff:169.254.0.1", .linkLocal),
            ("64:ff9b::10.0.0.1", .privateUse), ("64:ff9b::c633:6401", .documentation), ("2002:c000:201::1", .documentation),
            ("2002:7f00:1::1", .loopback),
        ]
        for (input, category) in expected {
            XCTAssertEqual(self.category(input), category.rawValue, input)
        }
        let mapped = try XCTUnwrap(Context.inspect("::ffff:192.0.2.1"))
        XCTAssertEqual(mapped.version, "IPv6")
        XCTAssertTrue(mapped.explanation.hasPrefix("IPv4-mapped form of 192.0.2.1, Documentation TEST-NET-1 (RFC 5737)."))
        XCTAssertTrue(try XCTUnwrap(Context.inspect("2002:c000:201::1")).explanation.contains("6to4 (RFC 3056) embedding 192.0.2.1"))
    }

    func testExplanationsNeverClaimIdentityLocationOrRouting() throws {
        let ordinary = try XCTUnwrap(Context.inspect("3ffe::1"))
        XCTAssertTrue(ordinary.explanation.hasPrefix("Possibly a public unicast address. Beholder has not checked"))
        let samples = ["3ffe::1", "192.0.2.1", "10.0.0.1", "100.64.0.1", "::ffff:192.0.2.1", "ff02::1", "4000::1"]
        for input in samples {
            let text = try XCTUnwrap(Context.inspect(input)).explanation
            XCTAssertTrue(text.hasSuffix(Context.caveat), input)
            for claim in ["located in", "belongs to", "owned by", "verified", "is routed", "subscriber is", "%"] {
                XCTAssertFalse(text.lowercased().contains(claim), "\(input): \(claim)")
            }
        }
        XCTAssertTrue(Context.caveat.contains("does not identify a person, account or email address"))
        XCTAssertTrue(Context.caveat.contains("network operators, not subscribers"))
        XCTAssertTrue(Context.caveat.contains("VPN"))
        XCTAssertEqual(Context.inspect("192.0.2.1"), Context.inspect(" 192.0.2.1 "), "Deterministic")
    }
}
