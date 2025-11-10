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
                         constant float2 *localOffsets [[buffer(0)]],
                         constant float2 *origins [[buffer(1)]],
                         constant Transform *transform [[buffer(2)]]) {
    float2 local = localOffsets[vertexID];
    float2 origin = origins[vertexID];

    float cosTheta = cos(transform->rotationAngle);
    float sinTheta = sin(transform->rotationAngle);

    float localRotX = local.x * cosTheta + local.y * sinTheta;
    float localRotY = -local.x * sinTheta + local.y * cosTheta;

    float originRotX = origin.x * cosTheta + origin.y * sinTheta;
    float originRotY = -origin.x * sinTheta + origin.y * cosTheta;

    float zoomedX = (originRotX + localRotX) * transform->zoomScale;
    float zoomedY = (originRotY + localRotY) * transform->zoomScale;

    float panX = (transform->panOffset.x / transform->screenWidth) * 2.0;
    float panY = -(transform->panOffset.y / transform->screenHeight) * 2.0;

    float2 transformed = float2(zoomedX + panX, zoomedY + panY);

    return float4(transformed, 0.0, 1.0);
}

fragment float4 fragment_main(float4 in [[stage_in]]) {
    return float4(0.0, 1.0, 0.0, 1.0);
}
