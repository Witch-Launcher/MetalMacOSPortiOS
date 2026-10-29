#include <metal_stdlib>
using namespace metal;

static_assert(__METAL_VERSION__ == 120, "MetalBridgeKit render probe requires Metal Shading Language 1.2");

struct ProbeVertexOut {
    float4 position [[position]];
};

vertex ProbeVertexOut probe_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    ProbeVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment float4 probe_fragment() {
    return float4(1.0, 0.0, 0.0, 1.0);
}
