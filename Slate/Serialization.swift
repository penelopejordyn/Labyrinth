import Foundation
import simd

// MARK: - Save File Schema

struct CanvasSaveHeader: Codable {
    let version: Int?
}

// MARK: - v2 (5x5 Fractal Grid)

struct FractalSaveConfigDTO: Codable {
    let gridSize: Int
    let scale: Double
    let frameExtent: [Double] // [width, height] in world units at zoom=1

    init(gridSize: Int = GridIndex.gridSize, scale: Double = FractalGrid.scale, frameExtent: SIMD2<Double>) {
        self.gridSize = gridSize
        self.scale = scale
        self.frameExtent = [frameExtent.x, frameExtent.y]
    }

    func toExtent() -> SIMD2<Double> {
        let w = frameExtent.count > 0 ? frameExtent[0] : 0
        let h = frameExtent.count > 1 ? frameExtent[1] : 0
        return SIMD2<Double>(w, h)
    }
}

struct CanvasSaveDataV2: Codable {
    let version: Int
    let timestamp: Date
    let fractal: FractalSaveConfigDTO
    let rootFrame: FrameDTOv2

    init(timestamp: Date, fractal: FractalSaveConfigDTO, rootFrame: FrameDTOv2, version: Int = 2) {
        self.version = version
        self.timestamp = timestamp
        self.fractal = fractal
        self.rootFrame = rootFrame
    }
}

struct GridIndexDTO: Codable {
    let col: Int
    let row: Int

    init(_ index: GridIndex) {
        self.col = index.col
        self.row = index.row
    }

    func toGridIndex() -> GridIndex {
        GridIndex(col: col, row: row).clamped()
    }
}

struct ChildFrameDTOv2: Codable {
    let index: GridIndexDTO
    let frame: FrameDTOv2
}

struct FrameDTOv2: Codable {
    let id: UUID
    let depthFromRoot: Int
    let indexInParent: GridIndexDTO?
    let strokes: [StrokeDTO]
    let cards: [CardDTO]
    let sections: [SectionDTO]?
    let children: [ChildFrameDTOv2]
}

		struct StrokeDTO: Codable {
		    let id: UUID
		    let origin: [Double]
		    let worldWidth: Double
	    let color: [Float]
	    let zoomCreation: Float
	    let depthID: UInt32
	    let depthWrite: Bool
	    let link: String?
	    let linkSectionID: UUID?
	    let linkTargetSectionID: UUID?
	    let linkTargetCardID: UUID?
	    let sectionID: UUID?
	    let points: [[Float]]
	}

struct CardDTO: Codable {
    let id: UUID
    let name: String?
    let sectionID: UUID?
    let origin: [Double]
    let size: [Double]
    let rotation: Float
    let creationZoom: Double
    let content: CardContentDTO
    let strokes: [StrokeDTO]
    let backgroundColor: [Float]?
    let opacity: Float?
    let isLocked: Bool?
}

struct SectionDTO: Codable {
    let id: UUID
    let name: String
    let color: [Float]
    let fillOpacity: Float?
    let polygon: [[Double]]
    let strokes: [StrokeDTO]?
    let cards: [CardDTO]?
}

enum CardContentDTO: Codable {
    case solid(color: [Float])
    case image(pngData: Data)
    case lined(spacing: Float, lineWidth: Float, color: [Float])
    case grid(spacing: Float, lineWidth: Float, color: [Float])
}
