// Stroke.swift models pen and pencil strokes, including coordinate transforms and tessellation helpers.
import SwiftUI
import Metal

/// A sub-section of a stroke for geometry chunking.
/// Large strokes are divided into chunks to enable sub-stroke culling.
/// Only visible chunks are sent to the GPU, reducing vertex processing overhead.
struct StrokeChunk {
    let vertexStart: Int
    let vertexCount: Int
    let boundingBox: CGRect
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
///
/// ** OPTIMIZATION: Buffer Caching**
/// Changed from struct to class to cache the GPU vertex buffer.
/// The buffer is created ONCE when the stroke is committed, eliminating
/// the CPU overhead of creating new buffers 60 times per second.
class Stroke: Identifiable {
    let id: UUID
    let origin: SIMD2<Double>           // Anchor point within the Frame (Double precision, always small)
    let localVertices: [SIMD2<Float>]   // Vertices relative to origin (Float precision)
    let worldWidth: Double              // Width in world units
    let color: SIMD4<Float>

    //  OPTIMIZATION: Cached GPU Buffer
    // Created once in init, reused every frame
    var vertexBuffer: MTLBuffer?

    //  OPTIMIZATION: Bounding Box for Culling
    // Calculated once in init, used to skip off-screen strokes
    var localBounds: CGRect = .zero

    //  OPTIMIZATION: Geometry Chunking
    // Large strokes are divided into chunks for sub-stroke culling
    // Only visible chunks are rendered, drastically reducing GPU vertex processing
    var chunks: [StrokeChunk] = []

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
    ///   - device: MTLDevice for creating cached vertex buffer
    ///  UPGRADED: Now accepts Double for zoom and pan to maintain precision
    ///  OPTIMIZATION: Now caches vertex buffer and bounding box in init
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
            self.localVertices = []
            self.worldWidth = 0
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

        let relativePoints: [SIMD2<Float>] = screenPoints.map { pt in
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

        // 3. World width is the base width divided by zoom
        let worldWidth = baseWidth / zoom
        self.worldWidth = worldWidth

        // 4. Tessellate in LOCAL space (no view-specific transforms)
        self.localVertices = tessellateStrokeLocal(
            centerPoints: relativePoints,
            width: Float(worldWidth)
        )

        // 5.  OPTIMIZATION: Create Cached Buffer
        // This is done ONCE here, not 60 times per second in drawStroke
        if let device = device, !localVertices.isEmpty {
            self.vertexBuffer = device.makeBuffer(
                bytes: localVertices,
                length: localVertices.count * MemoryLayout<SIMD2<Float>>.stride,
                options: .storageModeShared
            )
        }

        // 6.  OPTIMIZATION: Generate Chunks for Sub-Stroke Culling
        // Break the stroke into smaller pieces so we can cull them individually
        self.generateChunks()

        // 7.  OPTIMIZATION: Calculate Global Bounding Box
        // Union of all chunk bounding boxes
        if !chunks.isEmpty {
            self.localBounds = chunks.reduce(CGRect.null) { $0.union($1.boundingBox) }
        }
    }

    /// Generate chunks for sub-stroke culling.
    /// Large strokes are divided into blocks of vertices to enable fine-grained culling.
    /// Only visible chunks are sent to the GPU, reducing vertex processing overhead.
    private func generateChunks() {
        guard !localVertices.isEmpty else { return }

        // Chunk Size: How many vertices per chunk?
        // Too small = Too many CPU draw calls
        // Too big = Ineffective culling
        // 192 vertices = 32 quads (64 triangles). Good balance.
        let chunkSize = 192
        var offset = 0

        while offset < localVertices.count {
            let count = min(chunkSize, localVertices.count - offset)

            // Calculate Bounding Box for THIS chunk
            var minX = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude

            for i in offset..<(offset + count) {
                let v = localVertices[i]
                if v.x < minX { minX = v.x }
                if v.x > maxX { maxX = v.x }
                if v.y < minY { minY = v.y }
                if v.y > maxY { maxY = v.y }
            }

            let chunkBounds = CGRect(
                x: Double(minX),
                y: Double(minY),
                width: Double(maxX - minX),
                height: Double(maxY - minY)
            )

            chunks.append(StrokeChunk(
                vertexStart: offset,
                vertexCount: count,
                boundingBox: chunkBounds
            ))

            offset += count
        }
    }
}
