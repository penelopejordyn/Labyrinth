import Foundation
import Metal
import MetalKit
import simd
import UIKit

/// A Section is a lasso-defined grouping region that lives in a single `Frame`'s coordinate space.
///
/// Canvas strokes/cards remain stored on `Frame`s and carry an optional `sectionID` referencing
/// the owning Section (which may live in an ancestor frame).
///
/// Membership is dynamic: the "deepest" containing section (smallest area, newest on ties)
/// wins when resolving membership for new content and for items moved across boundaries.
final class Section: Identifiable {
    let id: UUID
    var name: String

    /// RGBA in linear space.
    var color: SIMD4<Float>
    var fillOpacity: Float

    /// Polygon vertices in the owning frame's coordinate system (not necessarily closed).
    /// Stored without a duplicated last=first point.
    var polygon: [SIMD2<Double>] {
        didSet { recomputeCaches() }
    }

    private(set) var bounds: CGRect = .null
    private(set) var absoluteArea: Double = 0.0

    /// Legacy (v3): sections previously stored strokes/cards directly.
    /// The current model stores strokes/cards on frames with an optional `sectionID`.
    var strokes: [Stroke] = []
    var cards: [Card] = []

    // MARK: - Label Rendering (cached)
    var labelTexture: MTLTexture?
    /// Label size in screen points (world units at zoom=1).
    var labelWorldSize: SIMD2<Double> = .zero

    // MARK: - Render Mesh Cache (Metal)
    var fillVertexBuffer: MTLBuffer?
    var fillVertexCount: Int = 0
    var borderVertexBuffer: MTLBuffer?
    var borderVertexCount: Int = 0
    private var cachedBorderWidthWorld: Double = 0.0

    init(id: UUID = UUID(),
         name: String,
         color: SIMD4<Float>,
         fillOpacity: Float = 0.3,
         polygon: [SIMD2<Double>],
         strokes: [Stroke] = [],
         cards: [Card] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.fillOpacity = fillOpacity
        self.polygon = Section.normalizedPolygon(polygon)
        self.strokes = strokes
        self.cards = cards
        recomputeCaches()
    }

    var origin: SIMD2<Double> {
        guard bounds != .null else { return .zero }
        return SIMD2<Double>(Double(bounds.midX), Double(bounds.midY))
    }
    
    /// Returns the bounds of the label in the frame's coordinate system.
    /// The label is positioned at the section's origin (center of bounds).
    func labelBounds() -> CGRect {
        let origin = self.origin
        let halfWidth = labelWorldSize.x * 0.5
        let halfHeight = labelWorldSize.y * 0.5
        return CGRect(
            x: origin.x - halfWidth,
            y: origin.y - halfHeight,
            width: labelWorldSize.x,
            height: labelWorldSize.y
        )
    }
    
    /// Check if a point (in the frame's coordinate system) is within the label bounds.
    func labelContains(pointInFrame: SIMD2<Double>) -> Bool {
        let labelRect = labelBounds()
        return labelRect.contains(CGPoint(x: pointInFrame.x, y: pointInFrame.y))
    }

    func contains(pointInFrame: SIMD2<Double>) -> Bool {
        guard polygon.count >= 3 else { return false }
        
        // Quick bounds check first
        if bounds != .null {
            guard bounds.contains(CGPoint(x: pointInFrame.x, y: pointInFrame.y)) else { return false }
        }

        // Ray casting for precise polygon containment
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            let denom = pj.y - pi.y
            if abs(denom) > 1e-12 {
                let intersect = ((pi.y > pointInFrame.y) != (pj.y > pointInFrame.y)) &&
                    (pointInFrame.x < (pj.x - pi.x) * (pointInFrame.y - pi.y) / denom + pi.x)
                if intersect { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    func ensureLabelTexture(device: MTLDevice) {
        guard labelTexture == nil else { return }

        let text = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name

        let font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]

        let textSize = (text as NSString).size(withAttributes: attributes)

        let paddingX: CGFloat = 10.0
        let paddingY: CGFloat = 6.0
        let sizePoints = CGSize(width: ceil(textSize.width + paddingX * 2.0),
                                height: ceil(textSize.height + paddingY * 2.0))

        // Store label size in screen points (1 world unit ~= 1 pt at zoom=1).
        labelWorldSize = SIMD2<Double>(Double(sizePoints.width), Double(sizePoints.height))

        let bg = UIColor(red: CGFloat(color.x),
                         green: CGFloat(color.y),
                         blue: CGFloat(color.z),
                         alpha: 1.0)

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: sizePoints, format: format)
        let image = renderer.image { ctx in
            bg.setFill()
            ctx.fill(CGRect(origin: .zero, size: sizePoints))

            let textRect = CGRect(
                x: paddingX,
                y: (sizePoints.height - textSize.height) * 0.5,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }

        guard let cgImage = image.cgImage else { return }
        let loader = MTKTextureLoader(device: device)
        labelTexture = try? loader.newTexture(
            cgImage: cgImage,
            options: [MTKTextureLoader.Option.SRGB: false]
        )
    }

    func rebuildRenderBuffersIfNeeded(device: MTLDevice, borderWidthWorld: Double) {
        let borderWidthWorld = max(borderWidthWorld, 0.0)
        let needsBorder = borderVertexBuffer == nil || abs(borderWidthWorld - cachedBorderWidthWorld) > 1e-9
        let needsFill = fillVertexBuffer == nil
        guard needsFill || needsBorder else { return }

        let origin = self.origin

        if needsFill {
            let fillTrianglesWorld = Section.triangulate(polygon: polygon)
            let verts: [StrokeVertex] = fillTrianglesWorld.map { p in
                StrokeVertex(
                    position: SIMD2<Float>(Float(p.x - origin.x), Float(p.y - origin.y)),
                    uv: SIMD2<Float>(0, 0),
                    color: SIMD4<Float>(1, 1, 1, 1)
                )
            }
            fillVertexCount = verts.count
            if verts.isEmpty {
                fillVertexBuffer = nil
            } else {
                fillVertexBuffer = device.makeBuffer(
                    bytes: verts,
                    length: verts.count * MemoryLayout<StrokeVertex>.stride,
                    options: .storageModeShared
                )
            }
        }

        if needsBorder {
            let borderTrianglesWorld = Section.borderTriangles(polygon: polygon, widthWorld: borderWidthWorld)
            let verts: [StrokeVertex] = borderTrianglesWorld.map { p in
                StrokeVertex(
                    position: SIMD2<Float>(Float(p.x - origin.x), Float(p.y - origin.y)),
                    uv: SIMD2<Float>(0, 0),
                    color: SIMD4<Float>(1, 1, 1, 1)
                )
            }
            borderVertexCount = verts.count
            if verts.isEmpty {
                borderVertexBuffer = nil
            } else {
                borderVertexBuffer = device.makeBuffer(
                    bytes: verts,
                    length: verts.count * MemoryLayout<StrokeVertex>.stride,
                    options: .storageModeShared
                )
            }
            cachedBorderWidthWorld = borderWidthWorld
        }
    }

    // MARK: - Caches

    private func recomputeCaches() {
        bounds = Section.bounds(for: polygon)
        absoluteArea = abs(Section.signedArea(for: polygon))
    }

    // MARK: - Geometry Helpers

    private static func normalizedPolygon(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard points.count >= 2 else { return points }
        var result = points
        if let first = result.first, let last = result.last {
            let dx = last.x - first.x
            let dy = last.y - first.y
            if (dx * dx + dy * dy) <= 1e-18 {
                result.removeLast()
            }
        }
        return result
    }

    private static func bounds(for points: [SIMD2<Double>]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func signedArea(for points: [SIMD2<Double>]) -> Double {
        guard points.count >= 3 else { return 0.0 }
        var sum = 0.0
        var j = points.count - 1
        for i in 0..<points.count {
            let pi = points[i]
            let pj = points[j]
            sum += (pj.x * pi.y) - (pi.x * pj.y)
            j = i
        }
        return 0.5 * sum
    }

    private static func triangulate(polygon: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var pts = normalizedPolygon(polygon)
        guard pts.count >= 3 else { return [] }
        if signedArea(for: pts) < 0.0 {
            pts.reverse()
        }

        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        func sign(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>) -> Double {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }

        func pointInTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            let d1 = sign(p, a, b)
            let d2 = sign(p, b, c)
            let d3 = sign(p, c, a)

            let hasNeg = (d1 < -1e-12) || (d2 < -1e-12) || (d3 < -1e-12)
            let hasPos = (d1 > 1e-12) || (d2 > 1e-12) || (d3 > 1e-12)
            return !(hasNeg && hasPos)
        }

        var indices = Array(0..<pts.count)
        var triangles: [SIMD2<Double>] = []
        triangles.reserveCapacity(max(0, (pts.count - 2) * 3))

        var guardCounter = 0
        while indices.count >= 3 && guardCounter < 10_000 {
            let count = indices.count
            var earFound = false

            for i in 0..<count {
                let prev = indices[(i - 1 + count) % count]
                let cur = indices[i]
                let next = indices[(i + 1) % count]

                let a = pts[prev]
                let b = pts[cur]
                let c = pts[next]

                // For CCW polygons, convex vertices have positive cross.
                if cross(a, b, c) <= 1e-12 {
                    continue
                }

                var containsOther = false
                for idx in indices where idx != prev && idx != cur && idx != next {
                    if pointInTriangle(pts[idx], a, b, c) {
                        containsOther = true
                        break
                    }
                }
                if containsOther { continue }

                triangles.append(a)
                triangles.append(b)
                triangles.append(c)
                indices.remove(at: i)
                earFound = true
                break
            }

            if !earFound {
                break
            }
            guardCounter += 1
        }

        return triangles
    }

    private static func borderTriangles(polygon: [SIMD2<Double>], widthWorld: Double) -> [SIMD2<Double>] {
        let pts = normalizedPolygon(polygon)
        guard pts.count >= 2 else { return [] }
        guard widthWorld > 0 else { return [] }

        var triangles: [SIMD2<Double>] = []
        triangles.reserveCapacity(pts.count * 6)

        for i in 0..<pts.count {
            let p0 = pts[i]
            let p1 = pts[(i + 1) % pts.count]
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let len = hypot(dx, dy)
            if len <= 1e-9 { continue }

            let nx = -dy / len
            let ny = dx / len
            let ox = nx * (widthWorld * 0.5)
            let oy = ny * (widthWorld * 0.5)

            let a = SIMD2<Double>(p0.x + ox, p0.y + oy)
            let b = SIMD2<Double>(p0.x - ox, p0.y - oy)
            let c = SIMD2<Double>(p1.x + ox, p1.y + oy)
            let d = SIMD2<Double>(p1.x - ox, p1.y - oy)

            triangles.append(a)
            triangles.append(b)
            triangles.append(c)
            triangles.append(b)
            triangles.append(d)
            triangles.append(c)
        }

        return triangles
    }
}

// MARK: - Serialization
extension Section {
    func toDTO() -> SectionDTO {
        SectionDTO(
            id: id,
            name: name,
            color: [color.x, color.y, color.z, color.w],
            fillOpacity: fillOpacity,
            polygon: polygon.map { [$0.x, $0.y] },
            strokes: nil,
            cards: nil
        )
    }
}
