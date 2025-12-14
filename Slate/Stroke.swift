// Stroke.swift models pen and pencil strokes, including coordinate transforms and tessellation helpers.
import SwiftUI
import Metal

struct StrokeSegmentInstance {
    var p0: SIMD2<Float>
    var p1: SIMD2<Float>
    var color: SIMD4<Float>
}

/// A stroke on the infinite canvas using Floating Origin architecture.
///
/// Local Realism:
/// Strokes are "locally aware" - they only know their position within the current Frame.
/// They are ignorant of the infinite universe and never see large numbers.
///
/// **Key Concept:** Instead of storing absolute world coordinates (which cause precision
/// issues at high zoom), we store:
/// - An `origin` (anchor point) within the current Frame (Double precision, but always small)
/// - All vertices as Float offsets from that origin (local coords)
///
/// This ensures the GPU only ever receives small Float values, eliminating precision gaps.
/// The stroke never needs to know if it exists at 10^100 zoom or 10^-50 zoom.
class Stroke: Identifiable {
    let id: UUID
    let origin: SIMD2<Double>           // Anchor point within the Frame (Double precision, always small)
    let worldWidth: Double              // Width in world units
    let color: SIMD4<Float>

    var segments: [StrokeSegmentInstance] = []
    var segmentBuffer: MTLBuffer?
    var localBounds: CGRect = .zero

    /// Initialize stroke from screen-space points using direct delta calculation.
    /// This avoids Double precision loss at extreme zoom levels by calculating
    /// the stroke geometry directly from screen-space deltas rather than converting
    /// all points to absolute world coordinates.
    ///
    /// - Parameters:
    ///   - screenPoints: Raw screen points (high precision)
    ///   - zoomAtCreation: Zoom level when stroke was drawn
    ///   - panAtCreation: Pan offset when stroke was drawn
    ///   - viewSize: View dimensions
    ///   - rotationAngle: Camera rotation angle
    ///   - color: Stroke color
    ///   - baseWidth: Base stroke width in world units (before zoom adjustment)
    ///   - device: MTLDevice for creating cached segment buffer
    ///  UPGRADED: Now accepts Double for zoom and pan to maintain precision
    init(screenPoints: [CGPoint],
         zoomAtCreation: Double,
         panAtCreation: SIMD2<Double>,
         viewSize: CGSize,
         rotationAngle: Float,
         color: SIMD4<Float>,
         baseWidth: Double = 10.0,
         device: MTLDevice?) {
        self.id = UUID()
        self.color = color

        guard let firstScreenPt = screenPoints.first else {
            self.origin = .zero
            self.worldWidth = 0
            self.segments = []
            return
        }

        // 1. CALCULATE ORIGIN (ABSOLUTE) -  HIGH PRECISION FIX
        // We still need the absolute world position for the anchor, so we know WHERE the stroke is.
        // Only convert the FIRST point to world coordinates.
        // Use the Pure Double helper so the anchor is precise at 1,000,000x zoom
        self.origin = screenToWorldPixels_PureDouble(firstScreenPt,
                                                     viewSize: viewSize,
                                                     panOffset: panAtCreation,
                                                     zoomScale: zoomAtCreation,
                                                     rotationAngle: rotationAngle)

        // 2. CALCULATE GEOMETRY (RELATIVE) - THE FIX for Double precision
        //  Calculate shape directly from screen deltas: (ScreenPoint - FirstScreenPoint) / Zoom
        // This preserves perfect smoothness regardless of world coordinates.
        let zoom = zoomAtCreation
        let angle = Double(rotationAngle)
        let c = cos(angle)
        let s = sin(angle)

        var centerPoints: [SIMD2<Float>] = screenPoints.map { pt in
            let dx = Double(pt.x) - Double(firstScreenPt.x)
            let dy = Double(pt.y) - Double(firstScreenPt.y)

            //  FIX: Match the CPU Inverse Rotation (Screen -> World)
            // Inverse of Shader's CW matrix: [c, s; -s, c]
            let unrotatedX = dx * c + dy * s
            let unrotatedY = -dx * s + dy * c

            // Convert to world units
            let worldDx = unrotatedX / zoom
            let worldDy = unrotatedY / zoom

            return SIMD2<Float>(Float(worldDx), Float(worldDy))
        }

        // 2.5. Clamp center points to prevent excessive vertex counts
        let maxCenterPoints = 1000  // Maximum number of centerline points per stroke
        if centerPoints.count > maxCenterPoints {
            let step = max(1, centerPoints.count / maxCenterPoints)
            var downsampled: [SIMD2<Float>] = []
            downsampled.reserveCapacity(maxCenterPoints + 1)

            for i in stride(from: 0, to: centerPoints.count, by: step) {
                downsampled.append(centerPoints[i])
            }
            if let last = centerPoints.last, last != downsampled.last {
                downsampled.append(last)
            }

            centerPoints = downsampled
        }

        // 3. World width is the base width divided by zoom
        let worldWidth = baseWidth / zoom
        self.worldWidth = worldWidth

        // 4. Build stroke segments (centerline only; thickness handled in shader)
        if centerPoints.count >= 2 {
            segments.reserveCapacity(centerPoints.count - 1)
            for i in 0..<(centerPoints.count - 1) {
                let p0 = centerPoints[i]
                let p1 = centerPoints[i + 1]
                segments.append(StrokeSegmentInstance(p0: p0, p1: p1, color: color))
            }
        } else if centerPoints.count == 1 {
            let p = centerPoints[0]
            segments = [StrokeSegmentInstance(p0: p, p1: p, color: color)]
        }

        // 5. Cached GPU Buffer for segments
        if let device = device, !segments.isEmpty {
            self.segmentBuffer = device.makeBuffer(
                bytes: segments,
                length: segments.count * MemoryLayout<StrokeSegmentInstance>.stride,
                options: .storageModeShared
            )
        }

        // 6. Bounding box for culling (expand by stroke radius)
        if centerPoints.isEmpty {
            self.localBounds = .null
        } else {
            var minX = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude

            for p in centerPoints {
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                minY = min(minY, p.y)
                maxY = max(maxY, p.y)
            }

            let halfWidth = Float(worldWidth) * 0.5
            minX -= halfWidth
            maxX += halfWidth
            minY -= halfWidth
            maxY += halfWidth

            self.localBounds = CGRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
        }
    }
}
