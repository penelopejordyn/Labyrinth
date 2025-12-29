import Foundation
import Metal
import MetalKit

final class PersistenceManager {
    static let shared = PersistenceManager()

    private init() {}

    struct ImportedCanvas {
        let rootFrame: Frame
        let fractalFrameExtent: SIMD2<Double>
    }

    func exportCanvas(rootFrame: Frame, fractalFrameExtent: SIMD2<Double>) -> Data? {
        let topFrame = topmostFrame(from: rootFrame)
        let dto = topFrame.toDTOv2()
        let config = FractalSaveConfigDTO(frameExtent: fractalFrameExtent)
        let saveData = CanvasSaveDataV2(timestamp: Date(), fractal: config, rootFrame: dto)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            return try encoder.encode(saveData)
        } catch {
            print("Export failed: \(error)")
            return nil
        }
    }

    func importCanvas(data: Data,
                      device: MTLDevice,
                      fractalFrameExtent: SIMD2<Double> = .zero) -> ImportedCanvas? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let header = (try? decoder.decode(CanvasSaveHeader.self, from: data))
            let version = header?.version ?? 1

            switch version {
            case 2:
                let saveData = try decoder.decode(CanvasSaveDataV2.self, from: data)
                let root = restoreFrame(from: saveData.rootFrame, parent: nil, indexInParent: nil, device: device)
                return ImportedCanvas(rootFrame: root, fractalFrameExtent: saveData.fractal.toExtent())
            default:
                // Legacy import (v1 telescoping) normalized into the 5x5 fractal grid.
                let saveData = try decoder.decode(CanvasSaveDataV1.self, from: data)
                let extent = (fractalFrameExtent.x > 0.0 && fractalFrameExtent.y > 0.0) ? fractalFrameExtent : SIMD2<Double>(1024.0, 1024.0)
                let root = restoreLegacyCanvas(from: saveData.rootFrame, device: device, frameExtent: extent)
                return ImportedCanvas(rootFrame: root, fractalFrameExtent: extent)
            }
        } catch {
            print("Import failed: \(error)")
            return nil
        }
    }

    private func restoreFrame(from dto: FrameDTOv2,
                              parent: Frame?,
                              indexInParent: GridIndex?,
                              device: MTLDevice) -> Frame {
        let frame = Frame(id: dto.id,
                          parent: parent,
                          indexInParent: indexInParent,
                          depth: dto.depthFromRoot)

        frame.strokes = dto.strokes.map { Stroke(dto: $0, device: device) }

        frame.cards = dto.cards.map { cardDto in
            let type = cardType(from: cardDto.content, device: device)
            let background = cardBackgroundColor(from: cardDto)
            let card = Card(
                id: cardDto.id,
                origin: double2(cardDto.origin),
                size: double2(cardDto.size),
                rotation: cardDto.rotation,
                zoom: cardDto.creationZoom,
                type: type,
                backgroundColor: background,
                opacity: cardDto.opacity ?? 1.0,
                isLocked: cardDto.isLocked ?? false
            )
            card.strokes = cardDto.strokes.map { Stroke(dto: $0, device: device) }
            return card
        }

        for child in dto.children {
            let index = child.index.toGridIndex()
            let restored = restoreFrame(from: child.frame, parent: frame, indexInParent: index, device: device)
            frame.children[index] = restored
        }
        return frame
    }

    private func restoreFrame(from dto: FrameDTOv1,
                              parent: Frame?,
                              indexInParent: GridIndex?,
                              device: MTLDevice) -> Frame {
        let frame = Frame(id: dto.id,
                          parent: parent,
                          indexInParent: indexInParent,
                          depth: dto.depthFromRoot)

        frame.strokes = dto.strokes.map { Stroke(dto: $0, device: device) }

        frame.cards = dto.cards.map { cardDto in
            let type = cardType(from: cardDto.content, device: device)
            let background = cardBackgroundColor(from: cardDto)
            let card = Card(
                id: cardDto.id,
                origin: double2(cardDto.origin),
                size: double2(cardDto.size),
                rotation: cardDto.rotation,
                zoom: cardDto.creationZoom,
                type: type,
                backgroundColor: background,
                opacity: cardDto.opacity ?? 1.0,
                isLocked: cardDto.isLocked ?? false
            )
            card.strokes = cardDto.strokes.map { Stroke(dto: $0, device: device) }
            return card
        }

        /*
        // MARK: - Legacy v1 Import (Reference Only)
        //
        // Previous best-effort approach: telescoping trees were treated like a simple chain and
        // mapped into arbitrary 5x5 slots (center-first), ignoring `originInParent` and `scaleRelativeToParent`.
        //
        // This caused misaligned depths and unreachable content once the fractal grid introduced
        // bounded coordinates + same-depth tiling.
        //
        // The new importer below (`restoreLegacyCanvas`) performs an actual normalization pass.
        */

        return frame
    }

    // MARK: - Legacy v1 Normalization (Telescoping → 5x5 Fractal)

    private func restoreLegacyCanvas(from dto: FrameDTOv1,
                                     device: MTLDevice,
                                     frameExtent: SIMD2<Double>) -> Frame {
        // Legacy v1 telescoping saves were authored at a much smaller world-unit scale than the
        // current fractal-grid `frameExtent` world. Scale the entire import up so users don't need
        // to drill many depths just to see content (which would then trigger the ±depth culling).
        let legacyV1ContentScale: Double = 80_000.0

        let base = Frame(id: dto.id, parent: nil, indexInParent: nil, depth: 0)
        var topRoot = base
        restoreLegacyFrame(dto,
                           baseFrame: base,
                           root: &topRoot,
                           extent: frameExtent,
                           device: device,
                           scaleToNew: legacyV1ContentScale,
                           translationToNew: .zero)
        return topmostFrame(from: topRoot)
    }

    private func restoreLegacyFrame(_ dto: FrameDTOv1,
                                    baseFrame: Frame,
                                    root: inout Frame,
                                    extent: SIMD2<Double>,
                                    device: MTLDevice,
                                    scaleToNew: Double,
                                    translationToNew: SIMD2<Double>) {
        func childFrame(parent: Frame, index: GridIndex, id: UUID? = nil) -> Frame {
            let key = index.clamped()
            if let existing = parent.children[key] {
                return existing
            }
            let created = Frame(id: id ?? UUID(),
                                parent: parent,
                                indexInParent: key,
                                depth: parent.depthFromRoot + 1)
            parent.children[key] = created
            return created
        }

        func scaledRect(_ rect: CGRect, by scale: Double) -> CGRect {
            guard rect != .null else { return rect }
            return CGRect(x: rect.origin.x * scale,
                          y: rect.origin.y * scale,
                          width: rect.size.width * scale,
                          height: rect.size.height * scale)
        }

        func makeScaledStroke(from dto: StrokeDTO, origin: SIMD2<Double>, scale: Double) -> Stroke {
            let base = Stroke(dto: dto, device: nil)
            let sf = Float(scale)
            let scaledSegments = base.segments.map { seg in
                StrokeSegmentInstance(p0: seg.p0 * sf,
                                      p1: seg.p1 * sf,
                                      color: seg.color)
            }
            let bounds = scaledRect(base.localBounds, by: scale)
            return Stroke(id: base.id,
                          origin: origin,
                          worldWidth: base.worldWidth * scale,
                          color: base.color,
                          zoomEffectiveAtCreation: base.zoomEffectiveAtCreation,
                          segments: scaledSegments,
                          localBounds: bounds,
                          segmentBounds: bounds,
                          device: device,
                          depthID: base.depthID,
                          depthWriteEnabled: base.depthWriteEnabled)
        }

        func resolveTileFrame(for pointInBase: SIMD2<Double>) -> (frame: Frame, pointInFrame: SIMD2<Double>) {
            let half = extent * 0.5

            func outOfBounds(_ point: SIMD2<Double>) -> Bool {
                point.x < -half.x || point.x > half.x || point.y < -half.y || point.y > half.y
            }

            var point = pointInBase
            var levelsUp = 0
            var current: Frame = baseFrame

            // Walk up to the current root, converting the point into each parent coordinate system.
            while let parent = current.parent, let index = current.indexInParent {
                let center = FractalGrid.childCenterInParent(frameExtent: extent, index: index)
                point = center + (point / FractalGrid.scale)
                current = parent
                levelsUp += 1
            }

            var top = current
            root = topmostFrame(from: top)
            top = root

            // Expand the universe upward until the point fits within the topmost bounds.
            while outOfBounds(point) {
                top = top.ensureSuperRoot()
                root = topmostFrame(from: top)
                point = point / FractalGrid.scale
                levelsUp += 1
            }

            // Walk back down to the original depth, choosing child tiles that contain the point.
            var frameDown = top
            var pointDown = point
            for _ in 0..<levelsUp {
                let idx = FractalGrid.childIndex(frameExtent: extent, pointInParent: pointDown)
                let center = FractalGrid.childCenterInParent(frameExtent: extent, index: idx)
                pointDown = (pointDown - center) * FractalGrid.scale
                frameDown = childFrame(parent: frameDown, index: idx)
            }

            return (frame: frameDown, pointInFrame: pointDown)
        }

        func legacyScaleLevels(for scaleRelativeToParent: Double) -> Int {
            // Legacy telescoping typically used ~1000x per depth step; mapping that literally to 5x steps
            // creates ~4-5 fractal levels per legacy level (log_5(1000) ≈ 4.29), which pushes imported
            // content far beyond the ±6 depth visibility window.
            //
            // Normalize legacy files to *one fractal depth per legacy depth* so imported content lands
            // near the expected depth range. Scale is still preserved via `childScaleToNew`.

            /*
            // Reference (scale-faithful) mapping:
            let safeScale = max(scaleRelativeToParent, 1e-9)
            let raw = log(safeScale) / log(FractalGrid.scale)
            let rounded = Int(raw.rounded())
            return max(1, min(rounded, 64))
            */

            _ = scaleRelativeToParent
            return 1
        }

        func transformPoint(_ point: SIMD2<Double>) -> SIMD2<Double> {
            translationToNew + point * scaleToNew
        }

        // A) Canvas strokes (tile into same-depth frames; keep geometry in local coordinates).
        for strokeDTO in dto.strokes {
            let originOld = double2(strokeDTO.origin)
            let originNew = transformPoint(originOld)
            let resolved = resolveTileFrame(for: originNew)
            resolved.frame.strokes.append(
                makeScaledStroke(from: strokeDTO,
                                 origin: resolved.pointInFrame,
                                 scale: scaleToNew)
            )
        }

        // B) Cards + card-local strokes.
        for cardDTO in dto.cards {
            let type = cardType(from: cardDTO.content, device: device)
            let background = cardBackgroundColor(from: cardDTO)

            let originOld = double2(cardDTO.origin)
            let originNew = transformPoint(originOld)
            let resolved = resolveTileFrame(for: originNew)

            let card = Card(id: cardDTO.id,
                            origin: resolved.pointInFrame,
                            size: double2(cardDTO.size) * scaleToNew,
                            rotation: cardDTO.rotation,
                            zoom: cardDTO.creationZoom,
                            type: type,
                            backgroundColor: background,
                            opacity: cardDTO.opacity ?? 1.0,
                            isLocked: cardDTO.isLocked ?? false)

            card.strokes = cardDTO.strokes.map { strokeDTO in
                makeScaledStroke(from: strokeDTO,
                                 origin: double2(strokeDTO.origin) * scaleToNew,
                                 scale: scaleToNew)
            }

            resolved.frame.cards.append(card)
        }

        // C) Child frames: map the legacy origin + scale into a k-step fractal chain.
        for childDTO in dto.children {
            let legacyOrigin = double2(childDTO.originInParent)
            let originInParentNew = transformPoint(legacyOrigin)

            let resolved = resolveTileFrame(for: originInParentNew)
            let scaleOld = max(childDTO.scaleRelativeToParent, 1e-9)
            let levels = legacyScaleLevels(for: scaleOld)
            let scaleFactor = pow(FractalGrid.scale, Double(levels))

            var parentFrame = resolved.frame
            var anchor = resolved.pointInFrame

            for level in 0..<levels {
                let idx = FractalGrid.childIndex(frameExtent: extent, pointInParent: anchor)
                let center = FractalGrid.childCenterInParent(frameExtent: extent, index: idx)
                anchor = (anchor - center) * FractalGrid.scale

                let id: UUID? = (level == levels - 1) ? childDTO.id : nil
                parentFrame = childFrame(parent: parentFrame, index: idx, id: id)
            }

            let childScaleToNew = scaleToNew * scaleFactor / scaleOld
            restoreLegacyFrame(childDTO,
                               baseFrame: parentFrame,
                               root: &root,
                               extent: extent,
                               device: device,
                               scaleToNew: childScaleToNew,
                               translationToNew: anchor)
        }
    }

    private func topmostFrame(from frame: Frame) -> Frame {
        var top = frame
        while let parent = top.parent {
            top = parent
        }
        return top
    }

    private func cardType(from content: CardContentDTO, device: MTLDevice) -> CardType {
        switch content {
        case .solid(let color):
            return .solidColor(float4(color))
        case .lined(let spacing, let lineWidth, let color):
            return .lined(LinedBackgroundConfig(spacing: spacing, lineWidth: lineWidth, color: float4(color)))
        case .grid(let spacing, let lineWidth, let color):
            return .grid(LinedBackgroundConfig(spacing: spacing, lineWidth: lineWidth, color: float4(color)))
        case .image(let data):
            let loader = MTKTextureLoader(device: device)
            // Note: card image textures are stored exactly as the in-memory Metal texture bytes.
            // Because our card UVs already compensate for the initial image-load vertical flip,
            // we should NOT apply another origin flip here (or the image will import upside-down).
            if let texture = try? loader.newTexture(
                data: data,
                options: [
                    .origin: MTKTextureLoader.Origin.topLeft,
                    // Keep card images in non-sRGB textures since the renderer targets `.bgra8Unorm`.
                    // Sampling sRGB textures would return linear values and the result would look too dark.
                    .SRGB: false,
                ]
            ) {
                return .image(texture)
            }
            return .solidColor(SIMD4<Float>(1, 0, 1, 1))
        }
    }

    private func cardBackgroundColor(from dto: CardDTO) -> SIMD4<Float> {
        if let background = dto.backgroundColor {
            return float4(background)
        }
        switch dto.content {
        case .solid(let color):
            return float4(color)
        default:
            return SIMD4<Float>(1, 1, 1, 1)
        }
    }

    private func double2(_ values: [Double]) -> SIMD2<Double> {
        let x = values.count > 0 ? values[0] : 0
        let y = values.count > 1 ? values[1] : 0
        return SIMD2<Double>(x, y)
    }

    private func float4(_ values: [Float]) -> SIMD4<Float> {
        let x = values.count > 0 ? values[0] : 0
        let y = values.count > 1 ? values[1] : 0
        let z = values.count > 2 ? values[2] : 0
        let w = values.count > 3 ? values[3] : 1
        return SIMD4<Float>(x, y, z, w)
    }
}
