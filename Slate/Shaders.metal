//
//  Shaders.metal
//  Slate
//
//  Created by Penny Marshall on 10/27/25.
//

#include <metal_stdlib>
using namespace metal;

struct Transform {
    float2 panOffset;
    float zoomScale;
    float screenWidth;
    float screenHeight;
    float rotationAngle;
};

vertex float4 vertex_main(uint vertexID [[vertex_id]],
                         constant float2 *worldPositions [[buffer(0)]],
                         constant Transform *transform [[buffer(1)]]) {
    float2 world = worldPositions[vertexID];

    // Convert world pixel coordinates to model-space NDC
    float modelX = (world.x / transform->screenWidth) * 2.0 - 1.0;
    float modelY = -((world.y / transform->screenHeight) * 2.0 - 1.0);

    float cosTheta = cos(transform->rotationAngle);
    float sinTheta = sin(transform->rotationAngle);

    float rotatedX = modelX * cosTheta + modelY * sinTheta;
    float rotatedY = -modelX * sinTheta + modelY * cosTheta;

    float zoomedX = rotatedX * transform->zoomScale;
    float zoomedY = rotatedY * transform->zoomScale;

    float panX = (transform->panOffset.x / transform->screenWidth) * 2.0;
    float panY = -(transform->panOffset.y / transform->screenHeight) * 2.0;

    float2 ndc = float2(zoomedX + panX, zoomedY + panY);

    return float4(ndc, 0.0, 1.0);
}

fragment float4 fragment_main(float4 in [[stage_in]]) {
    return float4(0.0, 1.0, 0.0, 1.0);
}
