import CoreGraphics
import StillnoteCore
import XCTest

final class MasonryPlacementTests: XCTestCase {
    func testEachItemGoesIntoTheShortestColumn() {
        // A tall first section leaves the left column long, so the next two stack on the right.
        let slots = MasonryPlacement.slots(heights: [300, 80, 60, 100], columns: 2, spacing: 20)
        XCTAssertEqual(slots, [
            .init(column: 0, y: 0),
            .init(column: 1, y: 0),
            .init(column: 1, y: 100),
            .init(column: 1, y: 180),
        ])
        XCTAssertEqual(MasonryPlacement.height(heights: [300, 80, 60, 100], columns: 2, spacing: 20), 300)
    }

    func testTiesGoLeft() {
        let slots = MasonryPlacement.slots(heights: [50, 50, 50], columns: 2, spacing: 10)
        XCTAssertEqual(slots.map(\.column), [0, 1, 0])
        XCTAssertEqual(slots[2].y, 60)
    }

    func testOneColumnStacksInOrder() {
        let slots = MasonryPlacement.slots(heights: [10, 20, 30], columns: 1, spacing: 5)
        XCTAssertEqual(slots.map(\.column), [0, 0, 0])
        XCTAssertEqual(slots.map(\.y), [0, 15, 40])
        XCTAssertEqual(MasonryPlacement.height(heights: [10, 20, 30], columns: 1, spacing: 5), 70)
    }

    func testEmptyAndZeroColumns() {
        XCTAssertEqual(MasonryPlacement.slots(heights: [], columns: 2, spacing: 10), [])
        XCTAssertEqual(MasonryPlacement.height(heights: [], columns: 2, spacing: 10), 0)
        // Zero columns is treated as one rather than trapping.
        XCTAssertEqual(MasonryPlacement.slots(heights: [10, 10], columns: 0, spacing: 4).map(\.y), [0, 14])
    }
}
