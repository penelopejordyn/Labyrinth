//
//  Stroke.swift
//  Slate
//
//  Created by Penny Marshall on 10/28/25.
//

import SwiftUI

struct Stroke {
    let id: UUID
    let centerPoints: [CGPoint]
    let width: CGFloat
    let color: SIMD4<Float>
    let vertices: [SIMD2<Float>]  // World-space triangle vertices

    init(centerPoints: [CGPoint], width: CGFloat, color: SIMD4<Float>, viewSize _: CGSize) {
        self.id = UUID()
        self.centerPoints = centerPoints
        self.width = width
        self.color = color

        // Tessellate once into world-space vertices so precision is preserved
        // regardless of the zoom level applied later in the shader.
        self.vertices = tessellateStroke(
            centerPoints: centerPoints,
            width: width
        )
    }
}
