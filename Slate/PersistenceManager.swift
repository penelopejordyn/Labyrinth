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
        let saveData = CanvasSaveDataV2(timestamp: Date(), fractal: config, rootFrame: dto, version: 4)

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
            let version = header?.version ?? 0

            switch version {
            case 2, 3, 4:
                let saveData = try decoder.decode(CanvasSaveDataV2.self, from: data)
                let root = restoreFrame(from: saveData.rootFrame, parent: nil, indexInParent: nil, device: device)
                return ImportedCanvas(rootFrame: root, fractalFrameExtent: saveData.fractal.toExtent())
            default:
                // Legacy v1 normalization (telescoping → fractal) has been removed.
                // Only v2+ fractal saves are supported.
                print("Import failed: unsupported save version \(version)")
                return nil
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
                name: cardDto.name ?? "Untitled",
                sectionID: cardDto.sectionID,
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

        let sectionDTOs = dto.sections ?? []
        frame.sections = sectionDTOs.map { sectionDto in
            let sectionColor = float4(sectionDto.color)
            return Section(
                id: sectionDto.id,
                name: sectionDto.name,
                color: sectionColor,
                fillOpacity: sectionDto.fillOpacity ?? 0.3,
                polygon: sectionDto.polygon.map { double2($0) }
            )
        }

        for child in dto.children {
            let index = child.index.toGridIndex()
            let restored = restoreFrame(from: child.frame, parent: frame, indexInParent: index, device: device)
            frame.children[index] = restored
        }
        return frame
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
