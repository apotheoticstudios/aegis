@testable import AegisKit
import XCTest

final class ScaffoldTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(AegisKit.version.isEmpty)
    }
}
