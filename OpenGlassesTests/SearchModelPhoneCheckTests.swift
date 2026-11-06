import XCTest
@testable import OpenGlasses

/// Plan KQ P0: the pure core of the phone check. The model itself is never loaded here.
final class SearchModelPhoneCheckTests: XCTestCase {

    func testCosineCutsToTheLeadingDimensions() {
        let a: [Float] = [1, 0, 5, 0]
        let b: [Float] = [1, 0, -5, 0]
        XCTAssertEqual(SearchModelPhoneCheck.cosine(a, b, dimension: 2), 1, accuracy: 1e-6)
        XCTAssertLessThan(SearchModelPhoneCheck.cosine(a, b), 0)
        XCTAssertEqual(SearchModelPhoneCheck.cosine([], b), 0)
    }

    func testParityCountsNonFiniteVectorsAndLeavesThemOutOfTheCosines() {
        let reference: [[Float]] = [[1, 0], [0, 1], [1, 1]]
        let produced: [[Float]] = [[1, 0], [.nan, 1], [1, 0.9]]
        let p = SearchModelPhoneCheck.parity(reference: reference, produced: produced, dimension: 2)
        XCTAssertEqual(p.nonFinite, 1)
        XCTAssertEqual(p.below999, 1)
        XCTAssertLessThan(p.minimum, 0.999)
        XCTAssertEqual(p.median, 1, accuracy: 1e-6)
    }

    func testParityWithNoFiniteVectorReportsZeros() {
        let p = SearchModelPhoneCheck.parity(reference: [[1]], produced: [[.infinity]], dimension: 1)
        XCTAssertEqual(p, .init(nonFinite: 1, minimum: 0, median: 0, below999: 0))
    }

    func testQuantile() {
        XCTAssertEqual(SearchModelPhoneCheck.quantile([], 0.5), 0)
        XCTAssertEqual(SearchModelPhoneCheck.quantile([3, 1, 2], 0.5), 2)
        XCTAssertEqual(SearchModelPhoneCheck.quantile(Array(1...10).map(Double.init), 0.9), 9)
    }

    func testMissingFilesNamesWhatIsAbsent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(SearchModelPhoneCheck.missingFiles(in: folder).count, 5)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("phone-check.json"))
        XCTAssertFalse(SearchModelPhoneCheck.missingFiles(in: folder).contains("phone-check.json"))
        XCTAssertEqual(SearchModelPhoneCheck.missingFiles(in: folder).count, 4)
    }
}
