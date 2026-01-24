import Foundation
import simd

/// 5x5 fractal grid indexing for child tiles within a Frame.
struct GridIndex: Hashable, Codable {
    static let gridSize: Int = 5
    static let center: GridIndex = GridIndex(col: 2, row: 2)

    var col: Int
    var row: Int

    var isValid: Bool {
        (0..<Self.gridSize).contains(col) && (0..<Self.gridSize).contains(row)
    }

    func clamped() -> GridIndex {
        GridIndex(
            col: min(max(col, 0), Self.gridSize - 1),
            row: min(max(row, 0), Self.gridSize - 1)
        )
    }

    func wrapped() -> GridIndex {
        func wrap(_ v: Int) -> Int {
            let m = Self.gridSize
            let r = v % m
            return r < 0 ? r + m : r
        }
        return GridIndex(col: wrap(col), row: wrap(row))
    }
}

enum GridDirection: CaseIterable {
    case left
    case right
    case up
    case down

    var delta: (dx: Int, dy: Int) {
        switch self {
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .up: return (0, -1)
        case .down: return (0, 1)
        }
    }
}

/// Fractal math/config helpers.
enum FractalGrid {
    static let scale: Double = 5.0

    static func tileExtent(frameExtent: SIMD2<Double>) -> SIMD2<Double> {
        frameExtent / Double(GridIndex.gridSize)
    }

    static func childCenterInParent(frameExtent: SIMD2<Double>, index: GridIndex) -> SIMD2<Double> {
        let tile = tileExtent(frameExtent: frameExtent)
        let x = (Double(index.col) - Double(GridIndex.center.col)) * tile.x
        let y = (Double(index.row) - Double(GridIndex.center.row)) * tile.y
        return SIMD2<Double>(x, y)
    }

    static func childIndex(frameExtent: SIMD2<Double>, pointInParent: SIMD2<Double>) -> GridIndex {
        let tile = tileExtent(frameExtent: frameExtent)
        let half = frameExtent * 0.5

        let fx = (pointInParent.x + half.x) / max(tile.x, 1e-9)
        let fy = (pointInParent.y + half.y) / max(tile.y, 1e-9)

        return GridIndex(col: Int(floor(fx)), row: Int(floor(fy))).clamped()
    }

    static func isPointInFrameBounds(frameExtent: SIMD2<Double>, point: SIMD2<Double>) -> Bool {
        let half = frameExtent * 0.5
        return point.x >= -half.x && point.x <= half.x && point.y >= -half.y && point.y <= half.y
    }
}

