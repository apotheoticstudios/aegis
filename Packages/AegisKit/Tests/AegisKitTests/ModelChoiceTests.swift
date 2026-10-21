@testable import AegisKit
import XCTest

final class ModelChoiceTests: XCTestCase {
    func testMemoryDecidesTheModel() {
        XCTAssertEqual(ModelChoice.forMemory(16 * 1_073_741_824), .small, "16 GB keeps the 4B")
        XCTAssertEqual(ModelChoice.forMemory(24 * 1_073_741_824), .medium, "24 GB runs the 9B")
        XCTAssertEqual(ModelChoice.forMemory(36 * 1_073_741_824), .medium)
        XCTAssertEqual(ModelChoice.medium.folderName, "Qwen3.5-9B-MLX-4bit")
    }
}
