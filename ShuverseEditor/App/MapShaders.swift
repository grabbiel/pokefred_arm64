import Foundation

enum MapShaders {
    /// Vertex buffer is six packed floats per vertex: x, y, r, g, b, a.
    /// `packed_float2` + `packed_float4` is 24 bytes with 4-byte alignment,
    /// matching `MeshVertex` on the CPU.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        packed_float2 position;
        packed_float4 color;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };

    struct Uniforms {
        float2 origin;
        float2 viewport;
        float pointsPerMetatile;
        float pad;
    };

    vertex VertexOut map_vertex(
        uint vertexID [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &uniforms [[buffer(1)]]
    ) {
        VertexIn input = vertices[vertexID];
        float2 pixel = (float2(input.position) - uniforms.origin) * uniforms.pointsPerMetatile;
        float2 ndc = float2(
            (pixel.x / uniforms.viewport.x) * 2.0 - 1.0,
            1.0 - (pixel.y / uniforms.viewport.y) * 2.0
        );
        VertexOut output;
        output.position = float4(ndc, 0.0, 1.0);
        output.color = float4(input.color);
        return output;
    }

    fragment float4 map_fragment(VertexOut input [[stage_in]]) {
        return input.color;
    }
    """
}
