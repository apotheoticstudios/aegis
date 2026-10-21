import AegisKit
import Foundation
import XCTest

final class TypedStreamTests: XCTestCase {
    private let header = Data([0x04, 0x0B]) + Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03])
    private let marker = Data([0x84, 0x01, 0x2B])

    /// Invented counted-byte vectors matching Fixtures/generate/typedstream.py.
    private func stream(length: [UInt8], bytes: Data = Data()) -> Data {
        header + Data("NSString".utf8) + Data([0x01, 0x94]) + marker + Data(length) + bytes
    }

    private func stream(text: String) -> Data {
        let bytes = Data(text.utf8)
        let count = bytes.count
        let length: [UInt8] = if count < 0x80 {
            [UInt8(count)]
        } else if count <= 0xFFFF {
            [0x81, UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8)]
        } else {
            [0x82] + (0 ..< 4).map { UInt8(truncatingIfNeeded: count >> (8 * $0)) }
        }
        return stream(length: length, bytes: bytes) + Data([0x86])
    }

    func testRoundTripsShortLongAndVeryLongText() throws {
        for text in ["", "hi", "hello 👋", String(repeating: "x", count: 200), String(repeating: "é", count: 40000)] {
            XCTAssertEqual(try TypedStream.text(fromAttributedBody: stream(text: text)), text)
        }
    }

    func testLengthBoundariesAndLittleEndianOrder() throws {
        for count in [127, 128, 255, 256, 65535, 65536] {
            let text = String(repeating: "x", count: count)
            XCTAssertEqual(try TypedStream.text(fromAttributedBody: stream(text: text)), text)
        }
        for length: [UInt8] in [[0x81, 0, 0], [0x82, 0, 0, 0, 0]] {
            XCTAssertEqual(try TypedStream.text(fromAttributedBody: stream(length: length)), "")
        }
    }

    func testInvalidUTF8BecomesReplacementCharacters() throws {
        let bytes = Data("ok ".utf8) + Data([0xED, 0xA0, 0x80]) + Data(" ok".utf8)
        XCTAssertEqual(
            try TypedStream.text(fromAttributedBody: stream(length: [UInt8(bytes.count)], bytes: bytes)),
            "ok \u{FFFD}\u{FFFD}\u{FFFD} ok"
        )
    }

    func testMalformedInputsHaveTypedErrors() {
        let cases: [(Data, TypedStreamError)] = [
            (Data(), .notTypedStream),
            (Data("bplist00 not a typedstream".utf8), .notTypedStream),
            (header + Data([0x84, 0x01, 0x40, 0xFF, 0xFE]), .missingNSString),
            (header + marker + Data("NSString".utf8), .missingStringPayload),
            (stream(length: []), .truncatedStream),
            (stream(length: [0x80]), .invalidStringLength),
            (stream(length: [0x83]), .invalidStringLength),
            (stream(length: [0xFF]), .invalidStringLength),
            (stream(length: [0x81]), .invalidStringLength),
            (stream(length: [0x81, 0]), .invalidStringLength),
            (stream(length: [0x82, 0, 0, 0]), .invalidStringLength),
            (stream(length: [5], bytes: Data("ab".utf8)), .stringOutOfBounds),
            (stream(length: [0x81, 0xFF, 0xFF]), .stringOutOfBounds),
            (stream(length: [0x82, 0xFF, 0xFF, 0xFF, 0xFF]), .stringOutOfBounds),
        ]
        for (data, expected) in cases {
            XCTAssertThrowsError(try TypedStream.text(fromAttributedBody: data)) { error in
                XCTAssertEqual(error as? TypedStreamError, expected)
            }
        }
    }

    func testEveryTruncatedPrefixThrows() {
        let data = stream(length: [0x82, 3, 0, 0, 0], bytes: Data("abc".utf8))
        for end in 0 ..< data.count {
            XCTAssertThrowsError(try TypedStream.text(fromAttributedBody: Data(data.prefix(end)))) { error in
                XCTAssertTrue(error is TypedStreamError)
            }
        }
    }

    func testSignatureMustFitEntirelyWithinFirstSixteenBytes() throws {
        let data = stream(text: "hi")
        XCTAssertEqual(try TypedStream.text(fromAttributedBody: Data(repeating: 0, count: 3) + data), "hi")
        XCTAssertThrowsError(try TypedStream.text(fromAttributedBody: Data(repeating: 0, count: 4) + data)) { error in
            XCTAssertEqual(error as? TypedStreamError, .notTypedStream)
        }
    }

    func testNonzeroDataIndicesAndFirstStringOnly() throws {
        let data = Data([0xFF]) + stream(text: "first") + stream(text: "second")
        XCTAssertEqual(try TypedStream.text(fromAttributedBody: data.dropFirst()), "first")
    }
}
