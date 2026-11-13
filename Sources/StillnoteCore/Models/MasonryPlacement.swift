import CoreGraphics

/// Column placement for the summary page's masonry layout: each item, in order, goes into
/// whichever column is shortest so far, so a short section never leaves a gap below it.
public enum MasonryPlacement {
    public struct Slot: Equatable, Sendable {
        public var column: Int
        public var y: CGFloat

        public init(column: Int, y: CGFloat) {
            self.column = column
            self.y = y
        }
    }

    /// Where each item goes, given the items' heights in order. Ties go to the leftmost column.
    /// `spacing` separates items stacked in the same column.
    public static func slots(heights: [CGFloat], columns: Int, spacing: CGFloat) -> [Slot] {
        var bottoms = [CGFloat](repeating: 0, count: max(1, columns))
        var used = [Bool](repeating: false, count: bottoms.count)
        return heights.map { height in
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let y = bottoms[column] + (used[column] ? spacing : 0)
            bottoms[column] = y + height
            used[column] = true
            return Slot(column: column, y: y)
        }
    }

    /// The height of the tallest column once every item is placed.
    public static func height(heights: [CGFloat], columns: Int, spacing: CGFloat) -> CGFloat {
        zip(slots(heights: heights, columns: columns, spacing: spacing), heights)
            .map { $0.y + $1 }
            .max() ?? 0
    }
}
