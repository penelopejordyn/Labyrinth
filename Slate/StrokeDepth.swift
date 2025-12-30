import Foundation

/// Shared mapping from monotonic `depthID` (creation order) into Metal NDC depth [0, 1].
///
/// Newer strokes (higher `depthID`) map closer to the camera (smaller depth value).
enum StrokeDepth {
    static let slotCount: UInt32 = 1 << 24
    static let denominator: Float = Float(slotCount) + 1.0

    static func metalDepth(for depthID: UInt32) -> Float {
        let clamped = min(depthID, slotCount - 1)
        let numerator = Float(slotCount - clamped)
        return numerator / denominator
    }
}

