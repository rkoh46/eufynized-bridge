import CoreGraphics

/// Multi-View split layouts, like an NVR monitor wall. A layout is a grid of equal 16:9 cells; each slot
/// covers a rectangle of cells, so featured layouts give one or two cameras a bigger slot.
public enum MultiViewLayout: String, CaseIterable, Identifiable, Sendable {
    case auto, grid2x2, grid3x3, grid4x4, focus1plus3, focus1plus5, focus1plus7, focus2plus8

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Fit All"
        case .grid2x2: "2 × 2"
        case .grid3x3: "3 × 3"
        case .grid4x4: "4 × 4"
        case .focus1plus3: "1 + 3"
        case .focus1plus5: "1 + 5"
        case .focus1plus7: "1 + 7"
        case .focus2plus8: "2 + 8"
        }
    }

    public var symbolName: String {
        switch self {
        case .auto: "rectangle.grid.3x2"
        case .grid2x2: "square.grid.2x2"
        case .grid3x3: "square.grid.3x3"
        case .grid4x4: "square.grid.4x3.fill"
        case .focus1plus3: "rectangle.righthalf.inset.filled"
        case .focus1plus5, .focus1plus7: "rectangle.inset.topleft.filled"
        case .focus2plus8: "rectangle.split.2x1"
        }
    }

    /// A slot's position and size, in cells.
    public struct Slot: Equatable, Sendable {
        public var x, y, width, height: Int
        public init(_ x: Int, _ y: Int, _ width: Int = 1, _ height: Int = 1) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// Cell grid size and slots (in display order) for `count` cameras shown in `size`.
    public func grid(count: Int, in size: CGSize) -> (columns: Int, rows: Int, slots: [Slot]) {
        switch self {
        case .auto:
            let columns = Self.bestColumns(count: count, in: size)
            let rows = max(1, Int((Double(max(count, 1)) / Double(columns)).rounded(.up)))
            return (columns, rows, (0..<count).map { Slot($0 % columns, $0 / columns) })
        case .grid2x2: return Self.uniform(2)
        case .grid3x3: return Self.uniform(3)
        case .grid4x4: return Self.uniform(4)
        case .focus1plus3:
            return (4, 3, [Slot(0, 0, 3, 3), Slot(3, 0), Slot(3, 1), Slot(3, 2)])
        case .focus1plus5:
            return (3, 3, [Slot(0, 0, 2, 2), Slot(2, 0), Slot(2, 1), Slot(0, 2), Slot(1, 2), Slot(2, 2)])
        case .focus1plus7:
            return (4, 4, [Slot(0, 0, 3, 3), Slot(3, 0), Slot(3, 1), Slot(3, 2),
                           Slot(0, 3), Slot(1, 3), Slot(2, 3), Slot(3, 3)])
        case .focus2plus8:
            return (4, 4, [Slot(0, 0, 2, 2), Slot(2, 0, 2, 2)] + (0..<8).map { Slot($0 % 4, 2 + $0 / 4) })
        }
    }

    /// Frames for each slot: cells keep a 16:9 shape, the grid is as large as fits, centred in `size`.
    public func frames(count: Int, in size: CGSize, spacing: CGFloat) -> [CGRect] {
        let (columns, rows, slots) = grid(count: count, in: size)
        let c = CGFloat(columns), r = CGFloat(rows)
        let cellWidth = max(0, min((size.width - spacing * (c - 1)) / c,
                                   (size.height - spacing * (r - 1)) / r * 16 / 9))
        let cellHeight = cellWidth * 9 / 16
        let gridWidth = cellWidth * c + spacing * (c - 1)
        let gridHeight = cellHeight * r + spacing * (r - 1)
        let origin = CGPoint(x: (size.width - gridWidth) / 2, y: (size.height - gridHeight) / 2)
        return slots.map { s in
            CGRect(x: origin.x + CGFloat(s.x) * (cellWidth + spacing),
                   y: origin.y + CGFloat(s.y) * (cellHeight + spacing),
                   width: CGFloat(s.width) * cellWidth + CGFloat(s.width - 1) * spacing,
                   height: CGFloat(s.height) * cellHeight + CGFloat(s.height - 1) * spacing)
        }
    }

    private static func uniform(_ n: Int) -> (Int, Int, [Slot]) {
        (n, n, (0..<(n * n)).map { Slot($0 % n, $0 / n) })
    }

    /// The column count that makes `count` 16:9 tiles as large as possible in `size`.
    static func bestColumns(count: Int, in size: CGSize) -> Int {
        guard count > 1, size.width > 0, size.height > 0 else { return 1 }
        var best = 1
        var bestWidth: CGFloat = 0
        for columns in 1...count {
            let rows = CGFloat((Double(count) / Double(columns)).rounded(.up))
            let width = min(size.width / CGFloat(columns), size.height / rows * 16 / 9)
            if width > bestWidth { bestWidth = width; best = columns }
        }
        return best
    }
}
