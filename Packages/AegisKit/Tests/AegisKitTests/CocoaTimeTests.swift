import AegisKit
import Foundation
import XCTest

final class CocoaTimeTests: XCTestCase {
    func testEpochOrdinaryAndFractionalTimes() throws {
        XCTAssertEqual(try XCTUnwrap(CocoaTime.date(fromSeconds: 0)).timeIntervalSince1970, 978_307_200)
        for seconds in [0.0, 1, 0.25, 86400, 780_000_000, 3_124_137_599.5] {
            XCTAssertEqual(try XCTUnwrap(CocoaTime.date(fromSeconds: seconds)).timeIntervalSinceReferenceDate, seconds)
        }
    }

    func testOutOfRangeAndNonFiniteTimesReturnNil() {
        for seconds in [-0.25, -1000, 3_124_137_600, 3_124_137_601, Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
            XCTAssertNil(CocoaTime.date(fromSeconds: seconds))
        }
    }

    func testUUIDBytesUseNetworkOrderAndUppercase() {
        let bytes = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(CocoaTime.uuidString(bytes), "00112233-4455-6677-8899-AABBCCDDEEFF")
        XCTAssertEqual(CocoaTime.uuidString((Data([0xFF]) + bytes).dropFirst()), "00112233-4455-6677-8899-AABBCCDDEEFF")
        XCTAssertEqual(CocoaTime.uuidString(Data(repeating: 0, count: 16)), "00000000-0000-0000-0000-000000000000")
        for count in [0, 1, 15, 17, 32] {
            XCTAssertNil(CocoaTime.uuidString(Data(repeating: 0, count: count)))
        }
    }
}
