@testable import AegisKit
import XCTest

/// The pinned downloads and the tune-up's verdict (ADR-0030).
final class ModelFilesTests: XCTestCase {
    func testEachModelListsCheckedFilesAtItsPinnedRevision() throws {
        for files in [ModelChoice.small.files, ModelChoice.medium.files, ModelFiles.meaning] {
            XCTAssertEqual(Set(files.files.map(\.path)).count, files.files.count)
            XCTAssertEqual(files.files.last?.path, files == ModelFiles.meaning ? "model.safetensors" : "config.json")
            for file in files.files {
                XCTAssertEqual(file.sha256.count, 64)
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit))
                XCTAssertGreaterThan(file.bytes, 0)
            }
            let source = try XCTUnwrap(files.files.first.flatMap(files.source))
            XCTAssertEqual(source.host, "huggingface.co")
            XCTAssertTrue(source.path.contains(files.revision))
        }
        XCTAssertEqual(ModelChoice.medium.files.folderName, "Qwen3.5-9B-MLX-4bit")
        XCTAssertEqual(ModelChoice.medium.files.revision, ModelChoice.medium.revision)
        // About 3 GB and 6 GB: what the wizard tells the owner and checks free space for.
        XCTAssertEqual(ModelChoice.small.files.bytes / 1_000_000_000, 3)
        XCTAssertEqual(ModelChoice.medium.files.bytes / 1_000_000_000, 5)
    }

    func testTheNineBStepsDownOnlyWhenItIsSlow() {
        let fast = ModelMetrics(generateSeconds: 10, generationTokens: 200)
        let slow = ModelMetrics(generateSeconds: 40, generationTokens: 200)
        XCTAssertEqual(ModelChoice.medium.tuned(fast), .medium)
        XCTAssertEqual(ModelChoice.medium.tuned(slow), .small)
        XCTAssertEqual(ModelChoice.small.tuned(slow), .small)
        XCTAssertEqual(ModelChoice.medium.tuned(ModelMetrics()), .medium, "no measurement, no change")
    }

    func testTheChoiceIsSavedAndRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-choice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(ModelChoice.chosen(in: folder))
        try ModelChoice.small.choose(in: folder)
        XCTAssertEqual(ModelChoice.chosen(in: folder), .small)
    }
}
