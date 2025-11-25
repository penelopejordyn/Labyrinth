// TileStroke.swift defines the tile-local stroke representation used for tiled rendering.
import SwiftUI

struct TileStroke {
    let strokeID: UUID
    let localVertices: [SIMD2<Float>]
    let color: SIMD4<Float>
    
}
    
